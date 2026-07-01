import SwiftUI
import UniformTypeIdentifiers

struct SendView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.presentationMode) var presentationMode
    
    @State private var showFilePicker = false
    @State private var selectedFileUrl: URL? = nil
    @State private var isScanning = true
    @State private var targetDevice: LanDevice? = nil
    
    var body: some View {
        ZStack {
            // Cream background
            FTheme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // ── Dark ink header ──
                VStack(spacing: 0) {
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
                        
                        Text("Send files")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        if isScanning {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: FTheme.primary))
                        }
                        
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
                }
                .background(FTheme.ink)
                .clipShape(RoundedShape(corners: [.bottomLeft, .bottomRight], radius: 32))
                
                // ── Content ──
                ScrollView {
                    VStack(spacing: 24) {
                        // File Selection Card
                        VStack(spacing: 16) {
                            if let selected = selectedFileUrl {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(FTheme.success)
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Image(systemName: "doc.fill")
                                                .font(.system(size: 18))
                                                .foregroundColor(.white)
                                        )
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(selected.lastPathComponent)
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(FTheme.foreground)
                                            .lineLimit(1)
                                        Text("Ready to beam · Choose a destination below")
                                            .font(.system(size: 11))
                                            .foregroundColor(FTheme.muted)
                                    }
                                    
                                    Spacer()
                                    
                                    Button(action: { selectedFileUrl = nil }) {
                                        Circle()
                                            .fill(FTheme.destructive.opacity(0.1))
                                            .frame(width: 32, height: 32)
                                            .overlay(
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundColor(FTheme.destructive)
                                            )
                                    }
                                }
                                .padding(16)
                                .background(FTheme.success.opacity(0.05))
                                .cornerRadius(24)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24)
                                        .stroke(FTheme.success.opacity(0.6), lineWidth: 2)
                                )
                            } else {
                                Button(action: { showFilePicker = true }) {
                                    VStack(spacing: 12) {
                                        RoundedRectangle(cornerRadius: 16)
                                            .fill(FTheme.primary)
                                            .frame(width: 48, height: 48)
                                            .overlay(
                                                Image(systemName: "plus")
                                                    .font(.system(size: 20, weight: .bold))
                                                    .foregroundColor(FTheme.ink)
                                            )
                                        
                                        Text("Drop files or click to pick")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(FTheme.foreground)
                                        Text("End-to-end encrypted · Up to 5 GB per beam")
                                            .font(.system(size: 11))
                                            .foregroundColor(FTheme.muted)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                                    .background(FTheme.primary.opacity(0.05))
                                    .cornerRadius(24)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 24)
                                            .stroke(FTheme.primary.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        
                        // Pick a destination
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Pick a destination")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(FTheme.foreground)
                                .padding(.horizontal, 16)
                            
                            if appState.discoveredDevices.isEmpty {
                                VStack(spacing: 12) {
                                    Spacer().frame(height: 20)
                                    Image(systemName: "radar")
                                        .font(.system(size: 40))
                                        .foregroundColor(FTheme.primary.opacity(0.3))
                                        .rotationEffect(.degrees(isScanning ? 360 : 0))
                                        .animation(isScanning ? Animation.linear(duration: 4).repeatForever(autoreverses: false) : .default, value: isScanning)
                                    Text("Scanning for nearby devices...")
                                        .font(.system(size: 13))
                                        .foregroundColor(FTheme.muted)
                                    Spacer().frame(height: 20)
                                }
                                .frame(maxWidth: .infinity)
                                .background(FTheme.card)
                                .cornerRadius(24)
                                .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 4)
                                .padding(.horizontal, 16)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(appState.discoveredDevices) { device in
                                        Button(action: {
                                            if selectedFileUrl != nil {
                                                self.targetDevice = device
                                                sendSelectedFile(to: device)
                                            }
                                        }) {
                                            HStack(spacing: 12) {
                                                RoundedRectangle(cornerRadius: 16)
                                                    .fill(selectedFileUrl != nil ? FTheme.primary.opacity(0.2) : FTheme.secondaryBg)
                                                    .frame(width: 44, height: 44)
                                                    .overlay(
                                                        Image(systemName: "laptopcomputer.and.iphone")
                                                            .font(.system(size: 16))
                                                            .foregroundColor(selectedFileUrl != nil ? FTheme.ink : FTheme.muted)
                                                    )
                                                
                                                VStack(alignment: .leading, spacing: 2) {
                                                    HStack(spacing: 6) {
                                                        Text(device.name)
                                                            .font(.system(size: 14, weight: .semibold))
                                                            .foregroundColor(FTheme.foreground)
                                                        if device.isCloudLinked {
                                                            Text("Linked")
                                                                .font(.system(size: 9, weight: .bold))
                                                                .padding(.horizontal, 6)
                                                                .padding(.vertical, 2)
                                                                .background(FTheme.success)
                                                                .cornerRadius(8)
                                                                .foregroundColor(.white)
                                                        }
                                                    }
                                                    Text(device.ipAddress)
                                                        .font(.system(size: 11))
                                                        .foregroundColor(FTheme.muted)
                                                }
                                                
                                                Spacer()
                                                
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundColor(FTheme.muted)
                                            }
                                            .padding(12)
                                            .background(FTheme.card)
                                            .cornerRadius(16)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 16)
                                                    .stroke(FTheme.border, lineWidth: 1)
                                            )
                                        }
                                        .disabled(selectedFileUrl == nil)
                                        .opacity(selectedFileUrl == nil ? 0.6 : 1.0)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        
                        // Active Transfers Progress
                        if !appState.activeTransfers.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("ACTIVE TRANSFERS")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(FTheme.muted)
                                    .tracking(1.5)
                                
                                ForEach(appState.activeTransfers) { transfer in
                                    VStack(spacing: 8) {
                                        HStack {
                                            Text(transfer.fileName)
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(FTheme.foreground)
                                                .lineLimit(1)
                                            Spacer()
                                            Text("\(Int(Double(transfer.bytesTransferred) / Double(transfer.totalSize) * 100))%")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(FTheme.primary)
                                        }
                                        
                                        ProgressView(value: Double(transfer.bytesTransferred), total: Double(transfer.totalSize))
                                            .accentColor(FTheme.primary)
                                        
                                        HStack {
                                            Text(transfer.status)
                                                .font(.system(size: 11))
                                                .foregroundColor(FTheme.muted)
                                            Spacer()
                                            Text(String(format: "%.1f MB/s", transfer.speed))
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(FTheme.foreground)
                                        }
                                    }
                                    .padding()
                                    .background(FTheme.card)
                                    .cornerRadius(16)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .stroke(FTheme.border, lineWidth: 1)
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                    }
                    .padding(.top, 16)
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    let _ = url.startAccessingSecurityScopedResource()
                    self.selectedFileUrl = url
                }
            case .failure(let error):
                print("Error picking file: \(error.localizedDescription)")
            }
        }
        .navigationBarHidden(true)
    }
    
    func sendSelectedFile(to device: LanDevice) {
        guard let fileUrl = selectedFileUrl else { return }
        appState.transferManager?.sendFile(url: fileUrl, toDevice: device)
        selectedFileUrl = nil
    }
}

struct SendView_Previews: PreviewProvider {
    static var previews: some View {
        SendView()
            .environmentObject(AppState())
    }
}
