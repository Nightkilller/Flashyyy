import Foundation

class WebSocketSignalingClient {
    private weak var appState: AppState?
    private var webSocketTask: URLSessionWebSocketTask?
    private let serverUrl = URL(string: "ws://localhost:3000")! // Standardized on port 3000
    private var isConnected = false
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    func connect() {
        guard !isConnected else { return }
        
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: serverUrl)
        self.webSocketTask = task
        
        task.resume()
        self.isConnected = true
        self.appState?.isCloudConnected = true
        
        receiveMessage()
        sendRegistration()
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        self.isConnected = false
        self.appState?.isCloudConnected = false
    }
    
    private func sendRegistration() {
        guard let email = appState?.currentUserEmail else { return }
        let payload: [String: Any] = [
            "type": "register",
            "email": email,
            "deviceName": appState?.localDeviceName ?? "iOS Device"
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let string = String(data: data, encoding: .utf8) {
            sendMessage(string)
        }
    }
    
    func sendMessage(_ text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("WebSocket send error: \(error)")
            }
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingPayload(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingPayload(text)
                    }
                @unknown default:
                    break
                }
                // Continue listening
                self.receiveMessage()
                
            case .failure(let error):
                print("WebSocket receive error: \(error)")
                self.disconnect()
            }
        }
    }
    
    private func handleIncomingPayload(_ text: String) {
        // Parse messages (e.g. signaling offers, sync updates)
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return }
        
        guard let type = json["type"] as? String else { return }
        
        if type == "offer",
           let sender = json["senderName"] as? String,
           let fileName = json["fileName"] as? String,
           let fileSize = json["fileSize"] as? String {
            // Post notification to trigger alert view in ReceiveView
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("IncomingTransferReceived"),
                    object: nil,
                    userInfo: ["fileName": fileName, "fileSize": fileSize, "sender": sender]
                )
            }
        }
    }
}
