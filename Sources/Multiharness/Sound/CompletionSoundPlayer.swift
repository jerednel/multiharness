import AVFoundation
import os

/// Loads `agent-ding.wav` from the bundled SPM resources at init time and
/// exposes `play()`. Failures (missing asset, decode error) silently degrade
/// the feature to "no sound" — they log a warning to the unified log under
/// subsystem `com.multiharness`, category `sound`, and `play()` becomes a
/// no-op.
@MainActor
final class CompletionSoundPlayer {
    private let player: AVAudioPlayer?
    private let logger = Logger(subsystem: "com.multiharness", category: "sound")

    init(resourceName: String = "agent-ding", ext: String = "wav") {
        // SPM `.process("Resources")` for an executable target produces a
        // resource bundle co-located with the binary. `Bundle.main` resolves
        // it both when run via `swift run` (from the .build directory) and
        // when packaged into the .app bundle.
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: ext) else {
            logger.warning("CompletionSoundPlayer: \(resourceName).\(ext) not found in main bundle")
            self.player = nil
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            self.player = p
        } catch {
            logger.warning("CompletionSoundPlayer: load failed: \(String(describing: error))")
            self.player = nil
        }
    }

    func play() {
        guard let player else { return }
        // Cut off any in-flight playback and replay from start. Acceptable
        // behavior for back-to-back completions: the user still hears a chime.
        player.currentTime = 0
        player.play()
    }
}
