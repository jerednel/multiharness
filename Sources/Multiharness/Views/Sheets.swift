import SwiftUI
import MultiharnessCore
import MultiharnessClient
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct NewProjectSheet: View {
    @Bindable var appStore: AppStore
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var repoURL: URL?
    @State private var baseBranch: String = "main"
    @State private var error: String?
    @State private var creatingEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New project").font(.title2).bold()

            GroupBox("Add existing repository") {
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
            }

            GroupBox("Create empty project") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Creates a folder and initialises a git repo inside:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(appStore.projectsRoot)
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack {
                        Spacer()
                        Button("Create empty") {
                            creatingEmpty = true
                            createEmpty()
                            creatingEmpty = false
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creatingEmpty)
                    }
                }
            }

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add existing") { commit() }
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

    private func createEmpty() {
        do {
            try appStore.createEmptyProject(
                name: name.trimmingCharacters(in: .whitespaces),
                defaultBaseBranch: baseBranch
            )
            isPresented = false
        } catch {
            self.error = String(describing: error)
        }
    }
}

struct NewWorkspaceSheet: View {
    @Bindable var appStore: AppStore
    @Bindable var workspaceStore: WorkspaceStore
    let branchListService: BranchListService
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var baseBranch: String = ""
    @State private var providerId: UUID?
    @State private var modelId: String = ""
    @State private var buildMode: BuildMode = .primary
    @State private var makeProjectDefault: Bool = false
    @State private var error: String?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New workspace").font(.title2).bold()
            if let proj = appStore.selectedProject {
                Form {
                    LabeledContent("Project") { Text(proj.name) }
                    TextField("Workspace name", text: $name)
                    LabeledContent("Base branch") {
                        BranchPicker(
                            selection: $baseBranch,
                            initialDefault: proj.defaultBaseBranch
                        ) { refresh in
                            try await branchListService.list(
                                projectId: proj.id,
                                repoPath: proj.repoPath,
                                refresh: refresh
                            )
                        }
                    }
                    Picker("Provider", selection: $providerId) {
                        ForEach(appStore.providers) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    Picker("Build target", selection: $buildMode) {
                        ForEach(BuildMode.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle(
                        "Make default for this project",
                        isOn: $makeProjectDefault
                    )
                    .disabled(buildMode == effectiveProjectDefault(proj))
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
        .padding(24).frame(width: 600, height: 680)
        .onAppear {
            if providerId == nil { providerId = appStore.providers.first?.id }
            if let proj = appStore.selectedProject {
                buildMode = effectiveProjectDefault(proj)
            }
        }
        .onChange(of: buildMode) { _, newValue in
            if let proj = appStore.selectedProject,
               newValue == effectiveProjectDefault(proj) {
                makeProjectDefault = false
            }
        }
    }

    private func effectiveProjectDefault(_ proj: Project) -> BuildMode {
        proj.defaultBuildMode ?? .primary
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
            if makeProjectDefault {
                try appStore.setProjectDefaultBuildMode(projectId: proj.id, mode: buildMode)
            }
            let storedMode: BuildMode? =
                buildMode == effectiveProjectDefault(proj) ? nil : buildMode
            let userName = NSUserName()
            _ = try workspaceStore.create(
                project: proj,
                name: name,
                baseBranch: baseBranch.isEmpty ? proj.defaultBaseBranch : baseBranch,
                provider: provider,
                modelId: modelId,
                gitUserName: userName,
                buildMode: storedMode
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
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
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
                .buttonStyle(.multiharnessIcon)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .hoverableRow()
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
                .transition(.disclosureContent)
            }
        }
        .background(.background)
        .onAppear { draftModelId = provider.defaultModelId ?? "" }
    }
}

struct SettingsSheet: View {
    let env: AppEnvironment
    @Bindable var appStore: AppStore
    @Binding var isPresented: Bool
    @State private var tab: SettingsTab = .providers
    @Namespace private var tabBarNamespace

    enum SettingsTab: Hashable { case providers, remote, permissions, sidebar, defaults }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                tabButton("Providers", .providers)
                tabButton("Remote access", .remote)
                tabButton("Permissions", .permissions)
                tabButton("Sidebar", .sidebar)
                tabButton("Defaults", .defaults)
                Spacer()
            }
            Divider()
            Group {
                switch tab {
                case .providers:
                    ProvidersTab(appStore: appStore)
                case .remote:
                    RemoteAccessTab(env: env)
                case .permissions:
                    PermissionsTab(env: env, appStore: appStore)
                case .sidebar:
                    SidebarTab(appStore: appStore)
                case .defaults:
                    DefaultsTab(appStore: appStore)
                }
            }
            .id(tab)
            .transition(.tabSwap)
            Spacer()
            HStack {
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 640, height: 640)
    }

    @ViewBuilder
    private func tabButton(_ label: String, _ value: SettingsTab) -> some View {
        Button {
            withAnimation(Motion.standard) { tab = value }
        } label: {
            Text(label).font(.body)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background {
                    if tab == value {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.18))
                            .matchedGeometryEffect(id: "tab-pill", in: tabBarNamespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.multiharness)
    }
}

private struct ProvidersTab: View {
    @Bindable var appStore: AppStore
    @State private var selectedPresetId: String = ""
    @State private var manualName: String = ""
    @State private var manualBaseUrl: String = ""
    @State private var manualKind: ProviderKind = .openaiCompatible
    @State private var apiKey: String = ""
    @State private var expandedProviderId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Providers").font(.title3).bold()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        Task { await appStore.signInWithAnthropic() }
                    } label: {
                        HStack(spacing: 6) {
                            if appStore.anthropicLoginInProgress {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(appStore.providers.contains(where: { $0.kind == .anthropicOauth })
                                 ? "Re-authenticate Claude"
                                 : "Sign in with Claude")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(appStore.anthropicLoginInProgress)
                    if let err = appStore.anthropicLoginError {
                        Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else if appStore.providers.contains(where: { $0.kind == .anthropicOauth }) {
                        Text("Signed in").font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button {
                        Task { await appStore.signInWithChatGPT() }
                    } label: {
                        HStack(spacing: 6) {
                            if appStore.openaiLoginInProgress {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "bubble.left.and.bubble.right")
                            }
                            Text(appStore.providers.contains(where: { $0.kind == .openaiCodexOauth })
                                 ? "Re-authenticate ChatGPT"
                                 : "Sign in with ChatGPT")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(appStore.openaiLoginInProgress)
                    if let err = appStore.openaiLoginError {
                        Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else if appStore.providers.contains(where: { $0.kind == .openaiCodexOauth }) {
                        Text("Signed in").font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button {
                        Task { await appStore.signInWithAnthropicConsole() }
                    } label: {
                        HStack(spacing: 6) {
                            if appStore.anthropicConsoleLoginInProgress {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "creditcard")
                            }
                            Text(hasConsoleProvider(appStore)
                                 ? "Re-authenticate Claude Console"
                                 : "Sign in with Claude (API Usage Billing)")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(appStore.anthropicConsoleLoginInProgress)
                    if let err = appStore.anthropicConsoleLoginError {
                        Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else if hasConsoleProvider(appStore) {
                        Text("Signed in").font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                }
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(appStore.providers) { p in
                        ProviderRow(
                            appStore: appStore,
                            provider: p,
                            isExpanded: expandedProviderId == p.id,
                            onToggle: {
                                withAnimation(Motion.disclosure) {
                                    expandedProviderId = (expandedProviderId == p.id) ? nil : p.id
                                }
                            }
                        )
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 280)
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
            HStack {
                Spacer()
                Button("Add") { addProvider() }
                    .disabled(manualName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func hasConsoleProvider(_ store: AppStore) -> Bool {
        store.providers.contains { p in
            p.kind == .piKnown
            && p.piProvider == "anthropic"
            && p.name == AppStore.anthropicConsoleProviderName
        }
    }

    private func applyPreset(_ id: String) {
        guard let preset = ProviderPreset.builtins.first(where: { $0.id == id }) else { return }
        manualName = preset.displayName
        manualKind = preset.kind
        manualBaseUrl = preset.baseUrl ?? ""
    }

    private func addProvider() {
        if manualName == AppStore.anthropicConsoleProviderName {
            appStore.lastError =
                "Provider name \"\(AppStore.anthropicConsoleProviderName)\" is reserved — use the Sign in button instead."
            return
        }
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

private struct SidebarTab: View {
    @Bindable var appStore: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sidebar").font(.title3).bold()
            Text("Choose how the sidebar lists your projects and workspaces.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Layout", selection: $appStore.sidebarMode) {
                ForEach(SidebarMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }
}

private struct DefaultsTab: View {
    @Bindable var appStore: AppStore

    @State private var draftProviderId: UUID? = nil
    @State private var draftModelId: String = ""
    @State private var saveError: String?
    @State private var projectsRootDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Defaults").font(.title3).bold()
            Text("Used when creating a workspace if the project has no default and there's no prior workspace to inherit from. iPhone quick-create uses this too.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Default provider", selection: $draftProviderId) {
                Text("None").tag(UUID?.none)
                ForEach(appStore.providers, id: \.id) { p in
                    Text(p.name).tag(UUID?.some(p.id))
                }
            }

            if let pid = draftProviderId,
               let provider = appStore.providers.first(where: { $0.id == pid }) {
                ModelPicker(
                    appStore: appStore,
                    provider: provider,
                    modelId: $draftModelId
                )
            } else {
                Text("Pick a provider to choose a default model.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Text("Projects root").font(.title3).bold()
            Text("New empty projects are created inside this folder.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Path", text: $projectsRootDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.prompt = "Select projects root"
                    if panel.runModal() == .OK, let url = panel.url {
                        projectsRootDraft = url.path
                    }
                }
            }
            HStack {
                Button("Save root") {
                    do {
                        try appStore.setProjectsRoot(projectsRootDraft)
                    } catch {
                        saveError = String(describing: error)
                    }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }

            HStack {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftProviderId == nil || draftModelId.isEmpty)
                Button("Clear", role: .destructive) { clear() }
                    .disabled(draftProviderId == nil && draftModelId.isEmpty)
                Spacer()
            }
            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .onAppear {
            projectsRootDraft = appStore.projectsRoot
            // Switching tabs destroys+recreates the inactive branch, so
            // .onAppear refires every visit. Only seed when the user hasn't
            // already touched the drafts — otherwise we'd silently clobber
            // unsaved selections on a tab round-trip.
            guard draftProviderId == nil && draftModelId.isEmpty else { return }
            if let cur = appStore.getGlobalDefault() {
                draftProviderId = cur.providerId
                draftModelId = cur.modelId
            }
        }
    }

    private func save() {
        do {
            try appStore.setGlobalDefault(providerId: draftProviderId, modelId: draftModelId)
            saveError = nil
        } catch {
            saveError = String(describing: error)
        }
    }

    private func clear() {
        do {
            try appStore.setGlobalDefault(providerId: nil, modelId: nil)
            draftProviderId = nil
            draftModelId = ""
            saveError = nil
        } catch {
            saveError = String(describing: error)
        }
    }
}

private struct RemoteAccessTab: View {
    let env: AppEnvironment
    @State private var working = false
    @State private var localToggle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remote access").font(.title3).bold()
            Text("Allow an iOS companion app on your local network to control this Multiharness instance. Authentication is via a generated bearer token. There is no TLS — use only on trusted networks.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $localToggle) {
                Text(env.remoteAccess.enabled ? "Enabled" : "Disabled")
            }
            .toggleStyle(.switch)
            .disabled(working)
            .onChange(of: localToggle) { _, on in
                guard on != env.remoteAccess.enabled else { return }
                Task {
                    working = true
                    await env.setRemoteAccessEnabled(on)
                    working = false
                }
            }
            .onAppear { localToggle = env.remoteAccess.enabled }

            if env.remoteAccess.enabled {
                Divider()
                if env.remoteAccess.publicPort != nil {
                    PairingPanel(remoteAccess: env.remoteAccess)
                } else {
                    Text("Waiting for sidecar to bind…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PermissionsTab: View {
    let env: AppEnvironment
    @Bindable var appStore: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions").font(.title3).bold()
            Text("When the iPhone asks the Mac to do something (open a workspace, create one, run tools), the Mac may need permission to access folders under Documents, Desktop, etc. Without an active person at the Mac to click \"Allow,\" the request hangs.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Projects").font(.headline)
            if appStore.projects.isEmpty {
                Text("No projects yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(appStore.projects) { p in
                            ProjectAccessRow(env: env, appStore: appStore, project: p)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 280)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Power-user shortcut").font(.headline)
                Text("Grant Multiharness Full Disk Access and you'll never see TCC prompts again — appropriate if you want the iPhone to drive your Mac unattended.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("macOS doesn't pre-list apps; you have to add Multiharness manually:")
                    .font(.callout)
                Text("1. Click \"Reveal Multiharness.app\" below — Finder opens with the bundle selected.\n2. Click \"Open Full Disk Access settings.\"\n3. Click the \"+\" button in the FDA list, drag Multiharness.app from the Finder window into the list (or use the file picker).\n4. Quit and relaunch Multiharness.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        let appURL = Bundle.main.bundleURL
                        NSWorkspace.shared.activateFileViewerSelecting([appURL])
                    } label: {
                        Label("Reveal Multiharness.app", systemImage: "magnifyingglass")
                    }
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Open Full Disk Access settings", systemImage: "lock.open")
                    }
                }
            }
        }
    }
}

private struct ProjectAccessRow: View {
    let env: AppEnvironment
    @Bindable var appStore: AppStore
    let project: Project
    @State private var status: AccessStatus = .checking

    enum AccessStatus { case checking, granted, missing, stale }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.body)
                Text(project.repoPath).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Button {
                regrant()
            } label: {
                Text(status == .granted ? "Re-grant" : "Grant access")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.background)
        .onAppear { status = check() }
    }

    private var icon: String {
        switch status {
        case .checking: return "circle"
        case .granted: return "checkmark.circle.fill"
        case .missing: return "exclamationmark.triangle.fill"
        case .stale: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch status {
        case .checking: return .secondary
        case .granted: return .green
        case .missing: return .red
        case .stale: return .orange
        }
    }

    private func check() -> AccessStatus {
        guard let bm = project.repoBookmark else { return .missing }
        if BookmarkScope.isStale(bm) { return .stale }
        return .granted
    }

    private func regrant() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: project.repoPath)
        panel.prompt = "Grant access"
        panel.message = "Pick the project's folder again to grant Multiharness ongoing access. The folder must match \(project.repoPath)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Update the project's bookmark by re-adding (which captures a new
        // bookmark while the implicit grant is fresh).
        if let bm = try? BookmarkScope.makeBookmark(for: url) {
            var updated = project
            updated.repoBookmark = bm
            try? env.persistence.upsertProject(updated)
            if let idx = appStore.projects.firstIndex(where: { $0.id == project.id }) {
                appStore.projects[idx] = updated
            }
            _ = BookmarkScope.shared.resolve(id: project.id, bookmark: bm)
            status = .granted
        }
    }
}

private struct PairingPanel: View {
    @Bindable var remoteAccess: RemoteAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair an iOS device").font(.headline)
            interfacePicker
            HStack(alignment: .top, spacing: 16) {
                if let pairing = remoteAccess.pairingString(),
                   let qr = makeQR(pairing) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan in Multiharness for iOS, or paste this string into the manual pairing field.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let pairing = remoteAccess.pairingString() {
                        Text(pairing)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            .textSelection(.enabled)
                        Button("Copy") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(pairing, forType: .string)
                        }
                    }
                }
            }
        }
        .onAppear { remoteAccess.refreshInterfaces() }
    }

    @ViewBuilder
    private var interfacePicker: some View {
        if remoteAccess.interfaces.isEmpty {
            Text("No routable interfaces found.").font(.caption).foregroundStyle(.red)
        } else {
            HStack(spacing: 8) {
                Text("Network").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { remoteAccess.selectedHost ?? remoteAccess.interfaces.first?.ipv4 ?? "" },
                    set: { remoteAccess.selectedHost = $0 }
                )) {
                    ForEach(remoteAccess.interfaces) { iface in
                        HStack {
                            Image(systemName: iface.kind == .tailscale ? "network.badge.shield.half.filled" : "network")
                                .foregroundStyle(iface.kind == .tailscale ? .green : .blue)
                            Text(iface.displayLabel)
                        }
                        .tag(iface.ipv4)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                if let host = remoteAccess.selectedHost,
                   let kind = remoteAccess.interfaces.first(where: { $0.ipv4 == host })?.kind,
                   kind == .tailscale {
                    Text("Reachable from anywhere on your tailnet")
                        .font(.caption2).foregroundStyle(.green)
                } else {
                    Text("LAN-only — phone must be on the same Wi-Fi")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func makeQR(_ s: String) -> NSImage? {
        guard let data = s.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scale: CGFloat = 12
        let scaled = ci.transformed(by: .init(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
