import SwiftUI
import MultiharnessCore
import AppKit

struct NewProjectSheet: View {
    @Bindable var appStore: AppStore
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var repoPath: String = ""
    @State private var baseBranch: String = "main"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New project").font(.title2).bold()
            Form {
                TextField("Name", text: $name)
                HStack {
                    TextField("Repo path", text: $repoPath)
                        .truncationMode(.head)
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Select repo"
                        if panel.runModal() == .OK, let url = panel.url {
                            repoPath = url.path
                            if name.isEmpty { name = url.lastPathComponent }
                        }
                    }
                }
                TextField("Default base branch", text: $baseBranch)
            }
            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || repoPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 520)
    }

    private func commit() {
        let trimmedPath = repoPath.trimmingCharacters(in: .whitespaces)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: trimmedPath, isDirectory: &isDir)
        guard exists, isDir.boolValue else {
            error = "Repo path does not exist or is not a directory."
            return
        }
        let gitDir = (trimmedPath as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else {
            error = "Selected directory is not a git repository (no .git found)."
            return
        }
        appStore.addProject(name: name, repoPath: trimmedPath, defaultBaseBranch: baseBranch)
        isPresented = false
    }
}

struct NewWorkspaceSheet: View {
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var baseBranch: String = ""
    @State private var providerId: UUID?
    @State private var modelId: String = ""
    @State private var error: String?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New workspace").font(.title2).bold()
            if let proj = appStore.selectedProject {
                Form {
                    LabeledContent("Project") { Text(proj.name) }
                    TextField("Workspace name", text: $name)
                    TextField("Base branch", text: $baseBranch, prompt: Text(proj.defaultBaseBranch))
                    Picker("Provider", selection: $providerId) {
                        ForEach(appStore.providers) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    TextField("Model id", text: $modelId, prompt: Text("e.g. openrouter/auto"))
                }
            } else {
                Text("No project selected").foregroundStyle(.secondary)
            }
            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") {
                    Task { await commit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(creating || !canCreate)
            }
        }
        .padding(24).frame(width: 540)
        .onAppear {
            if let proj = appStore.selectedProject, baseBranch.isEmpty {
                baseBranch = proj.defaultBaseBranch
            }
            if providerId == nil { providerId = appStore.providers.first?.id }
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !modelId.trimmingCharacters(in: .whitespaces).isEmpty
        && providerId != nil
        && appStore.selectedProject != nil
    }

    @MainActor
    private func commit() async {
        guard let proj = appStore.selectedProject,
              let pid = providerId,
              let provider = appStore.providers.first(where: { $0.id == pid }) else {
            error = "Missing project or provider"
            return
        }
        creating = true
        defer { creating = false }
        do {
            let userName = NSUserName()
            _ = try workspaceStore.create(
                project: proj,
                name: name,
                baseBranch: baseBranch.isEmpty ? proj.defaultBaseBranch : baseBranch,
                provider: provider,
                modelId: modelId,
                gitUserName: userName
            )
            isPresented = false
        } catch {
            self.error = String(describing: error)
        }
    }
}

struct SettingsSheet: View {
    @Bindable var appStore: AppStore
    @Binding var isPresented: Bool

    @State private var selectedPresetId: String = ""
    @State private var manualName: String = ""
    @State private var manualBaseUrl: String = ""
    @State private var manualKind: ProviderKind = .openaiCompatible
    @State private var apiKey: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Providers").font(.title2).bold()
            List {
                ForEach(appStore.providers) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.body)
                            HStack(spacing: 8) {
                                Text(p.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                                if let pi = p.piProvider { Text(pi).font(.caption2).foregroundStyle(.secondary) }
                                if let url = p.baseUrl { Text(url).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            appStore.removeProvider(p)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(minHeight: 140, maxHeight: 200)
            Divider()
            Text("Add provider").font(.headline)
            Picker("Preset", selection: $selectedPresetId) {
                Text("Custom…").tag("")
                ForEach(ProviderPreset.builtins) { preset in
                    Text(preset.displayName).tag(preset.id)
                }
            }
            .onChange(of: selectedPresetId) { _, new in applyPreset(new) }
            Form {
                TextField("Display name", text: $manualName)
                Picker("Kind", selection: $manualKind) {
                    Text("OpenAI-compatible").tag(ProviderKind.openaiCompatible)
                    Text("Anthropic").tag(ProviderKind.anthropic)
                    Text("pi-known").tag(ProviderKind.piKnown)
                }
                if manualKind != .piKnown {
                    TextField("Base URL", text: $manualBaseUrl)
                }
                SecureField("API key (stored in Keychain)", text: $apiKey)
            }
            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                Button("Add") { addProvider() }
                    .disabled(manualName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 600, height: 620)
    }

    private func applyPreset(_ id: String) {
        guard let preset = ProviderPreset.builtins.first(where: { $0.id == id }) else { return }
        manualName = preset.displayName
        manualKind = preset.kind
        manualBaseUrl = preset.baseUrl ?? ""
    }

    private func addProvider() {
        let pi: String?
        if manualKind == .piKnown {
            pi = ProviderPreset.builtins.first(where: { $0.id == selectedPresetId })?.piProvider
                ?? selectedPresetId
        } else {
            pi = nil
        }
        appStore.addProvider(
            name: manualName,
            kind: manualKind,
            piProvider: pi,
            baseUrl: manualKind == .piKnown ? nil : manualBaseUrl,
            defaultModelId: nil,
            apiKey: apiKey.isEmpty ? nil : apiKey
        )
        manualName = ""; manualBaseUrl = ""; apiKey = ""; selectedPresetId = ""
    }
}
