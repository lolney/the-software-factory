import Foundation
import Observation

@Observable
final class DaemonClient {
    private var task: URLSessionWebSocketTask?
    var isConnected = false

    func connect(port: Int = 3767) {
        guard task == nil else { return }
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        isConnected = true
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
    }

    func send(_ json: String) {
        task?.send(.string(json)) { error in
            if let error {
                print("WebSocket send failed: \(error)")
            }
        }
    }
}
