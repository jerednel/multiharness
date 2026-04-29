import SwiftUI
import MultiharnessClient

struct WorkspacesView: View {
    @Bindable var connection: ConnectionStore
    let onUnpair: () -> Void

    var body: some View {
        Group {
            switch connection.state {
            case .connecting:
                connectingView
            case .disconnected:
                connectingView
            case .error(let msg):
                errorView(msg)
            case .connected:
                listView
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        onUnpair()
                    } label: {
                        Label("Forget this Mac", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable { await connection.refreshWorkspaces() }
    }

    private var connectingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Connecting to \(connection.host):\(connection.port)…")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Couldn't connect").font(.title3).bold()
            Text(msg).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") {
                connection.connect()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var listView: some View {
        if connection.workspaces.isEmpty {
            ContentUnavailableView(
                "No workspaces",
                systemImage: "rectangle.split.3x1",
                description: Text("Create a workspace on your Mac to see it here.")
            )
        } else {
            List {
                ForEach(grouped(), id: \.0) { (state, items) in
                    Section(stateLabel(state)) {
                        ForEach(items) { ws in
                            NavigationLink(value: ws) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ws.name).font(.body)
                                    Text(ws.branchName).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: RemoteWorkspace.self) { ws in
                WorkspaceDetailView(connection: connection, workspace: ws)
            }
        }
    }

    private func grouped() -> [(String, [RemoteWorkspace])] {
        let order = ["in_progress", "in_review", "done", "backlog", "cancelled"]
        var buckets: [String: [RemoteWorkspace]] = [:]
        for w in connection.workspaces { buckets[w.lifecycleState, default: []].append(w) }
        return order.compactMap { state in
            guard let arr = buckets[state], !arr.isEmpty else { return nil }
            return (state, arr)
        }
    }

    private func stateLabel(_ s: String) -> String {
        switch s {
        case "in_progress": return "In progress"
        case "in_review": return "In review"
        case "done": return "Done"
        case "backlog": return "Backlog"
        case "cancelled": return "Cancelled"
        default: return s
        }
    }
}
