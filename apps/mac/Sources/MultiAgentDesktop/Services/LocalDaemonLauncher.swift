import Foundation
import Darwin

final class LocalDaemonLauncher: @unchecked Sendable {
    private var process: Process?
    private let lock = NSLock()

    func ensureStarted(port: Int) async -> Bool {
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

    private func start(port: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard process?.isRunning != true, let rootURL = findRepositoryRoot() else { return }
        let distURL = rootURL.appending(path: "dist", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: distURL, withIntermediateDirectories: true)
        let logURL = distURL.appending(path: "app-daemon.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        guard let logHandle = try? FileHandle(forWritingTo: logURL) else { return }
        logHandle.seekToEndOfFile()

        guard let nodeURL = findNodeExecutable() else {
            write("Could not find a node executable.\n", to: logHandle)
            try? logHandle.close()
            return
        }

        let process = Process()
        process.currentDirectoryURL = rootURL
        process.executableURL = nodeURL
        process.arguments = [rootURL.appending(path: "node_modules/.bin/tsx").path, "apps/daemon/src/nodeMain.ts"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "MULTIAGENT_DAEMON_PORT": String(port)
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
