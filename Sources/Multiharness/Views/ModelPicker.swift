import SwiftUI
import MultiharnessCore

/// Searchable model picker that fetches available models from the sidecar.
///
/// Use cases:
/// - `NewWorkspaceSheet`: pick the model to use for a new workspace
/// - `SettingsSheet`: pick a default model for a provider
///
/// Always allows a manual override (some endpoints serve models that don't
/// appear in `/v1/models`, and pi-ai's registry may lag a brand-new model).
struct ModelPicker: View {
    @Bindable var appStore: AppStore
    let provider: ProviderRecord?
    @Binding var modelId: String

    @State private var models: [AppStore.DiscoveredModel] = []
    @State private var loading: Bool = false
    @State private var error: String?
    @State private var query: String = ""
    @State private var manualMode: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Model").font(.subheadline).bold()
                Spacer()
                if loading { ProgressView().scaleEffect(0.6).frame(width: 14, height: 14) }
                Button {
                    Task { await load() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.multiharnessIcon)
                    .disabled(provider == nil || loading)
                Toggle("Manual", isOn: $manualMode).toggleStyle(.switch).controlSize(.mini)
            }

            if manualMode || provider == nil {
                TextField("Model id (e.g. openrouter/auto, qwen2.5-7b-instruct)", text: $modelId)
                    .textFieldStyle(.roundedBorder)
            } else if let err = error {
                VStack(alignment: .leading, spacing: 4) {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
                    TextField("Or enter model id manually", text: $modelId)
                        .textFieldStyle(.roundedBorder)
                }
            } else if models.isEmpty && !loading {
                TextField("Model id", text: $modelId).textFieldStyle(.roundedBorder)
                Text("No models found yet — click the refresh button or enter a model id.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("Filter…", text: $query, prompt: Text("Filter models"))
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredModels) { m in
                            ModelRow(model: m, selected: m.id == modelId)
                                .onTapGesture { modelId = m.id }
                        }
                    }
                }
                .frame(minHeight: 140, maxHeight: 220)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.tertiary))
                if !modelId.isEmpty {
                    Text("Selected: \(modelId)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: provider?.id) {
            // Reset on provider change.
            models = []
            error = nil
            await load()
        }
    }

    private var filteredModels: [AppStore.DiscoveredModel] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return models }
        return models.filter { m in
            m.id.lowercased().contains(q) || (m.name?.lowercased().contains(q) ?? false)
        }
    }

    @MainActor
    private func load() async {
        guard let provider else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let fetched = try await appStore.listModels(for: provider)
            models = fetched.sorted { ($0.name ?? $0.id).localizedCaseInsensitiveCompare($1.name ?? $1.id) == .orderedAscending }
            // Auto-select default model if nothing chosen yet.
            if modelId.isEmpty, let def = provider.defaultModelId, fetched.contains(where: { $0.id == def }) {
                modelId = def
            } else if modelId.isEmpty, let first = fetched.first {
                // Don't auto-select on a huge list (OpenRouter has thousands)
                if fetched.count <= 50 { modelId = first.id }
            }
        } catch {
            self.error = String(describing: error)
        }
    }
}

private struct ModelRow: View {
    let model: AppStore.DiscoveredModel
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name ?? model.id).font(.callout)
                HStack(spacing: 6) {
                    Text(model.id).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let w = model.contextWindow {
                        Text("·").foregroundStyle(.secondary).font(.caption2)
                        Text("\(w / 1000)k ctx").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
    }
}
