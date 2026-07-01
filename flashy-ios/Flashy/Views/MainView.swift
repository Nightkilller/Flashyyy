import SwiftUI
import CoreImage.CIFilterBuiltins

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @State private var activeTab: String = "home"
    @State private var showSendView = false
    
    var body: some View {
        if appState.currentUserEmail == nil && !appState.skippedLogin {
            WelcomeLoginView()
        } else {
            NavigationView {
                ZStack {
                    FTheme.background.ignoresSafeArea()
                    
                    VStack(spacing: 0) {
                        // Main Content based on active tab
                        if activeTab == "home" {
                            HomeTabView()
                        } else if activeTab == "qr" {
                            QRTabView()
                        }
                        
                        // Custom Bottom Nav Bar matching Android Flutter
                        CustomBottomNavBar(activeTab: $activeTab, showSendView: $showSendView)
                    }
                }
                .navigationBarHidden(true)
            }
            .navigationViewStyle(StackNavigationViewStyle())
            // Sheet overlay for SendView
            .sheet(isPresented: $showSendView) {
                SendView()
                    .environmentObject(appState)
            }
        }
    }
}

// ── 1. HOME TAB VIEW ──
struct HomeTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var isPulsing = false
    @State private var waveOffset = 0.0
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hero Card (dark ink)
                buildHeroCard()
                
                // Discovered Devices / LAN list
                buildTransfersList()
                    .padding(.horizontal, 16)
                
                // View History Button
                NavigationLink(destination: HistoryView()) {
                    HStack {
                        Image(systemName: "clock.fill")
                            .foregroundColor(FTheme.primary)
                        Text("View Transfer History")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(FTheme.foreground)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(FTheme.muted)
                    }
                    .padding()
                    .background(FTheme.card)
                    .cornerRadius(24)
                    .shadow(color: Color.black.opacity(0.04), radius: 12, x: 0, y: 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }
    
    @ViewBuilder
    func buildHeroCard() -> some View {
        ZStack(alignment: .topTrailing) {
            // Background Glow
            Circle()
                .fill(RadialGradient(
                    colors: [FTheme.primary.opacity(0.15), Color.clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 100
                ))
                .frame(width: 200, height: 200)
                .offset(x: 30, y: -40)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    // Avatar
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [FTheme.primary, FTheme.primaryGlow],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .overlay(
                            Text(String(appState.localDeviceName.prefix(1)).uppercased())
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .foregroundColor(FTheme.ink)
                        )
                    
                    Spacer()
                    
                    // Auth
                    NavigationLink(destination: AuthView()) {
                        Circle()
                            .fill(FTheme.primary.opacity(0.2))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Image(systemName: "person.crop.circle")
                                    .font(.system(size: 18))
                                    .foregroundColor(FTheme.primary)
                            )
                            .overlay(
                                Circle()
                                    .stroke(FTheme.primary.opacity(0.4), lineWidth: 1)
                            )
                    }
                }
                
                Text("FLASHY NETWORK")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(FTheme.primary)
                    .tracking(3)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome back,")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text(appState.localDeviceName.components(separatedBy: " ").first ?? "User")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundColor(FTheme.primary)
                }
                
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 12))
                        .foregroundColor(FTheme.primary)
                    
                    Text("End-to-end encrypted · \(appState.discoveredDevices.count) device\(appState.discoveredDevices.count != 1 ? "s" : "") on LAN")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
                
                HStack(spacing: 12) {
                    StatTile(label: "SENT TODAY", value: "\(appState.transferHistory.filter { $0.isSending }.count)")
                    StatTile(label: "RECEIVED", value: "\(appState.transferHistory.filter { !$0.isSending }.count)")
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
        .background(FTheme.ink)
        .clipShape(RoundedShape(corners: [.bottomLeft, .bottomRight], radius: 32))
        .shadow(color: FTheme.ink.opacity(0.35), radius: 30, x: 0, y: 10)
    }
    
    @ViewBuilder
    func buildTransfersList() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send to local devices")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(FTheme.foreground)
            
            if appState.discoveredDevices.isEmpty {
                VStack(spacing: 16) {
                    Spacer().frame(height: 16)
                    
                    ZStack {
                        Circle()
                            .fill(FTheme.primary.opacity(0.08))
                            .frame(width: 80, height: 80)
                            .scaleEffect(isPulsing ? 1.4 : 1.0)
                            .opacity(isPulsing ? 0.0 : 0.8)
                        
                        Circle()
                            .fill(FTheme.primary.opacity(0.15))
                            .frame(width: 50, height: 50)
                        
                        Image(systemName: "wifi")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(FTheme.primary)
                    }
                    .onAppear {
                        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: false)) {
                            isPulsing = true
                        }
                    }
                    
                    Text("Scanning local Wi-Fi for peers...")
                        .font(.system(size: 13))
                        .foregroundColor(FTheme.muted)
                    
                    Spacer().frame(height: 16)
                }
                .frame(maxWidth: .infinity)
            } else {
                ForEach(appState.discoveredDevices) { device in
                    NavigationLink(destination: SendView()) {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(FTheme.primary.opacity(0.15))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Image(systemName: "iphone")
                                        .font(.system(size: 18))
                                        .foregroundColor(FTheme.ink)
                                )
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(FTheme.foreground)
                                HStack(spacing: 4) {
                                    Image(systemName: "wifi")
                                        .font(.system(size: 10))
                                        .foregroundColor(FTheme.muted)
                                    Text(device.ipAddress)
                                        .font(.system(size: 11))
                                        .foregroundColor(FTheme.muted)
                                }
                            }
                            
                            Spacer()
                            
                            Text("Send")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(FTheme.primary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .padding(20)
        .background(FTheme.card)
        .cornerRadius(32)
        .shadow(color: Color.black.opacity(0.04), radius: 24, x: 0, y: 8)
    }
}

