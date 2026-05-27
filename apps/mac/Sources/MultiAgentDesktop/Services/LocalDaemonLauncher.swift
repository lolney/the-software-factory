import Foundation
import Darwin
import CryptoKit

final class LocalDaemonLauncher: @unchecked Sendable {
    private var process: Process?
    private let lock = NSLock()

    func ensureStarted(port: Int) async -> Bool {
        prepareStableSessionsRoot()
        if process?.isRunning == true, Self.isListening(port: port), Self.isOwnedDaemon(port: port) {
            return true
        }
        terminateStaleDaemonIfNeeded(port: port)
        if Self.isListening(port: port) {
            return Self.isOwnedDaemon(port: port)
        }
        await Task.detached(priority: .utility) { [weak self] in
            self?.start(port: port)
        }.value
        for _ in 0..<40 {
            if Self.isListening(port: port), Self.isOwnedDaemon(port: port) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return Self.isListening(port: port) && Self.isOwnedDaemon(port: port)
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
        guard process?.isRunning != true else { return }
        guard let supportURL = appSupportURL() else { return }
        guard let daemonToken = ensureDaemonToken(supportURL: supportURL) else { return }
        let sessionsURL = supportURL.appending(path: "sessions", directoryHint: .isDirectory)
        let logsURL = supportURL.appending(path: "logs", directoryHint: .isDirectory)
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

        guard let launch = daemonLaunchConfiguration() else {
            write("Could not find the packaged daemon entrypoint.\n", to: logHandle)
            try? logHandle.close()
            return
        }

        let process = Process()
        process.currentDirectoryURL = supportURL
        process.executableURL = nodeURL
        process.arguments = launch.arguments
        var environment = ProcessInfo.processInfo.environment.merging([
            "MULTIAGENT_DAEMON_PORT": String(port),
            "MULTIAGENT_SESSIONS_ROOT": sessionsURL.path,
            "MULTIAGENT_DAEMON_TOKEN": daemonToken
        ]) { _, new in new }
        environment["PATH"] = sanitizedPath(environment["PATH"])
        if let workflowsURL = launch.workflowsURL {
            environment["MULTIAGENT_BUILTIN_WORKFLOWS_DIR"] = workflowsURL.path
        }
        process.environment = environment
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
        _ = ensureDaemonToken(supportURL: supportURL)
    }

    private func ensureDaemonToken(supportURL: URL) -> String? {
        let tokenURL = supportURL.appending(path: "daemon.token")
        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        do {
            try token.write(to: tokenURL, atomically: true, encoding: .utf8)
            chmod(tokenURL.path, S_IRUSR | S_IWUSR)
            return token
        } catch {
            return nil
        }
    }

    private func terminateStaleDaemonIfNeeded(port: Int) {
        var didTerminate = false
        for pid in listenerPIDs(port: port) {
            guard pid != getpid(), isKnownDaemonProcess(pid: pid) else { continue }
            kill(pid, SIGTERM)
            didTerminate = true
        }
        guard didTerminate else { return }
        for _ in 0..<20 {
            if !Self.isListening(port: port) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
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
            || command.contains("The Software Factory/Build/Daemon/nodeMain.cjs")
            || command.contains("MultiAgentDesktop/Build/Daemon/nodeMain.cjs")
            || command.contains("apps/daemon/src/main.ts")
            || command.contains("The Software Factory daemon")
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

    private static func isOwnedDaemon(port: Int) -> Bool {
        guard let token = daemonToken(), !token.isEmpty else { return false }
        let nonce = UUID().uuidString + UUID().uuidString
        guard let url = URL(string: "http://127.0.0.1:\(port)/ownership-challenge?nonce=\(nonce)"),
              let data = try? Data(contentsOf: url),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["ok"] as? Bool == true,
              ["software-factory-daemon", "multiagent-daemon"].contains(response["service"] as? String),
              response["nonce"] as? String == nonce,
              let proof = response["proof"] as? String else {
            return false
        }
        return proof == ownershipProof(token: token, nonce: nonce)
    }

    private static func daemonToken() -> String? {
        guard let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "The Software Factory", directoryHint: .isDirectory)
            .appending(path: "daemon.token") else {
            return nil
        }
        return try? String(contentsOf: supportURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ownershipProof(token: String, nonce: String) -> String {
        let key = SymmetricKey(data: Data(token.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: key)
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    private func daemonLaunchConfiguration() -> (arguments: [String], workflowsURL: URL?)? {
        if let entry = Bundle.main.object(forInfoDictionaryKey: "SoftwareFactoryDaemonEntry") as? String,
           !entry.isEmpty {
            let workflows = (Bundle.main.object(forInfoDictionaryKey: "SoftwareFactoryBuiltinWorkflowsDir") as? String)
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            return ([entry], workflows)
        }
        if let entry = Bundle.main.object(forInfoDictionaryKey: "MultiAgentDaemonEntry") as? String,
           !entry.isEmpty {
            let workflows = (Bundle.main.object(forInfoDictionaryKey: "MultiAgentBuiltinWorkflowsDir") as? String)
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            return ([entry], workflows)
        }

        guard let rootURL = findRepositoryRoot() else { return nil }
        return ([
            rootURL.appending(path: "node_modules/.bin/tsx").path,
            rootURL.appending(path: "apps/daemon/src/nodeMain.ts").path
        ], rootURL.appending(path: "apps/daemon/src/workflows"))
    }

    private func findRepositoryRoot() -> URL? {
        if let plistRoot = Bundle.main.object(forInfoDictionaryKey: "SoftwareFactoryRepositoryRoot") as? String,
           !plistRoot.isEmpty {
            return URL(fileURLWithPath: plistRoot)
        }
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
        let supportURL = baseURL.appending(path: "The Software Factory", directoryHint: .isDirectory)
        let legacyURL = baseURL.appending(path: "MultiAgentDesktop", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            migrateLegacySupportData(from: legacyURL, to: supportURL)
            return supportURL
        } catch {
            return nil
        }
    }

    private func migrateLegacySupportData(from legacyURL: URL, to supportURL: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyURL.path) else { return }
        mergeDirectoryContents(from: legacyURL.appending(path: "sessions", directoryHint: .isDirectory), to: supportURL.appending(path: "sessions", directoryHint: .isDirectory))
        copyIfMissing(from: legacyURL.appending(path: "daemon.token"), to: supportURL.appending(path: "daemon.token"))
    }

    private func mergeDirectoryContents(from sourceURL: URL, to destinationURL: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        try? fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for source in entries {
            let destination = destinationURL.appending(path: source.lastPathComponent)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
                var sourceIsDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory),
                   sourceIsDirectory.boolValue,
                   isDirectory.boolValue {
                    mergeDirectoryContents(from: source, to: destination)
                }
                continue
            }
            try? fileManager.copyItem(at: source, to: destination)
        }
    }

    private func copyIfMissing(from sourceURL: URL, to destinationURL: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path),
              !fileManager.fileExists(atPath: destinationURL.path) else {
            return
        }
        try? fileManager.copyItem(at: sourceURL, to: destinationURL)
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
        var candidates = sanitizedPath(ProcessInfo.processInfo.environment["PATH"])
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "node") }
            .map(\.path)
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

    private func sanitizedPath(_ path: String?) -> String {
        (path ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !isInPrivacyProtectedUserFolder(URL(fileURLWithPath: $0)) }
            .joined(separator: ":")
    }

    private func isInPrivacyProtectedUserFolder(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let protectedFolders = ["Desktop", "Documents", "Downloads"]
            .map { home.appending(path: $0, directoryHint: .isDirectory).path }
        let path = url.standardizedFileURL.path
        return protectedFolders.contains { protectedPath in
            path == protectedPath || path.hasPrefix(protectedPath + "/")
        }
    }

    private func write(_ text: String, to handle: FileHandle) {
        if let data = text.data(using: .utf8) {
            handle.write(data)
        }
    }
}
