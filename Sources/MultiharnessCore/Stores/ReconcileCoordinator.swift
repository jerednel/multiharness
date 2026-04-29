import Foundation
import Observation
import MultiharnessClient

public enum ReconcileError: Error, CustomStringConvertible {
    case noEligibleWorkspaces
    case projectNotFound
    case noDefaultModelForProject
    case providerNotFound(UUID)
    case integrationCreateFailed(String)

    public var description: String {
        switch self {
        case .noEligibleWorkspaces:
            return "No workspaces are in Done or In review."
        case .projectNotFound:
            return "Project not found."
        case .noDefaultModelForProject:
            return "Set a default provider/model on the project before reconciling."
        case .providerNotFound(let id):
            return "Provider \(id) not found."
        case .integrationCreateFailed(let msg):
            return "Failed to create integration workspace: \(msg)"
        }
    }
}

@MainActor
@Observable
public final class ReconcileCoordinator {
    public enum Phase: Equatable {
        case ready
        case running(currentWorkspaceId: UUID?)
        case completed(integrationWorkspaceId: UUID)
        case aborted(integrationWorkspaceId: UUID?)
        case failed(message: String, integrationWorkspaceId: UUID?)
    }

    public struct WorkspaceProgress: Identifiable, Equatable {
        public let id: UUID
        public var name: String
        public var state: State
        public var log: [String]

        public enum State: Equatable {
            case pending
            case merging
            case resolving
            case committed
            case failed(String)
        }
    }

    public private(set) var phase: Phase = .ready
    public private(set) var rows: [WorkspaceProgress] = []

    private let env: AppEnvironment
    private let appStore: AppStore
    private let workspaceStore: WorkspaceStore
    private var aborted: Bool = false

    public init(env: AppEnvironment, appStore: AppStore, workspaceStore: WorkspaceStore) {
        self.env = env
        self.appStore = appStore
        self.workspaceStore = workspaceStore
    }

    public func prepare(project: Project) throws {
        let allWorkspaces = workspaceStore.workspaces
        let eligible = allWorkspaces
            .filter { $0.projectId == project.id }
            .filter { $0.archivedAt == nil }
            .filter { $0.lifecycleState == .done || $0.lifecycleState == .inReview }
            .sorted { $0.createdAt < $1.createdAt }
        guard !eligible.isEmpty else { throw ReconcileError.noEligibleWorkspaces }
        rows = eligible.map {
            WorkspaceProgress(id: $0.id, name: $0.name, state: .pending, log: [])
        }
        phase = .ready
    }

    public func abort() {
        aborted = true
    }

    public func start(project: Project) async {
        guard !rows.isEmpty else {
            phase = .failed(message: "No eligible workspaces.", integrationWorkspaceId: nil)
            return
        }

        // Resolve provider + model for the integration workspace.
        guard let providerId = project.defaultProviderId,
              let provider = appStore.providers.first(where: { $0.id == providerId }),
              let modelId = project.defaultModelId, !modelId.isEmpty else {
            phase = .failed(message: ReconcileError.noDefaultModelForProject.description, integrationWorkspaceId: nil)
            return
        }

        let integrationName = "_reconcile-\(Self.timestamp())"
        let integrationWorkspace: Workspace
        do {
            integrationWorkspace = try workspaceStore.create(
                project: project,
                name: integrationName,
                baseBranch: project.defaultBaseBranch,
                provider: provider,
                modelId: modelId,
                gitUserName: NSUserName(),
                buildMode: nil
            )
            workspaceStore.setLifecycle(integrationWorkspace, .inReview)
        } catch {
            phase = .failed(
                message: ReconcileError.integrationCreateFailed(String(describing: error)).description,
                integrationWorkspaceId: nil
            )
            return
        }

        let worktreePath = URL(fileURLWithPath: integrationWorkspace.worktreePath)
        let providerCfg = appStore.providerConfig(provider: provider, modelId: modelId)

        for i in rows.indices {
            if aborted {
                phase = .aborted(integrationWorkspaceId: integrationWorkspace.id)
                return
            }
            phase = .running(currentWorkspaceId: rows[i].id)
            // Look up the source workspace by id from the store.
            guard let source = workspaceStore.workspaces.first(where: { $0.id == rows[i].id }) else {
                rows[i].state = .failed("workspace not found")
                continue
            }
            await mergeOne(
                rowIndex: i,
                source: source,
                worktreePath: worktreePath,
                providerCfg: providerCfg
            )
        }

        // Bootstrap an agent session for the integration workspace.
        await appStore.bootstrapAllSessions(workspaces: [integrationWorkspace])
        appStore.selectedProjectId = project.id
        workspaceStore.selectedWorkspaceId = integrationWorkspace.id
        phase = .completed(integrationWorkspaceId: integrationWorkspace.id)
    }

