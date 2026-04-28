import SwiftUI
import MultiharnessCore

struct WorkspaceSidebar: View {
    @Bindable var workspaceStore: WorkspaceStore
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            ForEach(workspaceStore.grouped(), id: \.0) { (state, items) in
                Section(state.label) {
                    ForEach(items) { ws in
                        WorkspaceRow(ws: ws)
                            .tag(ws.id as UUID?)
                            .contextMenu {
                                ForEach(LifecycleState.allCases, id: \.self) { other in
                                    Button(other.label) {
                                        workspaceStore.setLifecycle(ws, other)
                                    }
                                    .disabled(other == ws.lifecycleState)
                                }
                                Divider()
                                Button("Archive (keep worktree)") {
                                    workspaceStore.archive(ws, removeWorktree: false)
                                }
                                Button("Archive + remove worktree", role: .destructive) {
                                    workspaceStore.archive(ws, removeWorktree: true)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct WorkspaceRow: View {
    let ws: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ws.name).font(.body)
            Text(ws.branchName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
