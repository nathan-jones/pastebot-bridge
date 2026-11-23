import SwiftUI

struct ClipListView: View {
    @Environment(\.scenePhase) private var scenePhase
    /// Read outside the split view, so it reflects the whole window (Duo inner screen = regular).
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model = ClipsModel.shared
    @State private var showSettings = false
    @State private var showSyncStatus = false
    @State private var selection: Clip.ID?
    /// Keeps the detail pane showing a clip even if a sync or search drops it from the list.
    @State private var selectedClip: Clip?

    var body: some View {
        // Side-by-side on wide screens (iPhone Duo inner display, iPad, landscape Max);
        // collapses to a push-navigation stack on narrow ones.
        NavigationSplitView {
            content
                .themedBackground(sidebar: isWide)
                .safeAreaInset(edge: .bottom) { if isWide { sidebarSearchBar } }
                // Inner screen: a fixed large title in the top bar beside the sidebar toggle (`header`);
                // the system bar title stays empty (it still names the back button).
                // Outer screen: normal large title.
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(isWide ? .inline : .large)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 480)
                .modifier(ClipSearch(text: $model.search, wide: isWide))
                .toolbar {
                    if isWide {
                        ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                        ToolbarItem(placement: .topBarLeading) { header }
                            .sharedBackgroundVisibility(.hidden)
                        // Inner screen: search and Filter sit at the bottom of the list (`sidebarSearchBar`);
                        // Settings and iCloud live at the top right of the detail side.
                    } else {
                        // Outer screen: Settings and iCloud at the top of the side bar...
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            settingsButton
                            syncButton
                        }
                        // ...Filter and Search at the bottom.
                        ToolbarSpacer(.flexible, placement: .bottomBar)
                        ToolbarItem(placement: .bottomBar) { filterMenu }
                        DefaultToolbarItem(kind: .search, placement: .bottomBar)
                    }
                }
        } detail: {
            NavigationStack {
                Group {
                    if let clip = selectedClip {
                        ClipDetailView(clip: clip, onDelete: { delete(clip) }).id(clip.id)
                    } else {
                        ContentUnavailableView("No Clip Selected", systemImage: "doc.on.clipboard",
                                               description: Text("Choose a clip from the list."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .themedBackground()
                    }
                }
                .toolbar {
                    if isWide {
                        // Spacers on both sides so this never merges with the clip's Share/Copy/Delete.
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            settingsButton
                            syncButton
                        }
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selection) { _, id in
            selectedClip = id.flatMap(model.clip(id:))
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showSyncStatus) { SyncStatusView() }
        .task {
            await CloudSync.shared.start()
            await CloudSync.shared.fetchNow()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await CloudSync.shared.fetchNow() } }
        }
    }

    /// Removes the clip from iCloud and all devices; it stays in the clipboard history on the Mac.
    private func delete(_ clip: Clip) {
        if selection == clip.id || selectedClip?.id == clip.id {
            selection = nil
            selectedClip = nil
        }
        Task { await CloudSync.shared.delete([clip.id]) }
    }

    private var isWide: Bool { sizeClass == .regular }

    /// Large title drawn in the list on the inner screen, so it scrolls away instead of collapsing.
    @Environment(\.colorScheme) private var scheme

    private var hidesSeparators: Bool {
        ThemeSettings.shared.palette(for: scheme)?.showsSeparators == false
    }

    private var header: some View {
        Text(title)
            .font(.largeTitle.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .fixedSize(horizontal: true, vertical: false)
            .themedText()
            .accessibilityAddTraits(.isHeader)
    }

    private var settingsButton: some View {
        Button { showSettings = true } label: { Image(systemName: "gearshape") }
            .accessibilityLabel("Settings")
    }

    private var syncButton: some View {
        Button { showSyncStatus = true } label: { Image(systemName: syncSymbol) }
            .accessibilityLabel("iCloud sync status")
    }

    private var syncSymbol: String {
        if model.accountProblem != nil || model.errorMessage != nil { return "exclamationmark.icloud" }
        return model.isSyncing ? "arrow.triangle.2.circlepath.icloud" : "icloud"
    }

    private var title: String { filterSummary.isEmpty ? "Pastebot" : filterSummary }


    @ViewBuilder
    private var content: some View {
        let items = model.items
        if items.isEmpty {
            emptyState
        } else {
            list(items)
        }
    }

    // ContentUnavailableView styles its own text, so these don't get `themedText()`.
    @ViewBuilder
    private var emptyState: some View {
        if !model.allClips.isEmpty && !model.search.isEmpty {
            ContentUnavailableView.search(text: model.search)
        } else if !model.allClips.isEmpty && model.isFiltered {
            ContentUnavailableView {
                Label("No Matching Clips", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No clips match \(filterSummary).")
            } actions: {
                Button("Clear Filters") { model.clearFilters() }
            }
        } else if let problem = model.accountProblem {
            ContentUnavailableView("iCloud Unavailable", systemImage: "exclamationmark.icloud",
                                   description: Text(problem))
        } else if !model.hasLoadedCache || model.isSyncing {
            VStack(spacing: 12) {
                ProgressView()
                Text("Downloading clips from iCloud…").font(.footnote).foregroundStyle(.secondary)
            }
        } else if let error = model.errorMessage {
            ContentUnavailableView {
                Label("Couldn't Sync", systemImage: "exclamationmark.icloud")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await CloudSync.shared.fetchNow() } }
            }
        } else {
            ContentUnavailableView("No Clips", systemImage: "doc.on.clipboard",
                                   description: Text("Clips appear here once Pastebot Bridge on your Mac uploads them to iCloud."))
        }
    }

    /// Shown above the list when the last sync failed (e.g. offline).
    @ViewBuilder
    private var syncStatus: some View {
        if let problem = model.accountProblem ?? model.errorMessage {
            VStack(alignment: .leading, spacing: 2) {
                Label(problem, systemImage: "icloud.slash").font(.footnote.weight(.semibold))
                if let lastSynced = model.lastSynced {
                    Text("Showing clips synced \(lastSynced, format: .relative(presentation: .named)).")
                        .font(.footnote)
                }
            }
            .foregroundStyle(.orange)
        }
    }

    @FocusState private var searchFocused: Bool

    /// The inner screen's search field. Drawn by hand rather than with `.searchable`: in a split view
    /// the system moves its search button between columns (it would jump to the detail toolbar and
    /// balloon across the screen when tapped).
    private var sidebarSearchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clips", text: $model.search)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(.capsule)
            .onTapGesture { searchFocused = true }
            .glassEffect(.regular.interactive(), in: .capsule)

            filterMenu
                .font(.title3)
                .frame(width: 48, height: 48)
                .contentShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Type", selection: $model.kindFilter) {
                Label("All Types", systemImage: "square.stack").tag(ClipKind?.none)
                ForEach(ClipKind.filterable, id: \.self) { kind in
                    Label(kind.pluralTitle, systemImage: kind.symbol).tag(Optional(kind))
                }
            }
            .pickerStyle(.inline)

            Picker(selection: $model.sourceFilter) {
                Text("All Apps").tag(String?.none)
                ForEach(model.sources) { source in
                    Text("\(source.name) (\(source.count))").tag(Optional(source.bundleID))
                }
                // Keep a remembered selection visible even if no clips from that app remain.
                if let selected = model.sourceFilter, !model.sources.contains(where: { $0.bundleID == selected }) {
                    Text(selected).tag(Optional(selected))
                }
            } label: {
                Label("App", systemImage: "app.badge")
                Text(model.sourceFilterName ?? "All Apps")
            }
            .pickerStyle(.menu)

            if model.isFiltered {
                Divider()
                Button("Clear Filters", systemImage: "xmark.circle", role: .destructive) { model.clearFilters() }
            }
        } label: {
            Image(systemName: model.isFiltered
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter")
    }

    /// e.g. "Links from Safari"; empty when unfiltered.
    private var filterSummary: String {
        let kind = model.kindFilter?.pluralTitle ?? (model.sourceFilter != nil ? "Clips" : nil)
        return [kind, model.sourceFilterName.map { "from \($0)" }].compactMap { $0 }.joined(separator: " ")
    }

    private func list(_ items: [Clip]) -> some View {
        // Wide: rows are buttons drawing their own rounded selection, since List's built-in highlight
        // can't take theme colors. Narrow: List selection pushes the clip like a normal iPhone list.
        List(selection: isWide ? .constant(nil) : $selection) {
            syncStatus.themedRow()
            ForEach(items) { clip in
                clipRow(clip)
                .contextMenu {
                    CopyButton(clip: clip)
                    if let url = clip.webURL {
                        Link(destination: url) { Label("Open in Safari", systemImage: "safari") }
                    }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(clip) }
                }
                .swipeActions(edge: .leading) { CopyButton(clip: clip).tint(.blue) }
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(clip) }
                }
                // Applied last so it covers the whole row (Iris and Grove hide separators).
                .listRowSeparator(hidesSeparators ? .hidden : .automatic, edges: .all)
            }
        }
        .listStyle(.plain)
        .refreshable { await CloudSync.shared.fetchNow() }
    }

    @ViewBuilder
    private func clipRow(_ clip: Clip) -> some View {
        if isWide {
            Button { selection = clip.id } label: {
                ClipRow(clip: clip).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == clip.id ? .isSelected : [])
            .themedSidebarRow(selected: selection == clip.id)
        } else {
            NavigationLink(value: clip.id) { ClipRow(clip: clip) }
                .themedRow()
        }
    }
}

