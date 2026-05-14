import SwiftUI
import MultiharnessClient

/// Structured render for the `qa_findings` event the sidecar emits when
/// the QA agent invokes `post_qa_findings`. Sits inside the QA group's
/// disclosure container alongside the read_file/grep tool calls.
///
/// Layout:
///
/// ```
/// 🔍 [verdict badge]
/// <summary text>
///
/// > 3 findings ▾   (collapsible list when present)
///   • 🛑 src/foo.ts:12  TODO left in
///   • ⚠️ src/bar.ts     missing test
/// ```
struct QaFindingsCard: View {
    let turn: ConversationTurn
    @State private var findingsExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var verdict: QaVerdict {
        turn.qaVerdict ?? .minorIssues  // benign fallback for unparseable verdicts
    }

    private var verdictAccent: Color {
        switch verdict {
        case .pass: return .green
        case .minorIssues: return .orange
        case .blockingIssues: return .red
        }
    }

    private var verdictGlyph: String {
        switch verdict {
        case .pass: return "checkmark.seal.fill"
        case .minorIssues: return "exclamationmark.triangle.fill"
        case .blockingIssues: return "octagon.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.cyan).font(.caption)
                Text("QA review").font(.caption).bold().foregroundStyle(.secondary)
                Spacer(minLength: 0)
                verdictBadge
            }

            if !turn.text.isEmpty {
                Text(turn.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !turn.qaFindings.isEmpty {
                findingsDisclosure
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.cyan.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(verdictAccent.opacity(0.3), lineWidth: 1)
        )
    }

    private var verdictBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: verdictGlyph)
            Text(verdict.label)
        }
        .font(.caption).bold()
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(verdictAccent, in: Capsule())
    }

    private var findingsDisclosure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(duration: reduceMotion ? 0 : 0.2)) {
                    findingsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                        .rotationEffect(.degrees(findingsExpanded ? 90 : 0))
                    Text(findingsSummary)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if findingsExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(turn.qaFindings) { f in
                        findingRow(f)
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    private var findingsSummary: String {
        let n = turn.qaFindings.count
        return "\(n) finding\(n == 1 ? "" : "s")"
    }

    private func findingRow(_ f: QaFinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: severityIcon(f.severity))
                .foregroundStyle(severityColor(f.severity))
                .font(.caption2)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                if let file = f.file {
                    HStack(spacing: 2) {
                        Text(file)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let line = f.line {
                            Text(":\(line)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(f.message)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
    }

    private func severityIcon(_ s: QaFinding.Severity) -> String {
        switch s {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .blocker: return "octagon"
        }
    }

    private func severityColor(_ s: QaFinding.Severity) -> Color {
        switch s {
        case .info: return .blue
        case .warning: return .orange
        case .blocker: return .red
        }
    }
}
