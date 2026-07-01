import SwiftUI

struct ReceiveView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.presentationMode) var presentationMode
    @State private var pulseWave = false
    
    @State private var showIncomingPrompt = false
    @State private var incomingFileName = "Presentation.pdf"
    @State private var incomingFileSize = "4.2 MB"
    @State private var incomingSender = "MacBook Pro"
    
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
                    
                    Text("Receive files")
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
                VStack(spacing: 24) {
                    Spacer()
                    
                    // Pulsing Radar — lime/green
                    ZStack {
                        Circle()
                            .stroke(FTheme.primary.opacity(0.2), lineWidth: 1.5)
                            .frame(width: 250, height: 250)
                            .scaleEffect(pulseWave ? 1.3 : 0.8)
                            .opacity(pulseWave ? 0.0 : 1.0)
                        
                        Circle()
                            .stroke(FTheme.success.opacity(0.15), lineWidth: 1.5)
                            .frame(width: 200, height: 200)
                            .scaleEffect(pulseWave ? 1.4 : 0.7)
                            .opacity(pulseWave ? 0.0 : 1.0)
                        
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [FTheme.primary.opacity(0.1), FTheme.success.opacity(0.05)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 150, height: 150)
                        
                        VStack(spacing: 12) {
                            Image(systemName: "square.and.arrow.down.on.square.fill")
                                .font(.system(size: 32))
                                .foregroundColor(FTheme.primary)
                            
                            Text("Discoverable")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(FTheme.foreground)
                        }
                    }
                    .onAppear {
                        withAnimation(.easeOut(duration: 3.0).repeatForever(autoreverses: false)) {
                            pulseWave = true
                        }
                    }
                    
                    Spacer()
                    
                    // Device info banner
                    VStack(spacing: 8) {
                        Text("Visible to everyone on same network as:")
                            .font(.system(size: 12))
                            .foregroundColor(FTheme.muted)
                        
                        Text(appState.localDeviceName)
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .foregroundColor(FTheme.foreground)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(FTheme.card)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(FTheme.border, lineWidth: 1)
                            )
                    }
                    .padding(.bottom, 8)
                    
                    // Active Receive Transfers
                    let receivingTransfers = appState.activeTransfers.filter { !$0.isSending }
                    if !receivingTransfers.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("INCOMING TRANSFERS")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(FTheme.muted)
                                .tracking(1.5)
                            
                            ForEach(receivingTransfers) { transfer in
                                VStack(spacing: 8) {
                                    HStack {
                                        Text(transfer.fileName)
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(FTheme.foreground)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(Int(Double(transfer.bytesTransferred) / Double(transfer.totalSize) * 100))%")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(FTheme.success)
                                    }
                                    
                                    ProgressView(value: Double(transfer.bytesTransferred), total: Double(transfer.totalSize))
                                        .accentColor(FTheme.success)
                                    
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
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                    }
                }
                .padding(.vertical)
            }
            
            // Incoming file prompt
            if showIncomingPrompt {
                Color.black.opacity(0.4).ignoresSafeArea()
                
                VStack(spacing: 24) {
                    // Icon
                    Circle()
                        .fill(FTheme.primary.opacity(0.2))
                        .frame(width: 64, height: 64)
                        .overlay(
                            Image(systemName: "square.and.arrow.down.fill")
                                .font(.system(size: 28))
                                .foregroundColor(FTheme.primary)
                        )
                    
                    VStack(spacing: 8) {
                        Text("Incoming File")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(FTheme.foreground)
                        
                        Text("\(incomingSender) wants to send you a file")
                            .font(.system(size: 14))
                            .foregroundColor(FTheme.muted)
                    }
                    
                    // File specs
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(FTheme.primary.opacity(0.2))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Image(systemName: "doc.fill")
                                    .foregroundColor(FTheme.primary)
                            )
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(incomingFileName)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(FTheme.foreground)
                            Text("Size: \(incomingFileSize)")
                                .font(.system(size: 12))
                                .foregroundColor(FTheme.muted)
                        }
                        Spacer()
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(FTheme.secondaryBg.opacity(0.3))
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(FTheme.border, lineWidth: 1)
                    )
                    
                    HStack(spacing: 16) {
                        Button(action: { showIncomingPrompt = false }) {
                            Text("Decline")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(FTheme.destructive)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                        }
                        
                        Button(action: {
                            showIncomingPrompt = false
                            appState.transferManager?.acceptIncomingConnection()
                        }) {
                            Text("Accept & Save")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundColor(FTheme.ink)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(FTheme.primary)
                                .cornerRadius(99)
                        }
                    }
                }
                .padding(24)
                .background(FTheme.background)
                .cornerRadius(24)
                .shadow(color: Color.black.opacity(0.15), radius: 30, x: 0, y: 10)
                .padding(.horizontal, 32)
            }
        }
        .navigationBarHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("IncomingTransferReceived"))) { notif in
            if let userInfo = notif.userInfo,
               let name = userInfo["fileName"] as? String,
               let size = userInfo["fileSize"] as? String,
               let sender = userInfo["sender"] as? String {
                self.incomingFileName = name
                self.incomingFileSize = size
                self.incomingSender = sender
                self.showIncomingPrompt = true
            }
        }
    }
}

struct ReceiveView_Previews: PreviewProvider {
    static var previews: some View {
        ReceiveView()
            .environmentObject(AppState())
    }
}