// ── 2. QR TAB VIEW ──
struct QRTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var showCameraScanner = false
    @State private var scanResult = ""
    @State private var manualCodeInput = ""
    @State private var showCopySuccess = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header Banner
                VStack(spacing: 4) {
                    Text("PAIR DEVICE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(FTheme.primary)
                        .tracking(3)
                        .padding(.top, 16)
                    
                    Text("Pair via QR Code")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundColor(FTheme.foreground)
                }
                
                // QR Info Panel matching Android layout
                VStack(spacing: 16) {
                    Text("THIS DEVICE")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(FTheme.muted)
                        .tracking(2)
                    
                    Text(appState.localDeviceName)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(FTheme.foreground)
                    
                    Text("\(String(appState.deviceId.prefix(8))) · ed25519")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(FTheme.muted)
                    
                    // Generate native QR Code
                    if let qrImage = generateQRCode(from: pairingString) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .padding(16)
                            .background(Color.white)
                            .cornerRadius(20)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(FTheme.primary.opacity(0.4), lineWidth: 2)
                            )
                            .shadow(color: FTheme.primary.opacity(0.3), radius: 30)
                    }
                    
                    // Copy Code Button
                    Button(action: {
                        UIPasteboard.general.string = pairingString
                        withAnimation {
                            showCopySuccess = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showCopySuccess = false
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: showCopySuccess ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 12))
                            Text(showCopySuccess ? "Copied!" : "flashy-pair:\(String(appState.deviceId.prefix(8)))...")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(FTheme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.04))
                        .cornerRadius(8)
                    }
                    
                    // Scan camera button
                    Button(action: {
                        showCameraScanner = true
                    }) {
                        HStack {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 18, weight: .bold))
                            Text("Scan another device")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(FTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(FTheme.primary)
                        .cornerRadius(99)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(20)
                .background(FTheme.card)
                .cornerRadius(24)
                .shadow(color: Color.black.opacity(0.04), radius: 24, x: 0, y: 8)
                .padding(.horizontal, 16)
                
                // Fallback manual pairing section matching Android
                VStack(alignment: .leading, spacing: 12) {
                    Text("MANUAL PAIRING (FALLBACK)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(FTheme.muted)
                        .tracking(1.5)
                    
                    HStack(spacing: 8) {
                        TextField("Paste flashy-pair: code here", text: $manualCodeInput)
                            .padding()
                            .font(.system(size: 12, design: .monospaced))
                            .background(FTheme.card)
                            .cornerRadius(12)
                            .foregroundColor(FTheme.foreground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(FTheme.border, lineWidth: 1)
                            )
                        
                        Button(action: handleManualPair) {
                            Circle()
                                .fill(FTheme.primary)
                                .frame(width: 48, height: 48)
                                .overlay(
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(FTheme.ink)
                                )
                                .shadow(color: FTheme.primary.opacity(0.3), radius: 6, x: 0, y: 3)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showCameraScanner) {
            QRScannerView { code in
                self.showCameraScanner = false
                processPairingCode(code)
            }
        }
    }
    
    var pairingString: String {
        return "flashy-pair:\(appState.deviceId):\(appState.publicKeyHex):\(appState.localDeviceName)"
    }
    
    func generateQRCode(from string: String) -> UIImage? {
        let data = string.data(using: .ascii)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        guard let ciImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledCIImage = ciImage.transformed(by: transform)
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledCIImage, from: scaledCIImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    
    func handleManualPair() {
        processPairingCode(manualCodeInput)
    }
    
    func processPairingCode(_ code: String) {
        guard code.hasPrefix("flashy-pair:") else { return }
        let parts = code.components(separatedBy: ":")
        guard parts.count >= 4 else { return }
        let peerId = parts[1]
        let peerKey = parts[2]
        let peerName = parts[3]
        
        // Add to discovered or paired devices log
        let newDevice = LanDevice(
            id: peerId,
            name: peerName,
            ipAddress: "Paired via QR",
            port: 52345,
            isCloudLinked: false
        )
        DispatchQueue.main.async {
            if !appState.discoveredDevices.contains(where: { $0.id == peerId }) {
                appState.discoveredDevices.append(newDevice)
            }
            manualCodeInput = ""
        }
    }
}

// ── 3. CUSTOM BOTTOM NAVIGATION BAR ──
struct CustomBottomNavBar: View {
    @Binding var activeTab: String
    @Binding var showSendView: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            Divider().background(FTheme.border)
            
            HStack {
                // Home Button
                Button(action: { activeTab = "home" }) {
                    VStack(spacing: 4) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 20))
                            .foregroundColor(activeTab == "home" ? FTheme.primary : .white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                }
                
                // Centered Floating Send Button
                Button(action: { showSendView = true }) {
                    Circle()
                        .fill(FTheme.primary)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 20))
                                .foregroundColor(FTheme.ink)
                        )
                        .shadow(color: FTheme.primary.opacity(0.4), radius: 10, x: 0, y: 4)
                }
                .offset(y: -4)
                
                // QR / Pair Button
                Button(action: { activeTab = "qr" }) {
                    VStack(spacing: 4) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 20))
                            .foregroundColor(activeTab == "qr" ? FTheme.primary : .white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 10)
            .padding(.bottom, UIApplication.shared.windows.first?.safeAreaInsets.bottom ?? 10)
            .background(FTheme.ink)
            .cornerRadius(24)
        }
        .ignoresSafeArea(.all, edges: .bottom)
    }
}
