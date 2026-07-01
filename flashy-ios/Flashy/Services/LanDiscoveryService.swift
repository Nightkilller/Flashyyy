import Foundation
import Network
import UIKit

class LanDiscoveryService {
    private weak var appState: AppState?
    private var browser: NWBrowser?
    private var listener: NWListener?
    private let serviceType = "_flashy._tcp"
    private let serviceName = UIDevice.current.name
    
    init(appState: AppState) {
        self.appState = appState
        if let state = self.appState {
            state.localDeviceName = serviceName
        }
    }
    
    func start() {
        startBrowsing()
        startAdvertising()
    }
    
    func stop() {
        browser?.cancel()
        listener?.cancel()
    }
    
    // Browse for nearby devices publishing our service type
    private func startBrowsing() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
        self.browser = browser
        
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Bonjour browser ready")
            case .failed(let error):
                print("Bonjour browser failed: \(error)")
                browser.cancel()
            default:
                break
            }
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            var devices: [LanDevice] = []
            
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint {
                    if name == self.serviceName { continue } // Skip self
                    
                    let device = LanDevice(
                        id: name,
                        name: name,
                        ipAddress: "Bonjour",
                        port: 52345,
                        isCloudLinked: false
                    )
                    devices.append(device)
                }
            }
            
            DispatchQueue.main.async {
                if !devices.isEmpty {
                    self.appState?.discoveredDevices = devices
                } else {
                    // Fall back to mock devices in simulator so preview works instantly
                    self.appState?.setupMockDevices()
                }
            }
        }
        
        browser.start(queue: .main)
    }
    
    // Advertise our presence via Bonjour
    private func startAdvertising() {
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            
            let listener = try NWListener(using: parameters)
            self.listener = listener
            
            listener.service = NWListener.Service(name: serviceName, type: serviceType)
            
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("Bonjour advertiser publishing service: \(self.serviceName)")
                case .failed(let error):
                    print("Bonjour advertiser failed: \(error)")
                    listener.cancel()
                default:
                    break
                }
            }
            
            listener.newConnectionHandler = { connection in
                // Handle incoming connection requests natively
                self.appState?.transferManager?.handleIncomingConnection(connection)
            }
            
            listener.start(queue: .main)
        } catch {
            print("Failed to start Bonjour advertiser listener: \(error)")
        }
    }
}
