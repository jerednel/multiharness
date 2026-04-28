import XCTest
@testable import MultiharnessCore

/// Light-weight smoke checks for sidecar wiring.
///
/// A full end-to-end ControlClient ↔ sidecar test exists in
/// `sidecar/test/e2e.test.ts`. Replicating it on the Swift side would require
/// careful WebSocket open/close synchronization that's prone to flakiness;
/// the manual `bash scripts/build-app.sh && open dist/Multiharness.app` smoke
/// test exercises the full path (binary lookup → spawn → READY → WS connect →
/// agent.* RPCs).
@MainActor
final class SidecarIntegrationTests: XCTestCase {

    func testBinaryLookup() throws {
        // The binary may or may not exist; if it does, the lookup path must find it.
        let bin = SidecarManager.locateBinary()
        if let bin {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bin.path))
        } else {
            throw XCTSkip("multiharness-sidecar binary not built; run 'bash sidecar/scripts/build.sh'")
        }
    }
}