    private func mergeOne(
        rowIndex: Int,
        source: Workspace,
        worktreePath: URL,
        providerCfg: [String: Any]
    ) async {
        rows[rowIndex].state = .merging

        let mergeResult: WorktreeService.MergeResult
        do {
            mergeResult = try env.worktree.merge(worktreePath: worktreePath, sourceBranch: source.branchName)
        } catch {
            rows[rowIndex].state = .failed("merge failed: \(error)")
            return
        }

        switch mergeResult {
        case .clean:
            do {
                try env.worktree.commit(worktreePath: worktreePath, message: "Reconcile: merge \(source.branchName)")
                rows[rowIndex].state = .committed
                rows[rowIndex].log.append("merged clean")
            } catch {
                rows[rowIndex].state = .failed("commit failed: \(error)")
            }

        case .conflicts(let unmergedFiles):
            rows[rowIndex].state = .resolving
            rows[rowIndex].log.append("\(unmergedFiles.count) files conflict")

            for file in unmergedFiles {
                if env.worktree.isLikelyBinary(worktreePath: worktreePath, path: file) {
                    rows[rowIndex].log.append("\(file): skipped (binary)")
                    continue
                }
                let absURL = worktreePath.appendingPathComponent(file)
                let content: String
                do {
                    content = try String(contentsOf: absURL, encoding: .utf8)
                } catch {
                    rows[rowIndex].log.append("\(file): unreadable")
                    continue
                }
                guard let client = env.control else {
                    rows[rowIndex].log.append("\(file): control client unavailable")
                    continue
                }
                let params: [String: Any] = [
                    "filePath": file,
                    "fileContext": content,
                    "providerConfig": providerCfg,
                ]
                do {
                    let raw = try await client.call(method: "agent.resolveConflictHunk", params: params)
                    guard let dict = raw as? [String: Any],
                          let outcome = dict["outcome"] as? String else {
                        rows[rowIndex].log.append("\(file): malformed RPC reply")
                        continue
                    }
                    if outcome == "resolved", let resolved = dict["content"] as? String {
                        try resolved.write(to: absURL, atomically: true, encoding: .utf8)
                        try env.worktree.stage(worktreePath: worktreePath, path: file)
                        rows[rowIndex].log.append("\(file): resolved")
                    } else if outcome == "declined" {
                        let reason = (dict["reason"] as? String) ?? "no reason"
                        rows[rowIndex].log.append("\(file): declined — \(reason)")
                    } else {
                        rows[rowIndex].log.append("\(file): unexpected outcome \(outcome)")
                    }
                } catch {
                    rows[rowIndex].log.append("\(file): RPC error \(error)")
                }
            }

            let stillUnmerged: [String]
            do {
                stillUnmerged = try env.worktree.unmergedFiles(worktreePath: worktreePath)
            } catch {
                stillUnmerged = []
            }
            if stillUnmerged.isEmpty {
                do {
                    try env.worktree.commit(worktreePath: worktreePath, message: "Reconcile: merge \(source.branchName)")
                    rows[rowIndex].state = .committed
                } catch {
                    rows[rowIndex].state = .failed("commit failed: \(error)")
                }
            } else {
                try? env.worktree.mergeAbort(worktreePath: worktreePath)
                rows[rowIndex].state = .failed("\(stillUnmerged.count) files need manual resolution")
            }
        }
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}
