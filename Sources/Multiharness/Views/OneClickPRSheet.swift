import SwiftUI
import AppKit
import MultiharnessClient
import MultiharnessCore

/// "Hit a button → PR is open in the browser" sheet.
///
/// Owns its own `PullRequestService` and a small state machine. Kicks
/// off the flow as soon as it appears so the user really does experience
/// it as a single click on the toolbar button.
struct OneClickPRSheet: View {
    let workspace: Workspace
    @Binding var isPresented: Bool

    @State private var phase: PullRequestService.Phase = .staging
    @State private var state: ScreenState = .running
    /// Captured at flow start so the in-progress checklist can show the
    /// right label for the final step ("Opening PR via `gh`" vs.
    /// "Building compare URL"). Updating this once at the top of
    /// `startFlow()` avoids a re-probe on every redraw.
    @State private var ghAvailable: Bool = true
    private let service = PullRequestService()

    private enum ScreenState {
        case running
        case done(PullRequestService.Outcome)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right.square")
                    .font(.title2).foregroundStyle(Color.accentColor)
                Text("Open Pull Request").font(.title2).bold()
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.caption)
                Text(workspace.branchName)
                    .font(.system(.callout, design: .monospaced))
                Text("→").foregroundStyle(.secondary)
                Text(workspace.baseBranch)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Divider()
            content
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 520, height: 380)
        .onAppear { startFlow() }
        .sheetEntry()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .running:
            VStack(alignment: .leading, spacing: 10) {
                stepRow(.staging, label: "Staging pending changes")
                stepRow(.committing, label: "Committing")
                stepRow(.pushing, label: "Pushing branch to origin")
                stepRow(
                    .opening,
                    label: ghAvailable
                        ? "Opening PR via `gh`"
                        : "Building GitHub compare URL"
                )
            }
        case .done(let outcome):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: outcome.didCreatePr
                          ? "checkmark.seal.fill"
                          : "arrow.up.right.circle.fill")
                        .foregroundStyle(outcome.didCreatePr ? .green : Color.accentColor)
                        .font(.title3)
                    Text(outcome.didCreatePr
                         ? "Pull request opened"
                         : "Branch pushed — click to open PR").font(.headline)
                }
                if !outcome.didCreatePr {
                    // Explain the fallback path so the user isn't left
                    // wondering why the PR didn't auto-open. One
                    // sentence — anything longer reads as an apology.
                    Text("`gh` isn't installed, so we couldn't create the PR for you. The branch is on GitHub; click below to open the create-PR form.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if outcome.didCommit, let msg = outcome.commitMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Swept \(outcome.stagedFiles.count) file\(outcome.stagedFiles.count == 1 ? "" : "s") into a commit:")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(msg)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                } else {
                    Text("Nothing new to commit — pushed existing branch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "link").foregroundStyle(Color.accentColor)
                    Text(outcome.pullRequestUrl)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow).font(.title3)
                    Text("Couldn't open PR").font(.headline)
                }
                ScrollView {
                    Text(msg)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func stepRow(_ p: PullRequestService.Phase, label: String) -> some View {
        HStack(spacing: 8) {
            stepGlyph(for: p)
            Text(label).font(.callout)
            Spacer()
        }
    }

    @ViewBuilder
    private func stepGlyph(for p: PullRequestService.Phase) -> some View {
        let myIdx = order(of: p)
        let curIdx = order(of: phase)
        if myIdx < curIdx {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if myIdx == curIdx {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private func order(of p: PullRequestService.Phase) -> Int {
        switch p {
        case .staging: return 0
        case .committing: return 1
        case .pushing: return 2
        case .opening: return 3
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch state {
            case .running:
                Button("Cancel") { isPresented = false }
            case .done(let outcome):
                Button("Close") { isPresented = false }
                Button {
                    if let url = URL(string: outcome.pullRequestUrl) {
                        NSWorkspace.shared.open(url)
                    }
                    isPresented = false
                } label: {
                    Label(
                        outcome.didCreatePr
                            ? "Open PR in browser"
                            : "Create PR on GitHub",
                        systemImage: "safari"
                    )
                }
                .keyboardShortcut(.defaultAction)
            case .failed:
                Button("Close") { isPresented = false }
                Button("Retry") { startFlow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Flow

    private func startFlow() {
        state = .running
        phase = .staging
        // Probe gh once up front. The orchestrator does its own probe
        // when deciding which branch to take; this copy is purely so
        // the in-progress checklist labels its final step correctly.
        ghAvailable = (service.locateGh() != nil)
        let svc = service
        let worktreePath = workspace.worktreePath
        let branch = workspace.branchName
        let base = workspace.baseBranch
        Task.detached {
            do {
                let outcome = try svc.openPullRequest(
                    worktreePath: worktreePath,
                    branch: branch,
                    baseBranch: base,
                    progress: { p in
                        Task { @MainActor in self.phase = p }
                    }
                )
                await MainActor.run { self.state = .done(outcome) }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                await MainActor.run { self.state = .failed(msg) }
            }
        }
    }
}
