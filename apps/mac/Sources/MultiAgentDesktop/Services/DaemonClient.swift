import Foundation
import Observation

@Observable
@MainActor
final class DaemonClient {
    private var task: URLSessionWebSocketTask?
    var isConnected = false
    var isConnecting = false
    var onMessage: ((Data) -> Void)?

    func connect(port: Int = 3767) {
        guard task == nil else { return }
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        isConnecting = true
        task.resume()
        receiveNext()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
        isConnecting = false
    }

    func send(_ json: String) {
        task?.send(.string(json)) { error in
            if let error {
                print("WebSocket send failed: \(error)")
            }
        }
    }

    func sendRequest(id: String = UUID().uuidString, method: String, params: [String: Any]) {
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        send(json)
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(.data(let data)):
                    self.isConnected = true
                    self.isConnecting = false
                    self.onMessage?(data)
                    self.receiveNext()
                case .success(.string(let text)):
                    self.isConnected = true
                    self.isConnecting = false
                    self.onMessage?(Data(text.utf8))
                    self.receiveNext()
                case .failure(let error):
                    print("WebSocket receive failed: \(error)")
                    self.task = nil
                    self.isConnected = false
                    self.isConnecting = false
                @unknown default:
                    self.receiveNext()
                }
            }
        }
    }
}
