import SwiftUI
import QuickLook

struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedTab: FilterTab = .all
    @State private var previewItem: PreviewItem? = nil
    
    enum FilterTab: String, CaseIterable {
        case all = "All"
        case sent = "Sent"
        case received = "Received"
    }
    
    var filteredLogs: [TransferLog] {
        switch selectedTab {
        case .all:
            return appState.transferHistory
        case .sent:
            return appState.transferHistory.filter { $0.isSending }
        case .received:
            return appState.transferHistory.filter { !$0.isSending }
        }
    }
    
    var body: some View {
        ZStack {
            // Cream background
            FTheme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // ── Dark ink header ──
                HStack(spacing: 12) {
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        Circle()
                            .fill(FTheme.primary.opacity(0.2))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Image(systemName: "arrow.left")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(FTheme.primary)
                            )
                    }
                    
                    Text("Transfer History")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        Circle()
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(FTheme.ink)
                .clipShape(RoundedShape(corners: [.bottomLeft, .bottomRight], radius: 32))
                
                // ── Content ──
                VStack(spacing: 16) {
                    // Filter Tabs
                    HStack(spacing: 8) {
                        ForEach(FilterTab.allCases, id: \.self) { tab in
                            Button(action: { selectedTab = tab }) {
                                Text(tab.rawValue)
                                    .font(.system(size: 12, weight: selectedTab == tab ? .bold : .medium))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(selectedTab == tab ? FTheme.primary : FTheme.card)
                                    .foregroundColor(selectedTab == tab ? FTheme.ink : FTheme.foreground)
                                    .cornerRadius(20)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20)
                                            .stroke(selectedTab == tab ? FTheme.primary : FTheme.border, lineWidth: 1)
                                    )
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    
                    // History List
                    ScrollView {
                        if filteredLogs.isEmpty {
                            VStack(spacing: 12) {
                                Spacer().frame(height: 60)
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 44))
                                    .foregroundColor(FTheme.muted.opacity(0.3))
                                Text("No transfer history yet")
                                    .font(.system(size: 13))
                                    .foregroundColor(FTheme.muted)
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredLogs) { log in
                                    Button(action: { openFilePreview(log: log) }) {
                                        HStack(spacing: 12) {
                                            // Status icon circle
                                            Circle()
                                                .fill(
                                                    log.status == "Completed"
                                                    ? (log.isSending ? FTheme.primary.opacity(0.15) : FTheme.success.opacity(0.15))
                                                    : FTheme.destructive.opacity(0.15)
                                                )
                                                .frame(width: 44, height: 44)
                                                .overlay(
                                                    Image(systemName:
                                                        log.status == "Completed"
                                                        ? (log.isSending ? "arrow.up.right" : "arrow.down.left")
                                                        : "exclamationmark"
                                                    )
                                                    .font(.system(size: 14, weight: .bold))
                                                    .foregroundColor(
                                                        log.status == "Completed"
                                                        ? (log.isSending ? FTheme.primary : FTheme.success)
                                                        : FTheme.destructive
                                                    )
                                                )
                                            
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(log.fileName)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundColor(FTheme.foreground)
                                                    .lineLimit(1)
                                                    .multilineTextAlignment(.leading)
                                                
                                                Text(log.isSending ? "Sent to \(log.peerName)" : "Received from \(log.peerName)")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(FTheme.muted)
                                            }
                                            
                                            Spacer()
                                            
                                            VStack(alignment: .trailing, spacing: 4) {
                                                Text(log.status == "Completed" ? "Success" : "Failed")
                                                    .font(.system(size: 11, weight: .bold))
                                                    .foregroundColor(log.status == "Completed" ? FTheme.success : FTheme.destructive)
                                                
                                                HStack(spacing: 4) {
                                                    Text(formatBytes(log.size))
                                                        .font(.system(size: 11))
                                                        .foregroundColor(FTheme.muted)
                                                    
                                                    Circle()
                                                        .fill(FTheme.muted.opacity(0.3))
                                                        .frame(width: 3, height: 3)
                                                    
                                                    Text(formatDate(log.date))
                                                        .font(.system(size: 11))
                                                        .foregroundColor(FTheme.muted)
                                                }
                                            }
                                        }
                                        .padding(12)
                                        .background(FTheme.card)
                                        .cornerRadius(16)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16)
                                                .stroke(FTheme.border, lineWidth: 1)
                                        )
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(item: $previewItem) { item in
            QuickLookController(url: item.url)
        }
    }
    
    func openFilePreview(log: TransferLog) {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let documentsDirectory = paths.first else { return }
        let fileUrl = documentsDirectory.appendingPathComponent(log.fileName)
        
        if FileManager.default.fileExists(atPath: fileUrl.path) {
            self.previewItem = PreviewItem(url: fileUrl)
        }
    }
    
    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// QuickLook SwiftUI View Wrapper
struct QuickLookController: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }
    
    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        
        init(url: URL) {
            self.url = url
        }
        
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }
        
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

struct HistoryView_Previews: PreviewProvider {
    static var previews: some View {
        HistoryView()
            .environmentObject(AppState())
    }
}
