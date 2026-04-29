import SwiftUI
import MultiharnessClient
import MultiharnessCore

struct ReconcileSheet: View {
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    let project: Project
    @Binding var isPresented: Bool

    @State private var coordinator: ReconcileCoordinator?
    @State private var prepareError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reconcile workspaces").font(.title2).bold()
            Text("Project: \(project.name)").foregroundStyle(.secondary)
            Divider()
            content
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 520, height: 540)
        .onAppear {
            let c = ReconcileCoordinator(env: appStore.appEnv, appStore: appStore, workspaceStore: workspaceStore)
            do {
                try c.prepare(project: project)
                coordinator = c
            } catch {
                prepareError = String(describing: error)
            }
        }
        .onDisappear {
            coordinator?.abort()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let err = prepareError {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                Text(err)
            }
        } else if let c = coordinator {
            switch c.phase {
            case .ready:
                triggerScreen(c)
            case .running, .completed, .aborted:
                progressScreen(c)
            case .failed(let message, _):
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                    Text(message)
                    if !c.rows.isEmpty {
                        Divider()
                        progressScreen(c)
                    }
                }
            }
        } else {
            ProgressView()
        }
    }

    private func triggerScreen(_ c: ReconcileCoordinator) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The following workspaces will merge into a new integration workspace, in this order:")
                .font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(c.rows.enumerated()), id: \.element.id) { idx, row in
                        Text("\(idx + 1). \(row.name)")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            Text("Conflicts will be resolved by your project's chosen model. Original workspaces are not modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func progressScreen(_ c: ReconcileCoordinator) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(c.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            stateGlyph(row.state)
                            Text(row.name)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(stateLabel(row.state)).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(row.log, id: \.self) { line in
                            Text("    \u{2022} \(line)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func stateGlyph(_ state: ReconcileCoordinator.WorkspaceProgress.State) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .merging, .resolving: ProgressView().controlSize(.small)
        case .committed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func stateLabel(_ state: ReconcileCoordinator.WorkspaceProgress.State) -> String {
        switch state {
        case .pending: return "pending"
        case .merging: return "merging\u{2026}"
        case .resolving: return "resolving\u{2026}"
        case .committed: return "merged"
        case .failed(let r): return "failed: \(r)"
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            if let c = coordinator {
                switch c.phase {
                case .ready:
                    Button("Cancel") { isPresented = false }
                    Button("Reconcile") {
                        Task { await c.start(project: project) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(c.rows.isEmpty)
                case .running:
                    Button("Abort") { c.abort() }
                case .completed(let id):
                    Button("Open integrated workspace") {
                        workspaceStore.selectedWorkspaceId = id
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Close") { isPresented = false }
                case .aborted, .failed:
                    Button("Close") { isPresented = false }
                }
            } else {
                Button("Cancel") { isPresented = false }
            }
        }
    }
}
