import SwiftUI
import MultiharnessClient

struct NewWorkspaceSheet: View {
    @Bindable var connection: ConnectionStore
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var baseBranch: String = ""
    @State private var projectId: String = ""
    @State private var providerId: String = ""
    @State private var modelId: String = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Workspace name", text: $name)
                    Picker("Project", selection: $projectId) {
                        ForEach(connection.projects) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    TextField("Base branch (e.g. main)", text: $baseBranch)
                }
                Section("Model") {
                    Picker("Provider", selection: $providerId) {
                        ForEach(connection.providers) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    TextField("Model id (e.g. anthropic/claude-sonnet-4-6)",
                              text: $modelId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if let err = error {
                    Section { Text(err).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(working || !canCreate)
                }
            }
        }
        .onAppear {
            projectId = connection.projects.first?.id ?? ""
            providerId = connection.providers.first?.id ?? ""
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !modelId.trimmingCharacters(in: .whitespaces).isEmpty
        && !projectId.isEmpty && !providerId.isEmpty
    }

    @MainActor
    private func create() async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await connection.createWorkspace(
                projectId: projectId,
                name: name,
                baseBranch: baseBranch,
                providerId: providerId,
                modelId: modelId
            )
            isPresented = false
        } catch {
            self.error = String(describing: error)
        }
    }
}

struct NewProjectSheet: View {
    @Bindable var connection: ConnectionStore
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var repoPath: String = ""
    @State private var baseBranch: String = "main"
    @State private var candidates: [(name: String, path: String)] = []
    @State private var loadingScan = false
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Pick a discovered repository") {
                    if loadingScan {
                        HStack { ProgressView(); Text("Scanning…").font(.caption) }
                    } else if candidates.isEmpty {
                        Text("No git repositories found in common locations.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates, id: \.path) { repo in
                            Button {
                                if name.isEmpty { name = repo.name }
                                repoPath = repo.path
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(repo.name).font(.body)
                                        Text(repo.path).font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                    Spacer()
                                    if repoPath == repo.path {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.green)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("Or enter a path") {
                    TextField("Display name", text: $name)
                    TextField("/Users/<you>/dev/<repo>", text: $repoPath)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Default base branch", text: $baseBranch)
                }
                if let err = error {
                    Section { Text(err).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        Task { await create() }
                    }
                    .disabled(working || !canCreate)
                }
            }
            .task { await scan() }
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !repoPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @MainActor
    private func scan() async {
        loadingScan = true
        defer { loadingScan = false }
        do {
            candidates = try await connection.scanRepos()
        } catch {
            self.error = String(describing: error)
        }
    }

    @MainActor
    private func create() async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await connection.createProject(
                name: name,
                repoPath: repoPath,
                defaultBaseBranch: baseBranch
            )
            isPresented = false
        } catch {
            self.error = String(describing: error)
        }
    }
}
