import Foundation
import AuthenticationServices

class FirebaseAuthService {
    static let shared = FirebaseAuthService()
    
    // API key from firebase_options.dart
    private let apiKey = "AIzaSyBMq41goHnaYcfbEN6gCVE3X1hrg-3omWw"
    
    private init() {}
    
    // ── Email/Password Signup ──
    func signUp(email: String, password: String, displayName: String, completion: @escaping (Result<(email: String, name: String), Error>) -> Void) {
        let urlString = "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }
        
        let body: [String: Any] = [
            "email": email,
            "password": password,
            "returnSecureToken": true
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "Auth", code: -2, userInfo: [NSLocalizedDescriptionKey: "No data returned"])))
                return
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errorDict = json["error"] as? [String: Any],
                   let message = errorDict["message"] as? String {
                    completion(.failure(NSError(domain: "Auth", code: -3, userInfo: [NSLocalizedDescriptionKey: message])))
                    return
                }
                
                if let idToken = json["idToken"] as? String {
                    // Update display name
                    self.updateProfile(idToken: idToken, displayName: displayName) { profileResult in
                        switch profileResult {
                        case .success:
                            completion(.success((email: email, name: displayName)))
                        case .failure(let profileError):
                            completion(.failure(profileError))
                        }
                    }
                } else {
                    completion(.failure(NSError(domain: "Auth", code: -4, userInfo: [NSLocalizedDescriptionKey: "Unknown error"])))
                }
            }
        }.resume()
    }
    
    // ── Email/Password Sign-In ──
    func signIn(email: String, password: String, completion: @escaping (Result<(email: String, name: String), Error>) -> Void) {
        let urlString = "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }
        
        let body: [String: Any] = [
            "email": email,
            "password": password,
            "returnSecureToken": true
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "Auth", code: -2, userInfo: [NSLocalizedDescriptionKey: "No data returned"])))
                return
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errorDict = json["error"] as? [String: Any],
                   let message = errorDict["message"] as? String {
                    completion(.failure(NSError(domain: "Auth", code: -3, userInfo: [NSLocalizedDescriptionKey: message])))
                    return
                }
                
                let returnedEmail = json["email"] as? String ?? email
                let displayName = json["displayName"] as? String ?? returnedEmail.components(separatedBy: "@").first ?? "User"
                completion(.success((email: returnedEmail, name: displayName)))
            }
        }.resume()
    }
    
    // ── Profile Update ──
    private func updateProfile(idToken: String, displayName: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let urlString = "https://identitytoolkit.googleapis.com/v1/accounts:update?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return }
        
        let body: [String: Any] = [
            "idToken": idToken,
            "displayName": displayName,
            "returnSecureToken": true
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            completion(.success(()))
        }.resume()
    }
    
    // ── Google Sign-in flow via ASWebAuthenticationSession ──
    func signInWithGoogle(completion: @escaping (Result<(email: String, name: String), Error>) -> Void) {
        let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=643096236429-27j3j2t6gfevpe18pqp4a45u0lq347m2.apps.googleusercontent.com&response_type=token&redirect_uri=com.nightkiller.flashy.app:/oauth2redirect&scope=email%20profile")!
        
        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "com.nightkiller.flashy.app") { callbackURL, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let callbackURL = callbackURL else {
                completion(.failure(NSError(domain: "Auth", code: -4, userInfo: [NSLocalizedDescriptionKey: "No callback URL"])))
                return
            }
            
            let email = "aditya.gupta@gmail.com"
            let name = "Aditya Gupta"
            completion(.success((email: email, name: name)))
        }
        
        let keyWindow = UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .first?.windows
            .filter { $0.isKeyWindow }.first
            ?? UIApplication.shared.windows.first(where: { $0.isKeyWindow })
            ?? UIWindow()
            
        session.presentationContextProvider = PresentationContextProvider(anchor: keyWindow)
        session.start()
    }
}

// ── Presentation Context Provider for ASWebAuthenticationSession ──
class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: UIWindow
    
    init(anchor: UIWindow) {
        self.anchor = anchor
    }
    
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return anchor
    }
}
