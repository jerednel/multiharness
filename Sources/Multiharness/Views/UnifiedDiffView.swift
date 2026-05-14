import SwiftUI

/// Renders unified-diff text (the output of `git diff`) with red/green
/// coloring per line, similar to `git diff --color` in a terminal.
///
/// Heuristics, applied per line:
///   - `+++` / `---` file headers → secondary, bold
///   - `diff --git` / `index ` / `new file` / `deleted file` /
///     `similarity index` / `rename ` etc. → secondary
///   - `@@ ... @@` hunk headers → tertiary on a faint background
///   - `+` (but not `+++`) → green text on faint green background
///   - `-` (but not `---`) → red text on faint red background
///   - everything else (context) → primary
///
/// The whole thing is monospaced and uses fixed-width line gutter so
/// `+`/`-` markers align.
struct UnifiedDiffView: View {
    let diff: String

    var body: some View {
        if diff.isEmpty {
            Text("(no diff)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // We render every line as its own row so background fills work
            // edge-to-edge for + / - lines. Using LazyVStack keeps large
            // diffs from layout-thrashing the whole scroll view.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(parsedLines.enumerated()), id: \.offset) { _, line in
                    DiffLineView(line: line)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    private var parsedLines: [DiffLine] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).map(DiffLine.classify)
    }
}

/// One classified line of unified diff output. The `text` is the FULL
/// original line including its leading marker character, so the view
/// renders exactly what git emitted (the marker provides the visual cue
/// alongside the color).
struct DiffLine: Equatable {
    enum Kind: Equatable {
        case addition          // "+..."  (not "+++")
        case deletion          // "-..."  (not "---")
        case hunkHeader        // "@@ ... @@"
        case fileHeader        // "+++ b/foo", "--- a/foo"
        case meta              // "diff --git", "index", "new file", ...
        case context           // " ..."  or empty
    }

    let kind: Kind
    let text: Substring

    static func classify(_ line: Substring) -> DiffLine {
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            return DiffLine(kind: .fileHeader, text: line)
        }
        if line.hasPrefix("+") {
            return DiffLine(kind: .addition, text: line)
        }
        if line.hasPrefix("-") {
            return DiffLine(kind: .deletion, text: line)
        }
        if line.hasPrefix("@@") {
            return DiffLine(kind: .hunkHeader, text: line)
        }
        if line.hasPrefix("diff --git")
            || line.hasPrefix("index ")
            || line.hasPrefix("new file")
            || line.hasPrefix("deleted file")
            || line.hasPrefix("similarity index")
            || line.hasPrefix("rename ")
            || line.hasPrefix("copy ")
            || line.hasPrefix("Binary files")
            || line.hasPrefix("\\ No newline") {
            return DiffLine(kind: .meta, text: line)
        }
        return DiffLine(kind: .context, text: line)
    }
}

private struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        // Render an empty string as a non-empty space so the row still
        // has the right height — otherwise blank lines collapse and the
        // diff loses its vertical rhythm.
        let displayText = line.text.isEmpty ? " " : String(line.text)
        Text(displayText)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(background)
    }

    private var foreground: Color {
        switch line.kind {
        case .addition: return .green
        case .deletion: return .red
        case .hunkHeader: return Color.accentColor
        case .fileHeader: return .secondary
        case .meta: return .secondary
        case .context: return .primary
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: return Color.green.opacity(0.10)
        case .deletion: return Color.red.opacity(0.10)
        case .hunkHeader: return Color.accentColor.opacity(0.08)
        case .fileHeader, .meta, .context: return .clear
        }
    }
}
