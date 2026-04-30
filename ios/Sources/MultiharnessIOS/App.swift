import SwiftUI

@main
struct MultiharnessIOSApp: App {
    @State private var pairing = PairingStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(pairing: pairing)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                pairing.connection?.didEnterForeground()
            case .background:
                pairing.connection?.didEnterBackground()
            case .inactive:
                // Transient (e.g., notification banner). Ignore.
                break
            @unknown default:
                break
            }
        }
    }
}
