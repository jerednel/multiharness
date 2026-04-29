import Foundation

/// Generates short, friendly workspace names like "brave-otter" or
/// "swift-comet" for one-click quick-create. Two ~30-element word lists
/// give ~900 unique combinations before any collision-handling kicks in.
public enum RandomName {
    public static let adjectives: [String] = [
        "brave", "bright", "calm", "clever", "cosmic", "crisp", "daring",
        "eager", "fancy", "gentle", "happy", "humble", "jolly", "keen",
        "lively", "lucky", "mellow", "mighty", "noble", "plucky", "quick",
        "quiet", "silver", "snowy", "sunny", "swift", "tidy", "vivid",
        "warm", "witty",
    ]

    public static let nouns: [String] = [
        "otter", "comet", "lotus", "ember", "harbor", "river", "summit",
        "meadow", "forest", "lantern", "cipher", "anchor", "beacon",
        "dune", "echo", "falcon", "garnet", "hollow", "iris", "juniper",
        "kestrel", "lark", "moss", "nebula", "orchid", "pebble", "quartz",
        "raven", "sparrow", "willow",
    ]

    /// Returns a fresh `<adjective>-<noun>` slug. Deliberately not seeded
    /// so consecutive calls return different names within the same process.
    public static func generate() -> String {
        let adj = adjectives.randomElement() ?? "brave"
        let noun = nouns.randomElement() ?? "otter"
        return "\(adj)-\(noun)"
    }

    /// Returns a name that's not already in `existing`. Tries `generate()`
    /// up to `retries` times; if every attempt collides, suffixes the last
    /// attempt with `-2`, `-3`, … until unique.
    public static func generateUnique(
        avoiding existing: Set<String>,
        retries: Int = 5
    ) -> String {
        for _ in 0..<retries {
            let candidate = generate()
            if !existing.contains(candidate) { return candidate }
        }
        var base = generate()
        var n = 2
        while existing.contains("\(base)-\(n)") {
            n += 1
            if n > 999 { base = generate(); n = 2 }
        }
        return "\(base)-\(n)"
    }
}
