import Foundation
import Network

/// Bonjour browser for `_multiharness._tcp.` services on the local network.
@Observable
final class DiscoveryBrowser {
    private var browser: NWBrowser?

    func start(onResults: @escaping ([DiscoveredHost]) -> Void) {
        stop()
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: "_multiharness._tcp.",
            domain: nil
        )
        let b = NWBrowser(for: descriptor, using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            let hosts: [DiscoveredHost] = results.compactMap { r in
                if case let .service(name, _, _, _) = r.endpoint {
                    return DiscoveredHost(id: name, name: name)
                }
                return nil
            }
            DispatchQueue.main.async { onResults(hosts) }
        }
        b.start(queue: .main)
        self.browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
