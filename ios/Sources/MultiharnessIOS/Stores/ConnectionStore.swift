import Foundation
import Observation
import MultiharnessClient

/// One open WebSocket session against a paired Mac. Holds the live
/// `ControlClient`, the workspace list it has fetched, and per-workspace
/// agent stores keyed by workspaceId.
@MainActor
@Observable
public final class ConnectionStore: NSObject, ControlClientDelegate {
    public enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    public var state: State = .disconnected
    public var workspaces: [RemoteWorkspace] = []
    public var providers: [RemoteProvider] = []
    public var projects: [RemoteProject] = []
    public var agents: [String: RemoteAgentStore] = [:]
    public let host: String
    public let port: Int

    private let client: ControlClient

    public init(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        self.client = ControlClient(port: port, host: host, authToken: token)
        super.init()
        self.client.delegate = self
    }

    public func connect() {
        state = .connecting
        client.connect()
    }

    public func disconnect() {
        client.disconnect()
        state = .disconnected
    }

    public func refreshWorkspaces() async {
        do {
            // Custom RPC: ask Mac for workspaces. (We'll add this RPC server-side too.)
            let result = try await client.call(method: "remote.workspaces", params: [:])
                as? [String: Any]
            guard let arr = result?["workspaces"] as? [[String: Any]] else { return }
            self.workspaces = arr.compactMap(RemoteWorkspace.init(json:))
            if let ps = result?["projects"] as? [[String: Any]] {
                self.projects = ps.compactMap(RemoteProject.init(json:))
            }
            if let pv = result?["providers"] as? [[String: Any]] {
                self.providers = pv.compactMap(RemoteProvider.init(json:))
            }
        } catch {
            self.state = .error(String(describing: error))
        }
    }

    public func openWorkspace(_ ws: RemoteWorkspace) async {
        if agents[ws.id] != nil { return }
        let store = RemoteAgentStore(workspaceId: ws.id)
        // Pre-populate from history fetched from Mac.
        do {
            let result = try await client.call(
                method: "remote.history",
                params: ["workspaceId": ws.id]
            ) as? [String: Any]
            if let turns = result?["turns"] as? [[String: Any]] {
                store.turns = turns.compactMap(RemoteAgentStore.turn(from:))
            }
        } catch { /* non-fatal */ }
        agents[ws.id] = store
    }

    public func sendPrompt(workspaceId: String, message: String) async {
        let store = agents[workspaceId]
        store?.turns.append(ConversationTurn(role: .user, text: message))
        store?.isStreaming = true
        do {
            _ = try await client.call(
                method: "agent.prompt",
                params: ["workspaceId": workspaceId, "message": message]
            )
        } catch {
            store?.isStreaming = false
            store?.turns.append(ConversationTurn(
                role: .assistant,
                text: "⚠️ " + String(describing: error)
            ))
        }
    }

    // MARK: Mac-relayed mutations

    public func createWorkspace(
        projectId: String,
        name: String,
        baseBranch: String?,
        providerId: String,
        modelId: String,
        buildMode: BuildMode? = nil,
        makeProjectDefault: Bool = false
    ) async throws {
        var params: [String: Any] = [
            "projectId": projectId,
            "name": name,
            "providerId": providerId,
            "modelId": modelId,
        ]
        if let bb = baseBranch, !bb.isEmpty { params["baseBranch"] = bb }
        if let mode = buildMode { params["buildMode"] = mode.rawValue }
        if makeProjectDefault { params["makeProjectDefault"] = true }
        _ = try await client.call(method: "workspace.create", params: params)
        await refreshWorkspaces()
    }

