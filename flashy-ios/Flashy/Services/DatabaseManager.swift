import Foundation

class DatabaseManager {
    static let shared = DatabaseManager()
    
    private let fileName = "transfers_history.json"
    
    private init() {}
    
    private var fileURL: URL? {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths.first?.appendingPathComponent(fileName)
    }
    
    // Save history logs to local json database file
    func saveLogs(_ logs: [TransferLogCodable]) {
        guard let url = fileURL else { return }
        do {
            let data = try JSONEncoder().encode(logs)
            try data.write(to: url, options: .atomic)
            print("Successfully saved \(logs.count) transfer logs to JSON database.")
        } catch {
            print("Failed to save transfer logs: \(error.localizedDescription)")
        }
    }
    
    // Load history logs from local json database file
    func loadLogs() -> [TransferLogCodable] {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let logs = try JSONDecoder().decode([TransferLogCodable].self, from: data)
            return logs
        } catch {
            print("Failed to load transfer logs: \(error.localizedDescription)")
            return []
        }
    }
}

// Decodable matching TransferLog model
struct TransferLogCodable: Codable, Identifiable {
    let id: String
    let fileName: String
    let size: Int64
    let date: Date
    let isSending: Bool
    let peerName: String
    let status: String
}
