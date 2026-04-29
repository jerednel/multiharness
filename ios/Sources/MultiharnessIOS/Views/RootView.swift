import SwiftUI

struct RootView: View {
    @Bindable var pairing: PairingStore

    var body: some View {
        NavigationStack {
            if let conn = pairing.connection {
                WorkspacesView(connection: conn, onUnpair: { pairing.unpair() })
                    .navigationTitle(pairing.pairing?.name ?? "Multiharness")
            } else {
                PairingView(pairing: pairing)
                    .navigationTitle("Pair with Mac")
            }
        }
    }
}
