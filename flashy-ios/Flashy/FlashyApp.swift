import SwiftUI

@main
struct FlashyApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .onAppear {
                    appState.startServices()
                }
        }
    }
}
