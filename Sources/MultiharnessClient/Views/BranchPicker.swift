import SwiftUI

/// SwiftUI picker for selecting a base branch ref. Caller provides:
///  - `fetcher` — async closure returning the current `BranchListing`. The
///    `refresh` flag lets the picker request a fresh listing when the user
///    taps the refresh button.
///  - `selection` — binding to the chosen ref string (e.g. "origin/main"
///    or "main"). The picker writes the fully-qualified ref including
///    the "origin/" prefix on the Origin side.
public struct BranchPicker: View {
    public typealias Fetcher = @Sendable (_ refresh: Bool) async throws -> BranchListing

    @Binding var selection: String
    let initialDefault: String?
    let fetcher: Fetcher

    @State private var listing: BranchListing?
    @State private var loading = false
    @State private var loadError: String?
    @State private var side: BranchSide = .local
    @State private var query: String = ""

    public init(
        selection: Binding<String>,
        initialDefault: String?,
        fetcher: @escaping Fetcher
    ) {
        self._selection = selection
        self.initialDefault = initialDefault
        self.fetcher = fetcher
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Source", selection: $side) {
                    Text("Origin").tag(BranchSide.origin)
                        .disabled(!originUsable)
                    Text("Local").tag(BranchSide.local)
                }
                .pickerStyle(.segmented)
                Button {
                    Task { await load(refresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
#if os(macOS)
                .help("Re-fetch branches from origin")
#endif
            }

            if let caption = originDisabledCaption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }

            TextField("Filter branches…", text: $query)
                .textFieldStyle(.roundedBorder)

            Group {
                if loading && listing == nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading branches…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let err = loadError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(err).font(.caption).foregroundStyle(.red)
                        Button("Retry") { Task { await load(refresh: false) } }
                    }
                } else if filteredBranches.isEmpty {
                    Text(emptyStateText).font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredBranches, id: \.self) { branch in
                                Text(branch)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(selection == branch ? Color.accentColor.opacity(0.2) : Color.clear)
                                    .cornerRadius(4)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selection = branch }
                            }
                        }
                        .padding(4)
                    }
                    .frame(minHeight: 140, maxHeight: 220)
                    .background(branchListBackground)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }
            }
        }
        .task { await load(refresh: false) }
        .onChange(of: side) { _, _ in
            // Don't drop the user's existing selection if it's still valid
            // on the new side; otherwise pick the first match.
            if !filteredBranches.contains(selection),
               let first = filteredBranches.first {
                selection = first
            }
        }
    }

    private var originUsable: Bool {
        listing?.originAvailable == true && (listing?.origin?.isEmpty == false)
    }

    private var originDisabledCaption: String? {
        guard !originUsable else { return nil }
        guard let listing else { return nil }
        if !listing.originAvailable {
            switch listing.originUnavailableReason {
            case .noRemote: return "No `origin` remote configured"
            case .fetchFailed: return "Failed to reach `origin`"
            case .none: return nil
            }
        }
        if listing.origin?.isEmpty == true { return "No remote branches" }
        return nil
    }

    private var filteredBranches: [String] {
        let pool: [String]
        switch side {
        case .origin: pool = listing?.origin ?? []
        case .local:  pool = listing?.local ?? []
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return pool }
        return pool.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private var emptyStateText: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            switch side {
            case .origin: return "No remote branches"
            case .local:  return "No local branches"
            }
        }
        return "No branches match \"\(q)\""
    }

    private var branchListBackground: Color {
#if os(macOS)
        Color(NSColor.controlBackgroundColor)
#else
        Color(UIColor.secondarySystemGroupedBackground)
#endif
    }

    @MainActor
    private func load(refresh: Bool) async {
        let isFirstLoad = (listing == nil)
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let result = try await fetcher(refresh)
            listing = result
            if isFirstLoad {
                applyInitialSelection()
            } else {
                // Don't clobber the user's manual selection on refresh.
                // Only fall back to the first available if their pick is
                // gone (e.g. branch was deleted upstream).
                let pool = side == .origin ? (result.origin ?? []) : result.local
                if !pool.contains(selection), let first = pool.first {
                    selection = first
                }
            }
        } catch {
            loadError = "Couldn't list branches: \(error)"
        }
    }

    private func applyInitialSelection() {
        guard let listing else { return }
        let preferred = (initialDefault?.isEmpty == false) ? initialDefault! : ""
        let preferOrigin = preferred.hasPrefix("origin/")

        // Choose initial side. If preferred is an origin ref but origin
        // isn't usable, fall back to local.
        if preferOrigin && originUsable {
            side = .origin
        } else {
            side = .local
        }

        // Apply selection. Prefer the saved default if present in the
        // selected side's list; otherwise first available.
        let pool: [String] = side == .origin ? (listing.origin ?? []) : listing.local
        if !preferred.isEmpty, pool.contains(preferred) {
            selection = preferred
        } else if let first = pool.first {
            selection = first
        }
    }
}
