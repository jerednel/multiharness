import SwiftUI

struct RootView: View {
    @Bindable var pairing: PairingStore
    @State private var showingAddPairing = false
    @State private var showingMacSwitcher = false

    var body: some View {
        NavigationStack {
            if let conn = pairing.connection, let active = pairing.activePairing {
                WorkspacesView(
                    connection: conn,
                    onUnpair: { pairing.forget(active.id) },
                    onSwitchMac: { showingMacSwitcher = true },
                    onAddMac: { showingAddPairing = true },
                    paired: pairing.pairings
                )
                .navigationTitle(active.name ?? "Multiharness")
            } else {
                PairingView(pairing: pairing)
                    .navigationTitle("Pair with Mac")
            }
        }
        .sheet(isPresented: $showingAddPairing) {
            NavigationStack {
                PairingView(pairing: pairing)
                    .navigationTitle("Add another Mac")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showingAddPairing = false }
                        }
                    }
            }
            // When the add-pairing flow finishes (PairingStore.connection
            // refreshes to the new Mac), auto-dismiss.
            .onChange(of: pairing.activePairingId) { _, _ in
                showingAddPairing = false
            }
        }
        .sheet(isPresented: $showingMacSwitcher) {
            NavigationStack {
                MacSwitcherView(pairing: pairing) {
                    showingMacSwitcher = false
                }
                .navigationTitle("Macs")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

private struct MacSwitcherView: View {
    @Bindable var pairing: PairingStore
    let onClose: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(pairing.pairings) { mac in
                    Button {
                        pairing.activate(mac.id)
                        onClose()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: pairing.activePairingId == mac.id
                                  ? "macbook.gen2"
                                  : "macbook")
                                .foregroundStyle(pairing.activePairingId == mac.id ? .blue : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mac.name ?? mac.host).font(.body)
                                Text("\(mac.host):\(mac.port)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if pairing.activePairingId == mac.id {
                                Text("connected").font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            pairing.forget(mac.id)
                        } label: {
                            Label("Forget", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Paired Macs")
            } footer: {
                Text("Swipe a row to forget that Mac.")
                    .font(.caption2)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { onClose() }
            }
        }
    }
}
