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
        // Implemented in Task 6.
    }
}
