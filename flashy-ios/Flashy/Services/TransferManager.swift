import Foundation
import Network
import Combine

class TransferManager: ObservableObject {
    private weak var appState: AppState?
    private var activeConnection: NWConnection?
    private var fileWriteHandle: FileHandle?
    private var bytesReceived: Int64 = 0
    private var totalExpectedBytes: Int64 = 0
    private var activeTransferId: String = ""
    private var activeFileName: String = ""
    private var startTime: Date = Date()
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    // MARK: - Sender Flow
    func sendFile(url: URL, toDevice device: LanDevice) {
        let transferId = UUID().uuidString
        let fileName = url.lastPathComponent
        
        // Get file size natively
        guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = fileAttributes[.size] as? Int64 else { return }
        
        let initialTransfer = TransferProgress(
            id: transferId,
            fileName: fileName,
            totalSize: fileSize,
            bytesTransferred: 0,
            isSending: true,
            status: "Connecting",
            speed: 0.0
        )
        
        DispatchQueue.main.async {
            self.appState?.activeTransfers.append(initialTransfer)
        }
        
        // Connect to target device natively (routing IP vs Bonjour)
        let connection: NWConnection
        if device.ipAddress == "Bonjour" {
            connection = NWConnection(to: .service(name: device.name, type: "_flashy._tcp", domain: "local", interface: nil), using: .tcp)
        } else {
            let host = NWEndpoint.Host(device.ipAddress)
            let port = NWEndpoint.Port(rawValue: device.port) ?? NWEndpoint.Port(rawValue: 52345)!
            connection = NWConnection(host: host, port: port, using: .tcp)
        }
        self.activeConnection = connection
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("Connected to receiver, starting streaming")
                self.streamFile(url: url, size: fileSize, transferId: transferId, connection: connection)
            case .failed(let error):
                print("Connection failed: \(error)")
                self.updateTransferStatus(id: transferId, status: "Failed")
            default:
                break
            }
        }
        
        connection.start(queue: .global())
    }
    
    private func streamFile(url: URL, size: Int64, transferId: String, connection: NWConnection) {
        // Send initial protocol metadata frame (manifest)
        let manifest = "\(url.lastPathComponent)|\(size)\n"
        guard let metadataData = manifest.data(using: .utf8) else { return }
        
        connection.send(content: metadataData, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                print("Metadata send error: \(error)")
                self.updateTransferStatus(id: transferId, status: "Failed")
                return
            }
            
            // Read and stream file in chunks natively
            guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return }
            let chunkSize = 65536 // 64KB chunks
            var sentBytes: Int64 = 0
            let start = Date()
            
            func sendNextChunk() {
                let data: Data
                if #available(iOS 13.4, *) {
                    guard let chunk = try? fileHandle.read(upToCount: chunkSize) else {
                        try? fileHandle.close()
                        self.completeTransfer(id: transferId, size: size, peer: connection.endpoint.debugDescription, isSending: true)
                        return
                    }
                    data = chunk
                } else {
                    data = fileHandle.readData(ofLength: chunkSize)
                }
                
                if data.isEmpty {
                    try? fileHandle.close()
                    self.completeTransfer(id: transferId, size: size, peer: connection.endpoint.debugDescription, isSending: true)
                    return
                }
                
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        print("Chunk send error: \(error)")
                        self.updateTransferStatus(id: transferId, status: "Failed")
                        try? fileHandle.close()
                        return
                    }
                    
                    sentBytes += Int64(data.count)
                    let duration = Date().timeIntervalSince(start)
                    let currentSpeed = duration > 0 ? (Double(sentBytes) / 1024.0 / 1024.0) / duration : 0.0
                    
                    self.updateTransferProgress(id: transferId, bytes: sentBytes, speed: currentSpeed)
                    sendNextChunk()
                })
            }
            
            sendNextChunk()
        })
    }
    
    // MARK: - Receiver Flow
    func handleIncomingConnection(_ connection: NWConnection) {
        self.activeConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if state == .ready {
                self.receiveMetadata(connection: connection)
            }
        }
        connection.start(queue: .global())
    }
    
    private func receiveMetadata(connection: NWConnection) {
        // Read manifest line (ended with newline)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            if let data = data, let manifestString = String(data: data, encoding: .utf8) {
                let parts = manifestString.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
                if parts.count == 2, let size = Int64(parts[1]) {
                    self.activeFileName = parts[0]
                    self.totalExpectedBytes = size
                    self.bytesReceived = 0
                    self.activeTransferId = UUID().uuidString
                    self.startTime = Date()
                    
                    // Trigger SwiftUI UI alert on main thread
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("IncomingTransferReceived"),
                            object: nil,
                            userInfo: ["fileName": self.activeFileName, "fileSize": "\(size / 1024 / 1024) MB", "sender": "Nearby Device"]
                        )
                    }
                }
            }
        }
    }
    
    func acceptIncomingConnection() {
        guard let connection = activeConnection else { return }
        
        // Create local output file in App Documents folder
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let documentsDirectory = paths.first else { return }
        let fileUrl = documentsDirectory.appendingPathComponent(activeFileName)
        
        FileManager.default.createFile(atPath: fileUrl.path, contents: nil, attributes: nil)
        guard let handle = try? FileHandle(forWritingTo: fileUrl) else { return }
        self.fileWriteHandle = handle
        
        let initialTransfer = TransferProgress(
            id: activeTransferId,
            fileName: activeFileName,
            totalSize: totalExpectedBytes,
            bytesTransferred: 0,
            isSending: false,
            status: "Transferring",
            speed: 0.0
        )
        
        DispatchQueue.main.async {
            self.appState?.activeTransfers.append(initialTransfer)
        }
        
        readIncomingData(connection: connection)
    }
    
    private func readIncomingData(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                try? self.fileWriteHandle?.write(contentsOf: data)
                self.bytesReceived += Int64(data.count)
                
                let duration = Date().timeIntervalSince(self.startTime)
                let currentSpeed = duration > 0 ? (Double(self.bytesReceived) / 1024.0 / 1024.0) / duration : 0.0
                
                self.updateTransferProgress(id: self.activeTransferId, bytes: self.bytesReceived, speed: currentSpeed)
            }
            
            if isComplete || self.bytesReceived >= self.totalExpectedBytes {
                try? self.fileWriteHandle?.close()
                self.completeTransfer(id: self.activeTransferId, size: self.totalExpectedBytes, peer: "Nearby Device", isSending: false)
                connection.cancel()
            } else if let error = error {
                print("Receiver data error: \(error)")
                self.updateTransferStatus(id: self.activeTransferId, status: "Failed")
                try? self.fileWriteHandle?.close()
                connection.cancel()
            } else {
                self.readIncomingData(connection: connection)
            }
        }
    }
    
    // MARK: - State Updates
    private func updateTransferProgress(id: String, bytes: Int64, speed: Double) {
        DispatchQueue.main.async {
            if let idx = self.appState?.activeTransfers.firstIndex(where: { $0.id == id }) {
                self.appState?.activeTransfers[idx].bytesTransferred = bytes
                self.appState?.activeTransfers[idx].speed = speed
                self.appState?.activeTransfers[idx].status = "Transferring"
            }
        }
    }
    
    private func updateTransferStatus(id: String, status: String) {
        DispatchQueue.main.async {
            if let idx = self.appState?.activeTransfers.firstIndex(where: { $0.id == id }) {
                self.appState?.activeTransfers[idx].status = status
            }
        }
    }
    
    private func completeTransfer(id: String, size: Int64, peer: String, isSending: Bool) {
        DispatchQueue.main.async {
            if let idx = self.appState?.activeTransfers.firstIndex(where: { $0.id == id }) {
                let transfer = self.appState?.activeTransfers[idx]
                self.appState?.activeTransfers.remove(at: idx)
                
                // Add to history logs
                let log = TransferLog(
                    id: UUID().uuidString,
                    fileName: transfer?.fileName ?? "Unknown",
                    size: size,
                    date: Date(),
                    isSending: isSending,
                    peerName: peer,
                    status: "Completed"
                )
                self.appState?.addTransferLog(log)
            }
        }
    }
}
