import SwiftUI

struct AuthView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.presentationMode) var presentationMode
    
    @State private var emailInput = ""
    @State private var passwordInput = ""
    @State private var isRegistering = false
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    
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
                    
                    Text("Account Portal")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(FTheme.ink)
                .clipShape(RoundedShape(corners: [.bottomLeft, .bottomRight], radius: 32))
                
                // ── Content ──
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer().frame(height: 20)
                        
                        // Icon + Title
                        VStack(spacing: 8) {
                            Circle()
                                .fill(FTheme.primary.opacity(0.2))
                                .frame(width: 72, height: 72)
                                .overlay(
                                    Image(systemName: "bolt.horizontal.circle.fill")
                                        .font(.system(size: 36))
                                        .foregroundColor(FTheme.primary)
                                )
                            
                            Text("Cloud Discovery Sync")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(FTheme.foreground)
                            Text("Link your account to auto-discover same-email devices")
                                .font(.system(size: 13))
                                .foregroundColor(FTheme.muted)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        
                        if let email = appState.currentUserEmail {
                            // Logged In Status Card
                            VStack(spacing: 16) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(FTheme.success)
                                    Text("Linked to Cloud")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(FTheme.foreground)
                                }
                                
                                Text(email)
                                    .font(.system(size: 15))
                                    .foregroundColor(FTheme.foreground.opacity(0.8))
                                
                                Button(action: handleLogout) {
                                    Text("Unlink Account")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundColor(FTheme.destructive)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 48)
                                        .background(FTheme.destructive.opacity(0.1))
                                        .cornerRadius(99)
                                }
                            }
                            .padding()
                            .background(FTheme.card)
                            .cornerRadius(24)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(FTheme.border, lineWidth: 1)
                            )
                            .padding(.horizontal)
                        } else {
                            // Login / Signup Form
                            VStack(spacing: 16) {
                                TextField("Email Address", text: $emailInput)
                                    .keyboardType(.emailAddress)
                                    .autocapitalization(.none)
                                    .padding()
                                    .background(FTheme.card)
                                    .cornerRadius(14)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(FTheme.border, lineWidth: 1)
                                    )
                                    .foregroundColor(FTheme.foreground)
                                
                                SecureField("Password", text: $passwordInput)
                                    .padding()
                                    .background(FTheme.card)
                                    .cornerRadius(14)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(FTheme.border, lineWidth: 1)
                                    )
                                    .foregroundColor(FTheme.foreground)
                                
                                if let error = errorMessage {
                                    Text(error)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(FTheme.destructive)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                
                                Button(action: handleAuth) {
                                    if isLoading {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: FTheme.ink))
                                    } else {
                                        Text(isRegistering ? "Create Account" : "Sign In & Sync")
                                            .font(.system(size: 15, weight: .bold, design: .rounded))
                                            .foregroundColor(FTheme.ink)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(FTheme.primary)
                                .cornerRadius(99)
                                .shadow(color: FTheme.primary.opacity(0.4), radius: 12, x: 0, y: 4)
                                .disabled(isLoading)
                                
                                Button(action: { isRegistering.toggle() }) {
                                    Text(isRegistering ? "Already have an account? Sign In" : "New to Flashy? Create Account")
                                        .font(.system(size: 13))
                                        .foregroundColor(FTheme.primary)
                                }
                                .padding(.top, 8)
                            }
                            .padding()
                            .background(FTheme.card)
                            .cornerRadius(24)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(FTheme.border, lineWidth: 1)
                            )
                            .padding(.horizontal)
                        }
                        
                        Spacer()
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            if let savedEmail = KeychainSecureStorage.shared.get("user_email") {
                appState.currentUserEmail = savedEmail
            }
        }
    }
    
    func handleAuth() {
        guard !emailInput.isEmpty && !passwordInput.isEmpty else {
            errorMessage = "Please fill in all fields"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.isLoading = false
            self.appState.currentUserEmail = self.emailInput
            KeychainSecureStorage.shared.save(key: "user_email", value: self.emailInput)
            self.presentationMode.wrappedValue.dismiss()
        }
    }
    
    func handleLogout() {
        appState.currentUserEmail = nil
        KeychainSecureStorage.shared.delete("user_email")
    }
}

struct AuthView_Previews: PreviewProvider {
    static var previews: some View {
        AuthView()
            .environmentObject(AppState())
    }
}
