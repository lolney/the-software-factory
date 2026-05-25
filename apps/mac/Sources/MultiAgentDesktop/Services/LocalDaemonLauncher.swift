import Foundation
import Darwin

final class LocalDaemonLauncher: @unchecked Sendable {
    private var process: Process?
    private let lock = NSLock()

    func ensureStarted(port: Int) async -> Bool {
        prepareStableSessionsRoot()
        if process?.isRunning == true, Self.isListening(port: port) {
            return true
        }
        terminateStaleDaemonIfNeeded(port: port)
        if Self.isListening(port: port) {
            return true
        }
        await Task.detached(priority: .utility) { [weak self] in
            self?.start(port: port)
        }.value
        for _ in 0..<40 {
            if Self.isListening(port: port) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return Self.isListening(port: port)
    }

    func stop() {
        lock.lock()
        let runningProcess = process
        process = nil
        lock.unlock()

        guard let runningProcess, runningProcess.isRunning else { return }
        runningProcess.terminate()
        for _ in 0..<20 {
            if !runningProcess.isRunning {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if runningProcess.isRunning {
            kill(runningProcess.processIdentifier, SIGKILL)
        }
    }

    private func start(port: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard process?.isRunning != true, let rootURL = findRepositoryRoot() else { return }
        guard let supportURL = appSupportURL() else { return }
        let sessionsURL = supportURL.appending(path: "sessions", directoryHint: .isDirectory)
        let logsURL = supportURL.appending(path: "logs", directoryHint: .isDirectory)
        migrateLegacySessions(from: rootURL, to: sessionsURL)
        try? FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        let logURL = logsURL.appending(path: "app-daemon.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        guard let logHandle = try? FileHandle(forWritingTo: logURL) else { return }
        logHandle.seekToEndOfFile()

        guard let nodeURL = findNodeExecutable() else {
            write("Could not find a node executable.\n", to: logHandle)
            try? logHandle.close()
            return
        }

        let process = Process()
        process.currentDirectoryURL = supportURL
        process.executableURL = nodeURL
        process.arguments = [
            rootURL.appending(path: "node_modules/.bin/tsx").path,
            rootURL.appending(path: "apps/daemon/src/nodeMain.ts").path
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "MULTIAGENT_DAEMON_PORT": String(port),
            "MULTIAGENT_SESSIONS_ROOT": sessionsURL.path,
            "MULTIAGENT_BUILTIN_WORKFLOWS_DIR": rootURL.appending(path: "apps/daemon/src/workflows").path
        ]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { _ in
            try? logHandle.close()
        }

        do {
            try process.run()
            self.process = process
        } catch {
            try? logHandle.close()
        }
    }

    private func prepareStableSessionsRoot() {
        guard let supportURL = appSupportURL() else { return }
        let sessionsURL = supportURL.appending(path: "sessions", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        if let rootURL = findRepositoryRoot() {
            migrateLegacySessions(from: rootURL, to: sessionsURL)
        }
    }

    private func terminateStaleDaemonIfNeeded(port: Int) {
        for pid in listenerPIDs(port: port) {
            guard pid != getpid(), isKnownDaemonProcess(pid: pid) else { continue }
            kill(pid, SIGTERM)
        }
    }

    private func listenerPIDs(port: Int) -> [pid_t] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func isKnownDaemonProcess(pid: pid_t) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let command = String(data: data, encoding: .utf8) ?? ""
        return command.contains("apps/daemon/src/nodeMain.ts")
            || command.contains("apps/daemon/src/main.ts")
            || command.contains("multiagent daemon")
    }

    private static func isListening(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func findRepositoryRoot() -> URL? {
        if let plistRoot = Bundle.main.object(forInfoDictionaryKey: "MultiAgentRepositoryRoot") as? String,
           !plistRoot.isEmpty {
            return URL(fileURLWithPath: plistRoot)
        }
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent(),
            Bundle.main.executableURL?.deletingLastPathComponent()
        ].compactMap { $0 }

        for candidate in candidates {
            if let root = walkUp(from: candidate) {
                return root
            }
        }
        return nil
    }

    private func appSupportURL() -> URL? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let supportURL = baseURL.appending(path: "MultiAgentDesktop", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            return supportURL
        } catch {
            return nil
        }
    }

    private func migrateLegacySessions(from rootURL: URL, to sessionsURL: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let markerURL = sessionsURL.deletingLastPathComponent().appending(path: ".legacy-session-migration-v1")
        if fileManager.fileExists(atPath: markerURL.path) {
            return
        }
        let legacyRoots = [
            rootURL.appending(path: "sessions", directoryHint: .isDirectory),
            rootURL.appending(path: "apps/daemon/sessions", directoryHint: .isDirectory)
        ]

        for legacyRoot in legacyRoots where fileManager.fileExists(atPath: legacyRoot.path) {
            guard let entries = try? fileManager.contentsOfDirectory(at: legacyRoot, includingPropertiesForKeys: nil) else {
                continue
            }
            for entry in entries {
                let destination = sessionsURL.appending(path: entry.lastPathComponent, directoryHint: .inferFromPath)
                if fileManager.fileExists(atPath: destination.path) {
                    continue
                }
                do {
                    try fileManager.copyItem(at: entry, to: destination)
                } catch {
                    continue
                }
            }
        }
        fileManager.createFile(atPath: markerURL.path, contents: Data())
    }

    private func walkUp(from startURL: URL) -> URL? {
        var url = startURL.standardizedFileURL
        while url.path != "/" {
            let daemonPackage = url.appending(path: "apps/daemon/package.json").path
            let rootPackage = url.appending(path: "package.json").path
            if FileManager.default.fileExists(atPath: daemonPackage),
               FileManager.default.fileExists(atPath: rootPackage) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private func findNodeExecutable() -> URL? {
        let fileManager = FileManager.default
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "node").path }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ])

        let nvmRoot = fileManager.homeDirectoryForCurrentUser.appending(path: ".nvm/versions/node", directoryHint: .isDirectory)
        if let versions = try? fileManager.contentsOfDirectory(at: nvmRoot, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: versions.map { $0.appending(path: "bin/node").path }.sorted().reversed())
        }

        return candidates
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func write(_ text: String, to handle: FileHandle) {
        if let data = text.data(using: .utf8) {
            handle.write(data)
        }
    }
}