struct ClipRow: View {
    let clip: Clip

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: clip.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.previewTitle)
                    .font(clip.kind == .link || clip.kind == .file ? .body.monospaced() : .body)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if let source = clip.sourceName { Text(source) }
                    Text("·")
                    Text(clip.createdAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if clip.hasImage {
                ClipImage(id: clip.id, maxPixel: 180)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
        .themedText()
    }
}

extension Clip {
    /// The http(s) URL for link clips, for opening in the browser.
    var webURL: URL? {
        guard kind == .link, let text,
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    var previewTitle: String {
        if let text, !text.isEmpty {
            // Rows show 3 lines; don't lay out megabytes of synced text.
            return String(text.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return switch kind {
        case .image: "Image"
        default: types.first ?? "Empty clip"
        }
    }
}

extension ClipKind {
    static let filterable: [ClipKind] = [.text, .link, .image, .file]

    var pluralTitle: String {
        switch self {
        case .text: "Text"
        case .link: "Links"
        case .file: "Files"
        case .image: "Images"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .file: "doc"
        case .image: "photo"
        case .other: "questionmark.square.dashed"
        }
    }
}

/// A toolbar search button on narrow screens. Wide screens use `sidebarSearchBar` instead.
private struct ClipSearch: ViewModifier {
    @Binding var text: String
    let wide: Bool

    func body(content: Content) -> some View {
        if wide {
            content
        } else {
            content
                .searchable(text: $text, prompt: "Search clips")
                .searchToolbarBehavior(.minimize)
        }
    }
}
