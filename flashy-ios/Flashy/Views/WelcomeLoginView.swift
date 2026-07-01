import SwiftUI

struct WelcomeLoginView: View {
    @EnvironmentObject var appState: AppState
    @State private var showEmailSheet = false
    @State private var isAnimating = false
    @State private var waveOffset = 0.0
    
    var body: some View {
        ZStack {
            // Dark forest green background matching Android
            Color(red: 0.06, green: 0.09, blue: 0.07)
                .ignoresSafeArea()
            
            // ── Animated Wave Header at the Top ──
            VStack {
                GeometryReader { geo in
                    ZStack {
                        // Wave 1
                        WaveShape(offset: waveOffset, percent: 0.45)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        FTheme.primary.opacity(0.18),
                                        FTheme.primaryGlow.opacity(0.08)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        
                        // Wave 2
                        WaveShape(offset: waveOffset + .pi, percent: 0.42)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        FTheme.primary.opacity(0.12),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    .frame(height: geo.size.height * 0.45)
                }
                .frame(height: 300)
                .ignoresSafeArea(edges: .top)
                
                Spacer()
            }
            
            // ── Main Content Area ──
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                    .frame(height: 240)
                
                VStack(alignment: .leading, spacing: 8) {
                    // Big typography like Archivo Black
                    Text("WELCOME")
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .tracking(-1.5)
                        .lineSpacing(-10)
                    Text("TO FLASHY")
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .tracking(-1.5)
                        .lineSpacing(-10)
                }
                .padding(.horizontal, 28)
                
                Spacer().frame(height: 32)
                
                // Primary Button
                Button(action: {
                    showEmailSheet = true
                }) {
                    HStack {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 16, weight: .bold))
                        Text("Continue with email or phone")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(FTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(FTheme.primary)
                    .cornerRadius(28)
                }
                .padding(.horizontal, 28)
                
                Spacer().frame(height: 20)
                
                // "or" divider
                HStack {
                    Spacer()
                    Text("or")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                }
                
                Spacer().frame(height: 20)
                
                // Social buttons row
                HStack(spacing: 16) {
                    Spacer()
                    SocialButton(content: AnyView(
                        Image(systemName: "applelogo")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                    )) {
                        // Mock Apple Login
                        simulateSocialLogin(email: "apple.user@icloud.com")
                    }
                    
                    SocialButton(content: AnyView(
                        Text("G")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                    )) {
                        triggerGoogleLogin()
                    }
                    
                    SocialButton(content: AnyView(
                        Text("f")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(Color(red: 0.09, green: 0.47, blue: 0.95))
                            .offset(x: 2, y: 1)
                    )) {
                        simulateSocialLogin(email: "fb.user@facebook.com")
                    }
                    Spacer()
                }
                
                Spacer()
                
                // Skip Button
                VStack(spacing: 16) {
                    Button(action: {
                        withAnimation {
                            appState.skippedLogin = true
                        }
                    }) {
                        Text("Skip and use local P2P")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                            .underline()
                    }
                    
                    Text("By continuing you agree to Flashy's Terms & Privacy Policy.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.3))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                waveOffset = 2 * .pi
            }
        }
        .sheet(isPresented: $showEmailSheet) {
            EmailSignInSheetView()
                .environmentObject(appState)
        }
    }
    
    private func triggerGoogleLogin() {
        FirebaseAuthService.shared.signInWithGoogle { result in
            switch result {
            case .success(let user):
                DispatchQueue.main.async {
                    withAnimation {
                        appState.currentUserEmail = user.email
                        appState.currentUserDisplayName = user.name
                        appState.skippedLogin = true
                        KeychainSecureStorage.shared.save(key: "user_email", value: user.email)
                    }
                }
            case .failure(let error):
                print("Google Auth error: \(error)")
            }
        }
    }
    
    private func simulateSocialLogin(email: String) {
        withAnimation {
            appState.currentUserEmail = email
            appState.skippedLogin = true
            KeychainSecureStorage.shared.save(key: "user_email", value: email)
        }
    }
}

// ── Social Button ──
struct SocialButton: View {
    let content: AnyView
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(red: 0.07, green: 0.12, blue: 0.09))
                .frame(width: 56, height: 56)
                .overlay(
                    Circle()
                        .stroke(Color(red: 0.13, green: 0.20, blue: 0.15), lineWidth: 1.5)
                )
                .overlay(content)
        }
    }
}

