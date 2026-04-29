import SwiftUI
import AVFoundation

struct PairingView: View {
    @Bindable var pairing: PairingStore
    @State private var manualString: String = ""
    @State private var error: String?
    @State private var discovering: Bool = true
    @State private var discovered: [DiscoveredHost] = []
    @State private var browser = DiscoveryBrowser()
    @State private var showingScanner: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Pair with a Mac running Multiharness")
                    .font(.title3).bold()
                Text("Open Multiharness on your Mac, go to Settings → Remote access, enable it, and either scan the QR code below or paste the pairing string.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Section {
                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Section {
                    Text("Discovered on this network").font(.headline)
                    if discovered.isEmpty {
                        HStack {
                            ProgressView().scaleEffect(0.7)
                            Text("Looking for Multiharness Macs…")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(discovered) { host in
                            Text(host.name).font(.body)
                            Text("(no token info; use QR or paste below)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text("Or paste a pairing string").font(.headline)
                    TextField("mh://...", text: $manualString, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...6)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Pair") {
                        if !pairing.pair(with: manualString) {
                            error = "Couldn't parse that pairing string."
                        }
                    }
                    .disabled(manualString.isEmpty)
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showingScanner) {
            QRScannerView { code in
                showingScanner = false
                if !pairing.pair(with: code) {
                    error = "Scanned QR did not contain a valid Multiharness pairing string."
                }
            }
            .ignoresSafeArea()
        }
        .task { browser.start { hosts in self.discovered = hosts } }
        .onDisappear { browser.stop() }
    }
}

struct DiscoveredHost: Identifiable, Hashable {
    let id: String
    let name: String
}
