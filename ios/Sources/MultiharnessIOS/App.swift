import SwiftUI

@main
struct MultiharnessIOSApp: App {
    @State private var pairing = PairingStore()

    var body: some Scene {
        WindowGroup {
            RootView(pairing: pairing)
        }
    }
}
