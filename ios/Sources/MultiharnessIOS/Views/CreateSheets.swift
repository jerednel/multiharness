import SwiftUI
import MultiharnessClient

struct NewWorkspaceSheet: View {
    @Bindable var connection: ConnectionStore
    @Binding var isPresented: Bool
    var preselectedProjectId: String? = nil

    @State private var name: String = ""
    @State private var baseBranch: String = ""
    @State private var projectId: String = ""
    @State private var providerId: String = ""
    @State private var modelId: String = ""
    @State private var manualMode = false
    @State private var loadedModels: [DiscoveredModel] = []
    @State private var loadingModels = false
    @State private var modelLoadError: String?
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
                Section {
                    Picker("Provider", selection: $providerId) {
                        ForEach(connection.providers) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    if manualMode {
                        TextField("Model id (e.g. anthropic/claude-sonnet-4-6)",
                                  text: $modelId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else if loadingModels {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading models…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let err = modelLoadError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    } else if loadedModels.isEmpty {
                        Text("No models available for this provider.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $modelId) {
                            Text("Pick a model…").tag("")
                            ForEach(loadedModels) { m in
                                Text(m.displayName).tag(m.id)
                            }
                        }
                    }
                    Toggle("Enter model id manually", isOn: $manualMode)
                        .font(.caption)
                } header: {
                    HStack {
                        Text("Model")
                        Spacer()
                        if !manualMode {
                            Button {
                                Task { await loadModels() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(providerId.isEmpty || loadingModels)
                        }
                    }
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
            projectId = preselectedProjectId ?? connection.projects.first?.id ?? ""
            providerId = connection.providers.first?.id ?? ""
            Task { await loadModels() }
        }
        .onChange(of: providerId) { _, _ in
            modelId = ""
            loadedModels = []
            modelLoadError = nil
            Task { await loadModels() }
        }
    }

    @MainActor
    private func loadModels() async {
        guard !providerId.isEmpty, !manualMode else { return }
        loadingModels = true
        modelLoadError = nil
        defer { loadingModels = false }
        do {
            loadedModels = try await connection.fetchModels(providerId: providerId)
        } catch {
            modelLoadError = String(describing: error)
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
    /// Called with the new project's ID after a successful add. Lets the
    /// parent kick off a follow-up "New workspace" flow.
    var onCreated: ((String) -> Void)? = nil

    @State private var name: String = ""
    @State private var repoPath: String = ""
    @State private var baseBranch: String = "main"
    @State private var candidates: [(name: String, path: String)] = []
    @State private var loadingScan = false
    @State private var error: String?
    @State private var working = false
    @State private var browsePath = NavigationPath()

    var body: some View {
        NavigationStack(path: $browsePath) {
            Form {
                Section("Browse") {
                    NavigationLink(value: BrowseDestination.root) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Browse for a folder")
                            if !repoPath.isEmpty {
                                Text(repoPath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                    }
                }

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

                Section("Details") {
                    TextField("Display name", text: $name)
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
            .navigationDestination(for: BrowseDestination.self) { _ in
                BrowseFolderView(
                    connection: connection,
                    initialPath: nil,
                    onPick: { picked in
                        let basename = (picked as NSString).lastPathComponent
                        if name.isEmpty { name = basename }
                        repoPath = picked
                        browsePath = NavigationPath()
                    }
                )
            }
            .task { await scan() }
        }
    }

    private enum BrowseDestination: Hashable { case root }

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
            let newId = try await connection.createProject(
                name: name,
                repoPath: repoPath,
                defaultBaseBranch: baseBranch
            )
            if let newId { onCreated?(newId) }
            isPresented = false
        } catch {
            self.error = String(describing: error)
        }
    }
}