    /// One-tap workspace creation. Asks the Mac to resolve inheritance via
    /// `workspace.quickCreate`. On `created` the workspace appears via the
    /// existing `workspace_updated`/refresh path. On `needs_input` the caller
    /// (WorkspacesView) opens NewWorkspaceSheet pre-filled with the
    /// suggestion.
    public func quickCreateWorkspace(projectId: String) async -> QuickCreateOutcome {
        do {
            guard let result = try await client.call(
                method: "workspace.quickCreate",
                params: ["projectId": projectId]
            ) as? [String: Any] else {
                return .failed("workspace.quickCreate: malformed response envelope")
            }
            let status = result["status"] as? String
            switch status {
            case "created":
                await refreshWorkspaces()
                return .created
            case "needs_input":
                guard let suggestedDict = result["suggested"] as? [String: Any],
                      let suggestion = WorkspaceSuggestion(json: suggestedDict) else {
                    return .failed("workspace.quickCreate: malformed needs_input payload")
                }
                return .needsInput(suggestion)
            default:
                return .failed("workspace.quickCreate: unexpected status '\(status ?? "nil")'")
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Display-name-only rename. Routed through the sidecar's
    /// `workspace.rename` (relayed to the Mac, which persists). The
    /// sidecar broadcasts a `workspace_updated` event after the relay
    /// returns, which our delegate handler picks up to refresh the local
    /// `workspaces` cache.
    public func requestRename(workspaceId: String, newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try await client.call(
            method: "workspace.rename",
            params: [
                "workspaceId": workspaceId,
                "name": trimmed,
            ]
        )
    }

    public func markViewed(workspaceId: String) async {
        do {
            _ = try await client.call(
                method: "workspace.markViewed",
                params: ["workspaceId": workspaceId]
            )
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            if let idx = workspaces.firstIndex(where: { $0.id == workspaceId }) {
                workspaces[idx] = workspaces[idx].withMarkViewed(at: now)
            }
        } catch {
            // Non-fatal — the next remote.workspaces refresh will reconcile.
        }
    }

    public func scanRepos() async throws -> [(name: String, path: String)] {
        let result = try await client.call(method: "project.scan", params: [:]) as? [String: Any]
        let arr = result?["repos"] as? [[String: Any]] ?? []
        return arr.compactMap { dict in
            guard let path = dict["path"] as? String,
                  let name = dict["name"] as? String else { return nil }
            return (name, path)
        }
    }

    public func listFolders(path: String?) async throws -> FolderListing {
        var params: [String: Any] = [:]
        if let p = path, !p.isEmpty { params["path"] = p }
        let result = try await client.call(method: "fs.list", params: params) as? [String: Any]
        let resolvedPath = (result?["path"] as? String) ?? (path ?? "")
        let parent = result?["parent"] as? String  // missing or NSNull → nil
        let arr = (result?["entries"] as? [[String: Any]]) ?? []
        let entries = arr.compactMap { dict -> FolderEntry? in
            guard let name = dict["name"] as? String,
                  let path = dict["path"] as? String else { return nil }
            let isGit = (dict["isGitRepo"] as? Bool) ?? false
            return FolderEntry(name: name, path: path, isGitRepo: isGit)
        }
        return FolderListing(path: resolvedPath, parent: parent, entries: entries)
    }

    public func fetchModels(providerId: String) async throws -> [DiscoveredModel] {
        let result = try await client.call(
            method: "models.listForProvider",
            params: ["providerId": providerId]
        ) as? [String: Any]
        let arr = (result?["models"] as? [[String: Any]]) ?? []
        return arr.compactMap { dict in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            return DiscoveredModel(id: id, name: dict["name"] as? String)
        }
    }

    public func listBranches(
        projectId: String,
        refresh: Bool = false
    ) async throws -> BranchListing {
        var params: [String: Any] = ["projectId": projectId]
        if refresh { params["refresh"] = true }
        let result = try await client.call(
            method: "project.listBranches", params: params
        ) as? [String: Any] ?? [:]

        let originRaw = result["origin"]
        let origin: [String]? = (originRaw is NSNull) ? nil : (originRaw as? [String])
        let local = (result["local"] as? [String]) ?? []
        let available = (result["originAvailable"] as? Bool) ?? false
        let reasonRaw = result["originUnavailableReason"] as? String
        let reason = reasonRaw.flatMap(BranchListing.OriginUnavailableReason.init(rawValue:))
        let fetchedAt = (result["fetchedAt"] as? Int64)
            ?? Int64((result["fetchedAt"] as? Double) ?? 0)
        return BranchListing(
            origin: origin,
            local: local,
            originAvailable: available,
            originUnavailableReason: reason,
            fetchedAt: fetchedAt
        )
    }

    /// Returns the new project's ID so the caller can preselect it in a
    /// follow-up "New workspace" flow.
    @discardableResult
    public func createProject(
        name: String,
        repoPath: String,
        defaultBaseBranch: String?
    ) async throws -> String? {
        var params: [String: Any] = [
            "name": name,
            "repoPath": repoPath,
        ]
        if let b = defaultBaseBranch, !b.isEmpty { params["defaultBaseBranch"] = b }
        let result = try await client.call(method: "project.create", params: params)
            as? [String: Any]
        let newId = result?["id"] as? String
        await refreshWorkspaces()
        return newId
    }

    public func updateProject(
        projectId: String,
        defaultBaseBranch: String
    ) async throws {
        _ = try await client.call(
            method: "project.update",
            params: [
                "projectId": projectId,
                "defaultBaseBranch": defaultBaseBranch,
            ]
        )
        await refreshWorkspaces()
    }

    // MARK: ControlClientDelegate

    nonisolated public func controlClient(_ client: ControlClient, didReceiveEvent event: AgentEventEnvelope) {
        if event.type == "workspace.activity" {
            let wsId = event.workspaceId
            let isStreaming = (event.payload["isStreaming"] as? Bool) ?? false
            let lastAssistantAt = RemoteWorkspace.int64(event.payload["lastAssistantAt"])
            Task { @MainActor in
                if let idx = self.workspaces.firstIndex(where: { $0.id == wsId }) {
                    self.workspaces[idx] = self.workspaces[idx].withActivity(
                        isStreaming: isStreaming,
                        lastAssistantAt: lastAssistantAt
                    )
                }
            }
            return
        }
        if event.type == "workspace_updated" {
            let wsId = event.workspaceId
            let newName = event.payload["name"] as? String
            Task { @MainActor in
                guard let newName, !newName.isEmpty else { return }
                if let idx = self.workspaces.firstIndex(where: { $0.id == wsId }) {
                    self.workspaces[idx] = self.workspaces[idx].withName(newName)
                }
            }
            return
        }
        Task { @MainActor in
            self.agents[event.workspaceId]?.handleEvent(event)
        }
    }

    nonisolated public func controlClientDidConnect(_ client: ControlClient) {
        Task { @MainActor in
            self.state = .connected
            await self.refreshWorkspaces()
        }
    }

    nonisolated public func controlClientDidDisconnect(_ client: ControlClient, error: Error?) {
        Task { @MainActor in
            self.state = .error(error.map { String(describing: $0) } ?? "disconnected")
        }
    }
}

public struct DiscoveredModel: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String?
    public var displayName: String { name ?? id }
}

public struct RemoteWorkspace: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let branchName: String
    public let baseBranch: String
    public let lifecycleState: String
    public let projectId: String
    public let contextInstructions: String
    public let lastViewedAt: Int64?
    public let lastAssistantAt: Int64?
    public let isStreaming: Bool

    /// Computed locally from `lastAssistantAt` and `lastViewedAt`. The
    /// sidecar provides an `unseen` field too, but we recompute so live
    /// `workspace.activity` events that only carry `lastAssistantAt`
    /// don't leave us stale.
    public var unseen: Bool {
        guard let last = lastAssistantAt else { return false }
        guard let viewed = lastViewedAt else { return true }
        return last > viewed
    }

    /// JSONSerialization on Apple platforms returns numbers as NSNumber/Int/Double
    /// depending on size; this normalizes to Int64? matching the sidecar's
    /// epoch-millisecond convention.
    fileprivate static func int64(_ v: Any?) -> Int64? {
        if let n = v as? Int64 { return n }
        if let n = v as? Int { return Int64(n) }
        if let n = v as? Double { return Int64(n) }
        return nil
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String,
              let branch = json["branchName"] as? String
        else { return nil }
        self.id = id
        self.name = name
        self.branchName = branch
        self.baseBranch = json["baseBranch"] as? String ?? ""
        self.lifecycleState = json["lifecycleState"] as? String ?? "in_progress"
        self.projectId = json["projectId"] as? String ?? ""
        self.contextInstructions = json["contextInstructions"] as? String ?? ""
        self.lastViewedAt = Self.int64(json["lastViewedAt"])
        self.lastAssistantAt = Self.int64(json["lastAssistantAt"])
        self.isStreaming = (json["isStreaming"] as? Bool) ?? false
    }

    init(
        id: String,
        name: String,
        branchName: String,
        baseBranch: String,
        lifecycleState: String,
        projectId: String,
        contextInstructions: String,
        lastViewedAt: Int64? = nil,
        lastAssistantAt: Int64? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.name = name
        self.branchName = branchName
        self.baseBranch = baseBranch
        self.lifecycleState = lifecycleState
        self.projectId = projectId
        self.contextInstructions = contextInstructions
        self.lastViewedAt = lastViewedAt
        self.lastAssistantAt = lastAssistantAt
        self.isStreaming = isStreaming
    }

    func withName(_ newName: String) -> RemoteWorkspace {
        RemoteWorkspace(
            id: id,
            name: newName,
            branchName: branchName,
            baseBranch: baseBranch,
            lifecycleState: lifecycleState,
            projectId: projectId,
            contextInstructions: contextInstructions,
            lastViewedAt: lastViewedAt,
            lastAssistantAt: lastAssistantAt,
            isStreaming: isStreaming
        )
    }

    func withActivity(isStreaming: Bool, lastAssistantAt: Int64?) -> RemoteWorkspace {
        RemoteWorkspace(
            id: id,
            name: name,
            branchName: branchName,
            baseBranch: baseBranch,
            lifecycleState: lifecycleState,
            projectId: projectId,
            contextInstructions: contextInstructions,
            lastViewedAt: lastViewedAt,
            lastAssistantAt: lastAssistantAt ?? self.lastAssistantAt,
            isStreaming: isStreaming
        )
    }

    func withMarkViewed(at ts: Int64) -> RemoteWorkspace {
        RemoteWorkspace(
            id: id,
            name: name,
            branchName: branchName,
            baseBranch: baseBranch,
            lifecycleState: lifecycleState,
            projectId: projectId,
            contextInstructions: contextInstructions,
            lastViewedAt: ts,
            lastAssistantAt: lastAssistantAt,
            isStreaming: isStreaming
        )
    }
}

public struct RemoteProject: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let defaultBaseBranch: String
    public let defaultBuildMode: BuildMode?
    public let contextInstructions: String
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String
        else { return nil }
        self.id = id
        self.name = name
        self.defaultBaseBranch = json["defaultBaseBranch"] as? String ?? "main"
        self.defaultBuildMode = (json["defaultBuildMode"] as? String).flatMap(BuildMode.init(rawValue:))
        self.contextInstructions = json["contextInstructions"] as? String ?? ""
    }
}

public struct RemoteProvider: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String
        else { return nil }
        self.id = id
        self.name = name
    }
}

public struct FolderEntry: Identifiable, Sendable, Hashable {
    public let name: String
    public let path: String
    public let isGitRepo: Bool
    public var id: String { path }
}

public struct FolderListing: Sendable {
    public let path: String
    public let parent: String?
    public let entries: [FolderEntry]
}

public struct WorkspaceSuggestion: Sendable, Equatable {
    public let name: String
    public let baseBranch: String?
    public let providerId: String?
    public let modelId: String?
    public let buildMode: BuildMode?

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        self.name = name
        self.baseBranch = json["baseBranch"] as? String
        self.providerId = json["providerId"] as? String
        self.modelId = json["modelId"] as? String
        self.buildMode = (json["buildMode"] as? String).flatMap(BuildMode.init(rawValue:))
    }
}

public enum QuickCreateOutcome: Sendable, Equatable {
    case created
    case needsInput(WorkspaceSuggestion)
    case failed(String)
}
