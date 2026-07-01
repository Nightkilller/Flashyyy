import Foundation
import Combine

class AppState: ObservableObject {
    @Published var localDeviceName: String = "iOS Simulator"
    @Published var isLanConnected: Bool = true
    @Published var isCloudConnected: Bool = false
    @Published var discoveredDevices: [LanDevice] = []
    @Published var activeTransfers: [TransferProgress] = []
    @Published var transferHistory: [TransferLog] = []
    @Published var currentUserEmail: String? = nil
    @Published var currentUserDisplayName: String? = nil
    @Published var skippedLogin: Bool = false
    var deviceId: String = UUID().uuidString
    var publicKeyHex: String = "89a3f2d87e02bc81fa392810cd832101fa28bf93213"
    
    // Services (to be wired up)
    var discoveryService: LanDiscoveryService?
    var signalingClient: WebSocketSignalingClient?
    var transferManager: TransferManager?
    
    init() {
        // We will bind services dynamically in Phase 3
        loadHistory()
        setupMockDevices()
    }
    
    func startServices() {
        discoveryService = LanDiscoveryService(appState: self)
        signalingClient = WebSocketSignalingClient(appState: self)
        transferManager = TransferManager(appState: self)
        
        discoveryService?.start()
    }
    
    func setupMockDevices() {
        // Pre-populate some mock LAN devices for preview testing if Bonjour is not running yet
        self.discoveredDevices = [
            LanDevice(id: "1", name: "MacBook Pro (Aditya)", ipAddress: "192.168.1.15", port: 52345, isCloudLinked: true),
            LanDevice(id: "2", name: "iPhone 15 Pro", ipAddress: "192.168.1.18", port: 52345, isCloudLinked: false)
        ]
    }
    
    func loadHistory() {
        self.transferHistory = [
            TransferLog(id: "h1", fileName: "Project_Proposal.pdf", size: 4500000, date: Date().addingTimeInterval(-3600), isSending: false, peerName: "MacBook Pro", status: "Completed"),
            TransferLog(id: "h2", fileName: "Vacation_Video.mp4", size: 104000000, date: Date().addingTimeInterval(-86400), isSending: true, peerName: "Aditya's iPad", status: "Completed")
        ]
    }
    
    func addTransferLog(_ log: TransferLog) {
        transferHistory.insert(log, at: 0)
    }
}

struct LanDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let ipAddress: String
    let port: UInt16
    let isCloudLinked: Bool
}

struct TransferProgress: Identifiable {
    let id: String
    let fileName: String
    let totalSize: Int64
    var bytesTransferred: Int64
    var isSending: Bool
    var status: String // "Connecting", "Transferring", "Completed", "Failed"
    var speed: Double // MB/s
}

struct TransferLog: Identifiable {
    let id: String
    let fileName: String
    let size: Int64
    let date: Date
    let isSending: Bool
    let peerName: String
    let status: String
}
