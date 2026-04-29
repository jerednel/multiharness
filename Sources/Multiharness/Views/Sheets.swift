import SwiftUI
import MultiharnessCore
import AppKit

struct NewProjectSheet: View {
    @Bindable var appStore: AppStore
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var repoURL: URL?
    @State private var baseBranch: String = "main"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New project").font(.title2).bold()
            Form {
                TextField("Name", text: $name)
                HStack {
                    Text(repoURL?.path ?? "(none)")
                        .truncationMode(.head)
                        .lineLimit(1)
                        .foregroundStyle(repoURL == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Select repo"
                        if panel.runModal() == .OK, let url = panel.url {
                            repoURL = url
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || repoURL == nil)
            }
        }
        .padding(24).frame(width: 520)
    }

    private func commit() {
        guard let url = repoURL else {
            error = "Pick a repo directory."
            return
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists, isDir.boolValue else {
            error = "Repo path does not exist or is not a directory."
            return
        }
        let gitDir = url.appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitDir) else {
            error = "Selected directory is not a git repository (no .git found)."
            return
        }
        appStore.addProject(name: name, repoURL: url, defaultBaseBranch: baseBranch)
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
                }
                Divider()
                ModelPicker(
                    appStore: appStore,
                    provider: appStore.providers.first(where: { $0.id == providerId }),
                    modelId: $modelId
                )
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
        .padding(24).frame(width: 600, height: 620)
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

struct ProviderRow: View {
    @Bindable var appStore: AppStore
    let provider: ProviderRecord
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var draftModelId: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name).font(.body)
                    HStack(spacing: 8) {
                        Text(provider.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                        if let pi = provider.piProvider {
                            Text(pi).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let url = provider.baseUrl {
                            Text(url).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let def = provider.defaultModelId {
                            Text("·").foregroundStyle(.secondary).font(.caption2)
                            Text("default: \(def)").font(.caption2).foregroundStyle(.blue)
                        }
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    appStore.removeProvider(provider)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ModelPicker(
                        appStore: appStore,
                        provider: provider,
                        modelId: $draftModelId
                    )
                    HStack {
                        Spacer()
                        Button("Save default") {
                            appStore.setProviderDefaultModel(provider, modelId: draftModelId)
                        }
                        .disabled(draftModelId.isEmpty || draftModelId == provider.defaultModelId)
                    }
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
        .background(.background)
        .onAppear { draftModelId = provider.defaultModelId ?? "" }
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
    @State private var expandedProviderId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Providers").font(.title2).bold()
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(appStore.providers) { p in
                        ProviderRow(
                            appStore: appStore,
                            provider: p,
                            isExpanded: expandedProviderId == p.id,
                            onToggle: {
                                expandedProviderId = (expandedProviderId == p.id) ? nil : p.id
                            }
                        )
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 360)
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