// ── Wave Shape for Header ──
struct WaveShape: Shape {
    var offset: Double
    var percent: Double
    
    var animatableData: Double {
        get { offset }
        set { offset = newValue }
    }
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: height * percent))
        
        for x in stride(from: 0, through: width, by: 5) {
            let relativeX = x / width
            let sine = sin(relativeX * 3 * .pi + offset)
            let y = height * percent + sine * 12
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        path.addLine(to: CGPoint(x: width, y: 0))
        path.closeSubpath()
        
        return path
    }
}

// ── Email Sign-In Bottom Sheet View ──
struct EmailSignInSheetView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.presentationMode) var presentationMode
    
    @State private var emailInput = ""
    @State private var passwordInput = ""
    @State private var nameInput = ""
    @State private var isSignUp = true
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        ZStack {
            // Dark gray card-like background
            Color(red: 0.12, green: 0.12, blue: 0.12)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Header badge
                HStack(spacing: 6) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 10))
                        .foregroundColor(FTheme.primary)
                    Text("FIREBASE SECURE")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(.white.opacity(0.7))
                        .tracking(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
                .padding(.top, 16)
                
                Text(isSignUp ? "Create your account" : "Welcome back")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                
                Text(isSignUp ? "Sign up to link your devices and start sending." : "Sign in to access your linked devices.")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                
                VStack(spacing: 16) {
                    if isSignUp {
                        TextField("Full Name", text: $nameInput)
                            .padding()
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(14)
                            .foregroundColor(.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                    }
                    
                    TextField("Email Address", text: $emailInput)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .padding()
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(14)
                        .foregroundColor(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                    
                    SecureField("Password", text: $passwordInput)
                        .padding()
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(14)
                        .foregroundColor(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 24)
                
                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(FTheme.destructive)
                        .padding(.horizontal, 24)
                }
                
                // Submit Button
                Button(action: handleAuthSubmit) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: FTheme.ink))
                    } else {
                        Text(isSignUp ? "Sign Up" : "Sign In")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(FTheme.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(FTheme.primary)
                            .cornerRadius(14)
                    }
                }
                .padding(.horizontal, 24)
                .disabled(isLoading)
                
                // Toggle sign up / sign in
                Button(action: {
                    isSignUp.toggle()
                }) {
                    Text(isSignUp ? "Already have an account? Sign In" : "Need an account? Sign Up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FTheme.primary)
                }
                .padding(.bottom, 24)
            }
        }
    }
    
    private func handleAuthSubmit() {
        guard !emailInput.isEmpty && !passwordInput.isEmpty && (!isSignUp || !nameInput.isEmpty) else {
            errorMessage = "Please fill in all fields"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        if isSignUp {
            FirebaseAuthService.shared.signUp(email: emailInput, password: passwordInput, displayName: nameInput) { result in
                DispatchQueue.main.async {
                    self.isLoading = false
                    switch result {
                    case .success(let user):
                        self.appState.currentUserEmail = user.email
                        self.appState.currentUserDisplayName = user.name
                        self.appState.skippedLogin = true
                        KeychainSecureStorage.shared.save(key: "user_email", value: user.email)
                        self.presentationMode.wrappedValue.dismiss()
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        } else {
            FirebaseAuthService.shared.signIn(email: emailInput, password: passwordInput) { result in
                DispatchQueue.main.async {
                    self.isLoading = false
                    switch result {
                    case .success(let user):
                        self.appState.currentUserEmail = user.email
                        self.appState.currentUserDisplayName = user.name
                        self.appState.skippedLogin = true
                        KeychainSecureStorage.shared.save(key: "user_email", value: user.email)
                        self.presentationMode.wrappedValue.dismiss()
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}
