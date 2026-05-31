import Foundation
import Observation

@Observable
@MainActor
final class DaemonClient {
    private struct QueuedMessage {
        var json: String
        var requestId: String?
    }

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var delegate: WebSocketConnectionDelegate?
    private var queuedMessages: [QueuedMessage] = []
    private var connectionGeneration = 0
    var isConnected = false
    var isConnecting = false
    var onMessage: ((Data) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onSendError: ((String) -> Void)?
    var onRequestSent: ((String) -> Void)?

    func connect(port: Int = 3767) {
        guard task == nil else { return }
        connectionGeneration += 1
        let generation = connectionGeneration
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        var request = URLRequest(url: url)
        if let token = Self.daemonToken(), !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-multiagent-token")
        }
        let delegate = WebSocketConnectionDelegate(
            onOpen: { [weak self] in
                Task { @MainActor in
                    guard let self, generation == self.connectionGeneration else { return }
                    self.isConnected = true
                    self.isConnecting = false
                    self.flushQueuedMessages(generation: generation)
                }
            },
            onClose: { [weak self] reason in
                Task { @MainActor in
                    guard let self, generation == self.connectionGeneration else { return }
                    self.invalidateCurrentConnection(generation: generation)
                    self.onDisconnect?(reason)
                }
            }
        )
        self.delegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        isConnecting = true
        task.resume()
        receiveNext(generation: connectionGeneration)
    }

    func reconnect(port: Int = 3767) {
        disconnect()
        connect(port: port)
    }

    func disconnect() {
        connectionGeneration += 1
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        delegate = nil
        queuedMessages.removeAll()
        isConnected = false
        isConnecting = false
    }

    func send(_ json: String, requestId: String? = nil) {
        let generation = connectionGeneration
        guard task != nil else {
            onSendError?("Daemon is not connected.")
            return
        }
        if isConnecting && !isConnected {
            queuedMessages.append(QueuedMessage(json: json, requestId: requestId))
            return
        }
        guard isConnected else {
            onSendError?("Daemon is not connected.")
            return
        }
        send(json, generation: generation, requestId: requestId)
    }

    private func send(_ json: String, generation: Int, requestId: String?) {
        guard generation == connectionGeneration else { return }
        guard let task else { return }
        task.send(.string(json)) { error in
            Task { @MainActor in
                guard generation == self.connectionGeneration else { return }
                if let error {
                    print("WebSocket send failed: \(error)")
                    self.invalidateCurrentConnection(generation: generation)
                    self.onSendError?(error.localizedDescription)
                    return
                }
                self.isConnected = true
                self.isConnecting = false
                if let requestId {
                    self.onRequestSent?(requestId)
                }
            }
        }
    }

    private func flushQueuedMessages(generation: Int) {
        guard generation == connectionGeneration, isConnected else { return }
        let messages = queuedMessages
        queuedMessages.removeAll()
        for message in messages {
            send(message.json, generation: generation, requestId: message.requestId)
        }
    }

    @discardableResult
    func sendRequest(id: String = UUID().uuidString, method: String, params: [String: Any]) -> String {
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return id }
        send(json, requestId: id)
        return id
    }

    private func receiveNext(generation: Int) {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard generation == self.connectionGeneration else { return }
                switch result {
                case .success(.data(let data)):
                    self.isConnected = true
                    self.isConnecting = false
                    self.onMessage?(data)
                    self.receiveNext(generation: generation)
                case .success(.string(let text)):
                    self.isConnected = true
                    self.isConnecting = false
                    self.onMessage?(Data(text.utf8))
                    self.receiveNext(generation: generation)
                case .failure(let error):
                    print("WebSocket receive failed: \(error)")
                    self.invalidateCurrentConnection(generation: generation)
                    self.onDisconnect?(error.localizedDescription)
                @unknown default:
                    self.receiveNext(generation: generation)
                }
            }
        }
    }

    private func invalidateCurrentConnection(generation: Int) {
        guard generation == connectionGeneration else { return }
        connectionGeneration += 1
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        delegate = nil
        queuedMessages.removeAll()
        isConnected = false
        isConnecting = false
    }

    private static func daemonToken() -> String? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let candidates = [
            baseURL.appending(path: "The Software Factory", directoryHint: .isDirectory),
            baseURL.appending(path: "MultiAgentDesktop", directoryHint: .isDirectory)
        ]
        for supportURL in candidates {
            if let token = try? String(contentsOf: supportURL.appending(path: "daemon.token"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                return token
            }
        }
        return nil
    }
}

private final class WebSocketConnectionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let onOpen: @Sendable () -> Void
    private let onClose: @Sendable (String) -> Void

    init(onOpen: @escaping @Sendable () -> Void, onClose: @escaping @Sendable (String) -> Void) {
        self.onOpen = onOpen
        self.onClose = onClose
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        onClose(reasonText ?? "WebSocket closed with code \(closeCode.rawValue).")
    }
}
