import SwiftUI
import MultiharnessCore
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
    let env: AppEnvironment
    @Bindable var appStore: AppStore
    @Binding var isPresented: Bool
    @State private var tab: SettingsTab = .providers

    enum SettingsTab: Hashable { case providers, remote, permissions }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                tabButton("Providers", .providers)
                tabButton("Remote access", .remote)
                tabButton("Permissions", .permissions)
                Spacer()
            }
            Divider()
            switch tab {
            case .providers:
                ProvidersTab(appStore: appStore)
            case .remote:
                RemoteAccessTab(env: env)
            case .permissions:
                PermissionsTab(env: env, appStore: appStore)
            }
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
        Button { tab = value } label: {
            Text(label).font(.body)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(tab == value ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
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
                .disabled(appStore.anthropicLoginInProgress)
                if let err = appStore.anthropicLoginError {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if appStore.providers.contains(where: { $0.kind == .anthropicOauth }) {
                    Text("Signed in").font(.caption).foregroundStyle(.green)
                }
                Spacer()
            }
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
