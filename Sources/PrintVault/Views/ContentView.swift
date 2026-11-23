import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

// MARK: - App Command Notifications

extension Notification.Name {
    static let printVaultScanFiles = Notification.Name("PrintVault.ScanFiles")
    static let printVaultImportFiles = Notification.Name("PrintVault.ImportFiles")
    static let printVaultSendSelectedToSlicer = Notification.Name("PrintVault.SendSelectedToSlicer")
    static let printVaultExpandPreview = Notification.Name("PrintVault.ExpandPreview")
}

// MARK: - Sidebar Navigation Selection

enum SidebarFilter: Hashable {
    case all
    case favorites
    case uncategorized
    case recentlySliced
    case format(PrintFileFormat)
    case status(PrintStatus)
    case category(UUID)
    case folder(String)
    case tag(String)
}

enum BrowserSortOrder: String, CaseIterable, Identifiable {
    case dateModified = "Date Modified"
    case name = "Name"
    case fileSize = "File Size"
    case triangles = "Triangle Count"

    var id: String { rawValue }
}

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case grid = "Grid"
    case table = "Table"

    var id: String { rawValue }
}

// MARK: - ContentView

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \PrintFileItem.dateModified, order: .reverse)
    private var allItems: [PrintFileItem]

    @Query(sort: \PrintCategory.sortOrder)
    private var categories: [PrintCategory]

    @Query(sort: \WatchedFolder.displayName)
    private var watchedFolders: [WatchedFolder]

    @State private var scanner = FileScannerService()
    @State private var slicerService = SlicerService.shared
    @State private var vlmService = VLMCategorizerService.shared

    @State private var sidebarFilter: SidebarFilter? = .all
    @State private var selectedItemPaths: Set<String> = []
    @State private var primarySelectedPath: String?
    @State private var searchText: String = ""
    @State private var sortOrder: BrowserSortOrder = .dateModified
    @State private var viewMode: BrowserViewMode = .grid
    @AppStorage("PrintVault.GroupRelatedModels") private var groupRelatedModels: Bool = true
    @State private var openedGroupID: String?
    @State private var expandedTableGroupIDs: Set<String> = []

    @State private var showSlicerSettings: Bool = false
    @State private var showAICategorizeSheet: Bool = false
    @State private var showCategorySheet: Bool = false
    @State private var editingCategory: PrintCategory?
    @State private var categoryNameDraft: String = ""
    @State private var categoryIconDraft: String = "cube.box.fill"
    @State private var categoryColorDraft: Color = .blue
    @State private var expandedPreviewItem: PrintFileItem?
    @State private var highlightedDropCategoryId: UUID?
    @State private var thumbnailGeneration: Int = 0
    @State private var preferEmbedded3MFThumbnails: Bool = ThumbnailService.shared.preferEmbedded3MFThumbnails

    @State private var didPerformInitialBootstrap: Bool = false

    private struct SidebarStats {
        var totalCount = 0
        var favoritesCount = 0
        var uncategorizedCount = 0
        var recentlySlicedCount = 0
        var formatCounts: [PrintFileFormat: Int] = [:]
        var statusCounts: [PrintStatus: Int] = [:]
        var folderCounts: [String: Int] = [:]
        var tagCounts: [String: Int] = [:]
        var sortedTags: [String] = []

        static func build(from items: [PrintFileItem], folders: [WatchedFolder]) -> SidebarStats {
            var stats = SidebarStats()
            stats.totalCount = items.count
            let folderPaths = folders.map(\.path)
            for item in items {
                if item.isFavorite { stats.favoritesCount += 1 }
                if item.category == nil { stats.uncategorizedCount += 1 }
                if item.lastSentToSlicerDate != nil { stats.recentlySlicedCount += 1 }
                stats.formatCounts[item.format, default: 0] += 1
                stats.statusCounts[item.printStatus, default: 0] += 1
                for tag in item.tags {
                    stats.tagCounts[tag, default: 0] += 1
                }
                for folderPath in folderPaths where FileScannerService.matchesFolder(item.filePath, folderPath: folderPath) {
                    stats.folderCounts[folderPath, default: 0] += 1
                }
            }
            stats.sortedTags = stats.tagCounts.keys.sorted()
            return stats
        }
    }

    private func computeFilteredItems() -> [PrintFileItem] {
        let queryLower = searchText.lowercased()
        let base = allItems.filter { item in
            switch sidebarFilter ?? .all {
            case .all:
                break
            case .favorites:
                if !item.isFavorite { return false }
            case .uncategorized:
                if item.category != nil { return false }
            case .recentlySliced:
                if item.lastSentToSlicerDate == nil { return false }
            case .format(let fmt):
                if item.format != fmt { return false }
            case .status(let st):
                if item.printStatus != st { return false }
            case .category(let catID):
                if item.category?.id != catID { return false }
            case .folder(let folderPath):
                if !FileScannerService.matchesFolder(item.filePath, folderPath: folderPath) { return false }
            case .tag(let tag):
                if !item.tags.contains(tag) { return false }
            }

            if !queryLower.isEmpty {
                let matchesName = item.fileName.lowercased().contains(queryLower)
                let matchesCategory = item.category?.name.lowercased().contains(queryLower) ?? false
                let matchesTag = item.tags.contains(where: { $0.lowercased().contains(queryLower) })
                let matchesNotes = item.notes.lowercased().contains(queryLower)
                if !(matchesName || matchesCategory || matchesTag || matchesNotes) {
                    return false
                }
            }

            return true
        }

        // @Query already returns items sorted by dateModified descending — skip re-sorting for the default sort order!
        if sortOrder == .dateModified {
            return base
        }

        return base.sorted { a, b in
            switch sortOrder {
            case .dateModified:
                return a.dateModified > b.dateModified
            case .name:
                return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
            case .fileSize:
                return a.fileSize > b.fileSize
            case .triangles:
                return a.triangleCount > b.triangleCount
            }
        }
    }

    private func resolveSelectedItem(in displayedItems: [PrintFileItem]) -> PrintFileItem? {
        if let primarySelectedPath,
           let item = allItems.first(where: { $0.filePath == primarySelectedPath }) {
            return item
        }
        if let firstPath = selectedItemPaths.first,
           let item = allItems.first(where: { $0.filePath == firstPath }) {
            return item
        }
        return displayedItems.first
    }

    private func resolveSelectedItems(in displayedItems: [PrintFileItem]) -> [PrintFileItem] {
        let matched = displayedItems.filter { selectedItemPaths.contains($0.filePath) }
        if !matched.isEmpty { return matched }
        if let active = resolveSelectedItem(in: displayedItems) { return [active] }
        return []
    }

    var body: some View {
        let displayedItems = computeFilteredItems()
        let stats = SidebarStats.build(from: allItems, folders: watchedFolders)
        let browserEntries: [BrowserEntry] = groupRelatedModels
            ? ModelGroupingService.groupItems(displayedItems, watchedFolderPaths: watchedFolders.map(\.path))
            : displayedItems.map { .single($0) }
        let activeOpenedGroup: ModelGroup? = openedGroupID.flatMap { gid in
            for entry in browserEntries {
                if case .group(let group) = entry, group.id == gid {
                    return group
                }
            }
            return nil
        }
        let activeItem = resolveSelectedItem(in: activeOpenedGroup?.items ?? displayedItems)
        let activeItemGroup: ModelGroup? = activeItem.flatMap { active in
            for entry in browserEntries {
                if case .group(let group) = entry,
                   group.items.contains(where: { $0.filePath == active.filePath }) {
                    return group
                }
            }
            return nil
        }

        NavigationSplitView {
            sidebarView(stats: stats)
                .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 290)
        } detail: {
            HSplitView {
                centerBrowserView(
                    displayedItems: displayedItems,
                    browserEntries: browserEntries,
                    activeOpenedGroup: activeOpenedGroup,
                    stats: stats,
                    activeItem: activeItem
                )
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

                if let activeItem {
                    InspectorPaneView(
                        item: activeItem,
                        categories: categories,
                        slicerService: slicerService,
                        vlmService: vlmService,
                        onOpenSlicerSettings: { showSlicerSettings = true },
                        onOpenAICategorize: { showAICategorizeSheet = true },
                        containingGroup: activeItemGroup,
                        onSelectSiblingPart: { sibling in
                            selectedItemPaths = [sibling.filePath]
                            primarySelectedPath = sibling.filePath
                        },
                        onOpenGroup: activeItemGroup.map { group in
                            {
                                openedGroupID = group.id
                            }
                        }
                    )
                    .frame(minWidth: 320, idealWidth: 355, maxWidth: 420, maxHeight: .infinity)
                } else {
                    emptyInspectorPlaceholder
                        .frame(minWidth: 320, idealWidth: 355, maxWidth: 420, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: sidebarFilter) { _, _ in
            openedGroupID = nil
        }
        .onChange(of: groupRelatedModels) { _, isGrouped in
            if !isGrouped {
                openedGroupID = nil
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search STL, 3MF, tags, categories...")
        .toolbar {
            toolbarContent
        }
        .sheet(isPresented: $showSlicerSettings) {
            SlicerSettingsView(slicerService: slicerService)
        }
        .sheet(isPresented: $showAICategorizeSheet) {
            AICategorizeSheetView(
                vlmService: vlmService,
                allItems: allItems,
                selectedItems: resolveSelectedItems(in: displayedItems),
                categories: categories,
                onRunKeywordFallback: {
                    let count = scanner.autoCategorizeUncategorized(context: modelContext)
                    scanner.statusMessage = "Keyword rules categorized \(count) model(s)."
                    return count
                }
            )
        }
        .sheet(isPresented: $showCategorySheet) {
            categoryEditorSheet
        }
        .sheet(item: $expandedPreviewItem) { item in
            ExpandedPreview3DSheet(item: item, slicerService: slicerService)
        }
        .onReceive(NotificationCenter.default.publisher(for: .printVaultScanFiles)) { _ in
            Task {
                await scanner.performFullScan(context: modelContext, includeSpotlight: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .printVaultImportFiles)) { _ in
            promptImportFilesOrFolders()
        }
        .onReceive(NotificationCenter.default.publisher(for: .printVaultSendSelectedToSlicer)) { _ in
            let items = resolveSelectedItems(in: computeFilteredItems())
            guard !items.isEmpty else { return }
            Task {
                _ = await slicerService.sendToSlicer(items: items)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .printVaultExpandPreview)) { _ in
            if let active = resolveSelectedItem(in: computeFilteredItems()) {
                expandedPreviewItem = active
            }
        }
        .task {
            guard !didPerformInitialBootstrap else { return }
            didPerformInitialBootstrap = true
            await bootstrapInitialDataAndScan()
        }
    }

    // MARK: - Sidebar

    private func sidebarView(stats: SidebarStats) -> some View {
        List(selection: $sidebarFilter) {
            Section("Library") {
                sidebarRow(
                    title: "All 3D Models",
                    icon: "cube.fill",
                    color: .accentColor,
                    count: stats.totalCount,
                    tag: .all
                )
                sidebarRow(
                    title: "Favorites",
                    icon: "heart.fill",
                    color: .red,
                    count: stats.favoritesCount,
                    tag: .favorites
                )
                sidebarRow(
                    title: "Uncategorized",
                    icon: "questionmark.folder.fill",
                    color: .orange,
                    count: stats.uncategorizedCount,
                    tag: .uncategorized
                )
                sidebarRow(
                    title: "Recently Sliced",
                    icon: "paperplane.fill",
                    color: .green,
                    count: stats.recentlySlicedCount,
                    tag: .recentlySliced
                )
            }

            Section {
                ForEach(categories) { category in
                    HStack {
                        Label {
                            Text(category.name)
                        } icon: {
                            Image(systemName: category.iconName)
                                .foregroundStyle(category.color)
                        }
                        Spacer()
                        Text("\(category.items.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                    .background(
                        highlightedDropCategoryId == category.id
                            ? RoundedRectangle(cornerRadius: 6).fill(category.color.opacity(0.22))
                            : nil
                    )
                    .tag(SidebarFilter.category(category.id))
                    .dropDestination(for: String.self) { droppedPayloads, _ in
                        let parsedPaths = droppedPayloads.flatMap {
                            $0.split(separator: "\n").map(String.init)
                        }
                        var targetPaths = Set(parsedPaths)
                        // If dragging an item that's part of a multi-selection, categorize the whole selection
                        if !targetPaths.isDisjoint(with: selectedItemPaths) {
                            targetPaths.formUnion(selectedItemPaths)
                        }
                        var updated = 0
                        for item in allItems where targetPaths.contains(item.filePath) {
                            item.category = category
                            updated += 1
                        }
                        if updated > 0 {
                            try? modelContext.save()
                            scanner.statusMessage = "Moved \(updated) model(s) to \(category.name)."
                        }
                        return updated > 0
                    } isTargeted: { isTargeted in
                        highlightedDropCategoryId = isTargeted ? category.id : nil
                    }
                    .contextMenu {
                        Button {
                            beginEditCategory(category)
                        } label: {
                            Label("Edit Category...", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            modelContext.delete(category)
                            try? modelContext.save()
                        } label: {
                            Label("Delete Category", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Categories")
                    Spacer()
                    Button {
                        beginCreateCategory()
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("New Category")
                }
            }

            Section("3D Formats") {
                ForEach(PrintFileFormat.allCases) { fmt in
                    sidebarRow(
                        title: fmt.displayName,
                        icon: "doc.badge.gearshape.fill",
                        color: fmt.badgeColor,
                        count: stats.formatCounts[fmt, default: 0],
                        tag: .format(fmt)
                    )
                }
            }

            Section("Print Status") {
                ForEach(PrintStatus.allCases) { st in
                    sidebarRow(
                        title: st.label,
                        icon: st.systemImage,
                        color: st.color,
                        count: stats.statusCounts[st, default: 0],
                        tag: .status(st)
                    )
                }
            }

            Section {
                ForEach(watchedFolders) { folder in
                    HStack {
                        Label(folder.displayName, systemImage: "folder.fill.badge.gearshape")
                        Spacer()
                        Text("\(stats.folderCounts[folder.path, default: 0])")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(SidebarFilter.folder(folder.path))
                    .contextMenu {
                        Button("Scan Folder Now") {
                            Task {
                                await scanner.scanWatchedFolders(context: modelContext)
                                await scanner.analyzeUnprocessedMeshes(context: modelContext)
                            }
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.open(folder.url)
                        }
                        Divider()
                        Button(role: .destructive) {
                            modelContext.delete(folder)
                            try? modelContext.save()
                        } label: {
                            Label("Remove Watched Folder", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Watched Folders")
                    Spacer()
                    Button {
                        promptAddWatchedFolder()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .help("Add Watched Folder")
                }
            }

            if !stats.sortedTags.isEmpty {
                Section("Tags") {
                    ForEach(stats.sortedTags, id: \.self) { tag in
                        HStack {
                            Label(tag, systemImage: "tag.fill")
                            Spacer()
                            Text("\(stats.tagCounts[tag, default: 0])")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .tag(SidebarFilter.tag(tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func sidebarRow(
        title: String,
        icon: String,
        color: Color,
        count: Int,
        tag: SidebarFilter
    ) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(color)
            }
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .tag(tag)
    }

    // MARK: - Center Browser View

    private func centerBrowserView(
        displayedItems: [PrintFileItem],
        browserEntries: [BrowserEntry],
        activeOpenedGroup: ModelGroup?,
        stats: SidebarStats,
        activeItem: PrintFileItem?
    ) -> some View {
        let defaultSlicerName = slicerService.defaultProfile.name
        let slicerProfiles = slicerService.profiles
        let groupCount = browserEntries.reduce(0) { count, entry in
            if case .group = entry { return count + 1 }
            return count
        }

        return VStack(spacing: 0) {
            // Sub-header bar
            HStack(spacing: 12) {
                if let opened = activeOpenedGroup {
                    Text("\(opened.items.count) parts in \(opened.title)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if groupRelatedModels && groupCount > 0 {
                    Text("\(browserEntries.count) models (\(displayedItems.count) files)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("\(displayedItems.count) model\(displayedItems.count == 1 ? "" : "s")")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if !allItems.isEmpty {
                    Button {
                        showAICategorizeSheet = true
                    } label: {
                        Label("AI Auto-Categorize", systemImage: "wand.and.stars")
                    }
                    .controlSize(.small)
                    .help("Categorize 3D models visually using a local Vision-Language Model (Ollama, LM Studio, or MLX-VLM)")
                }

                Spacer()

                Toggle(isOn: $groupRelatedModels) {
                    Label("Group", systemImage: "square.stack.3d.up")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(
                    groupRelatedModels
                        ? "Grouping related multi-part models (click for flat list)"
                        : "Showing all files individually (click to group related multi-part models)"
                )

                Picker("Sort", selection: $sortOrder) {
                    ForEach(BrowserSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 155)
                .controlSize(.small)

                Picker("View", selection: $viewMode) {
                    Image(systemName: "square.grid.2x2")
                        .help("Grid View")
                        .tag(BrowserViewMode.grid)
                    Image(systemName: "list.bullet")
                        .help("Table View")
                        .tag(BrowserViewMode.table)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 68)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            // Drilled-in Multi-Part Group Breadcrumb Bar
            if let opened = activeOpenedGroup {
                Divider()
                groupDrillInBar(group: opened, defaultSlicerName: defaultSlicerName)
            }

            // Multi-select Batch Action Bar
            if selectedItemPaths.count > 1 {
                Divider()
                batchActionBar(displayedItems: activeOpenedGroup?.items ?? displayedItems)
            }

            Divider()

            // Main Grid or Table
            if displayedItems.isEmpty {
                emptyBrowserView
            } else if viewMode == .grid {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 205, maximum: 260), spacing: 14)],
                        spacing: 14
                    ) {
                        if let opened = activeOpenedGroup {
                            ForEach(opened.items, id: \.filePath) { item in
                                let isSelected = selectedItemPaths.contains(item.filePath)
                                    || (selectedItemPaths.isEmpty && activeItem?.filePath == item.filePath)
                                ModelGridCardView(
                                    item: item,
                                    isSelected: isSelected,
                                    categories: categories,
                                    defaultSlicerName: defaultSlicerName,
                                    slicerProfiles: slicerProfiles,
                                    thumbnailGeneration: thumbnailGeneration,
                                    onSendToSlicer: { targetItem, profile in
                                        Task {
                                            _ = await slicerService.sendToSlicer(items: [targetItem], using: profile)
                                        }
                                    },
                                    onSelect: { toggleMulti in
                                        handleSelection(for: item, toggleMulti: toggleMulti)
                                    },
                                    onDoubleClick: {
                                        expandedPreviewItem = item
                                    }
                                )
                            }
                        } else {
                            ForEach(browserEntries) { entry in
                                switch entry {
                                case .single(let item):
                                    let isSelected = selectedItemPaths.contains(item.filePath)
                                        || (selectedItemPaths.isEmpty && activeItem?.filePath == item.filePath)
                                    ModelGridCardView(
                                        item: item,
                                        isSelected: isSelected,
                                        categories: categories,
                                        defaultSlicerName: defaultSlicerName,
                                        slicerProfiles: slicerProfiles,
                                        thumbnailGeneration: thumbnailGeneration,
                                        onSendToSlicer: { targetItem, profile in
                                            Task {
                                                _ = await slicerService.sendToSlicer(items: [targetItem], using: profile)
                                            }
                                        },
                                        onSelect: { toggleMulti in
                                            handleSelection(for: item, toggleMulti: toggleMulti)
                                        },
                                        onDoubleClick: {
                                            expandedPreviewItem = item
                                        }
                                    )
                                case .group(let group):
                                    let isSelected = group.items.contains(where: { selectedItemPaths.contains($0.filePath) })
                                        || (selectedItemPaths.isEmpty && group.items.contains(where: { $0.filePath == activeItem?.filePath }))
                                    ModelGroupCardView(
                                        group: group,
                                        isSelected: isSelected,
                                        categories: categories,
                                        defaultSlicerName: defaultSlicerName,
                                        slicerProfiles: slicerProfiles,
                                        thumbnailGeneration: thumbnailGeneration,
                                        onSendAllToSlicer: { itemsToSlice, profile in
                                            Task {
                                                _ = await slicerService.sendToSlicer(items: itemsToSlice, using: profile)
                                            }
                                        },
                                        onSelect: {
                                            selectedItemPaths = [group.primaryItem.filePath]
                                            primarySelectedPath = group.primaryItem.filePath
                                        },
                                        onOpenGroup: {
                                            openedGroupID = group.id
                                            selectedItemPaths = [group.primaryItem.filePath]
                                            primarySelectedPath = group.primaryItem.filePath
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            } else {
                if let opened = activeOpenedGroup {
                    tableBrowserView(displayedItems: opened.items)
                } else if groupRelatedModels && groupCount > 0 {
                    groupedTableBrowserView(browserEntries: browserEntries, activeItem: activeItem)
                } else {
                    tableBrowserView(displayedItems: displayedItems)
                }
            }

            Divider()

            // Isolated Status Footer Bar (status/progress updates won't re-render the 3D model grid)
            StatusFooterBar(scanner: scanner, slicerService: slicerService)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDroppedProviders(providers)
            return true
        }
    }

    private func groupDrillInBar(group: ModelGroup, defaultSlicerName: String) -> some View {
        HStack(spacing: 10) {
            Button {
                openedGroupID = nil
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .controlSize(.small)
            .keyboardShortcut("[", modifiers: .command)
            .help("Return to model library (⌘[)")

            Image(systemName: group.reason == .projectFolder ? "folder.fill" : "square.stack.3d.up.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(group.items.count) parts • \(group.reason.rawValue) • \(group.formattedTotalFileSize)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button("Uncategorized") {
                    for item in group.items { item.category = nil }
                    try? modelContext.save()
                }
                Divider()
                ForEach(categories) { category in
                    Button {
                        for item in group.items { item.category = category }
                        try? modelContext.save()
                    } label: {
                        Label(category.name, systemImage: category.iconName)
                    }
                }
            } label: {
                Label("Categorize All", systemImage: "folder")
            }
            .controlSize(.small)

            Button {
                Task {
                    _ = await slicerService.sendToSlicer(items: group.items)
                }
            } label: {
                Label("Send All \(group.items.count) to \(defaultSlicerName)", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.07))
    }

    private func batchActionBar(displayedItems: [PrintFileItem]) -> some View {
        let batchItems = resolveSelectedItems(in: displayedItems)
        return HStack(spacing: 10) {
            Text("\(batchItems.count) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Button {
                Task {
                    _ = await slicerService.sendToSlicer(items: batchItems)
                }
            } label: {
                Label("Send \(batchItems.count) to \(slicerService.defaultProfile.name)", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Menu {
                Button("Uncategorized") {
                    for item in batchItems { item.category = nil }
                    try? modelContext.save()
                }
                Divider()
                ForEach(categories) { category in
                    Button {
                        for item in batchItems { item.category = category }
                        try? modelContext.save()
                    } label: {
                        Label(category.name, systemImage: category.iconName)
                    }
                }
            } label: {
                Label("Categorize", systemImage: "folder")
            }
            .controlSize(.small)

            Menu {
                ForEach(PrintStatus.allCases) { status in
                    Button {
                        for item in batchItems { item.printStatus = status }
                        try? modelContext.save()
                    } label: {
                        Label(status.label, systemImage: status.systemImage)
                    }
                }
            } label: {
                Label("Status", systemImage: "flag")
            }
            .controlSize(.small)

            Spacer()

            Button("Clear") {
                selectedItemPaths.removeAll()
                primarySelectedPath = nil
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.08))
    }

    private var tableHeaderRow: some View {
        HStack(spacing: 12) {
            Text("Model Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Category")
                .frame(width: 150, alignment: .leading)
            Text("Dimensions (mm)")
                .frame(width: 145, alignment: .leading)
            Text("Triangles")
                .frame(width: 80, alignment: .trailing)
            Text("Size")
                .frame(width: 75, alignment: .trailing)
            Text("Slicer")
                .frame(width: 75, alignment: .center)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func tableItemRow(for item: PrintFileItem) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(item.format.badgeText)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(item.format.badgeColor.opacity(0.85))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                Text(item.displayTitle)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let cat = item.category {
                    Label(cat.name, systemImage: cat.iconName)
                        .font(.caption)
                        .foregroundStyle(cat.color)
                        .lineLimit(1)
                } else {
                    Text("Uncategorized")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, alignment: .leading)

            Text(item.formattedDimensions)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 145, alignment: .leading)

            Text(item.triangleCount > 0 ? item.triangleCount.formatted() : "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Text(item.formattedFileSize)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 75, alignment: .trailing)

            Button {
                Task {
                    _ = await slicerService.sendToSlicer(items: [item])
                }
            } label: {
                Label("Slice", systemImage: "paperplane.fill")
            }
            .controlSize(.small)
            .frame(width: 75, alignment: .center)
        }
        .padding(.vertical, 2)
        .draggable(item.filePath)
        .contextMenu {
            tableRowContextMenu(for: item)
        }
    }

    private func tableBrowserView(displayedItems: [PrintFileItem]) -> some View {
        VStack(spacing: 0) {
            tableHeaderRow
            Divider()

            List(displayedItems, id: \.filePath, selection: $selectedItemPaths) { item in
                tableItemRow(for: item)
                    .tag(item.filePath)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onChange(of: selectedItemPaths) { _, newValue in
                if let last = newValue.first, !newValue.contains(primarySelectedPath ?? "") {
                    primarySelectedPath = last
                }
            }
        }
    }

    private func groupedTableBrowserView(browserEntries: [BrowserEntry], activeItem: PrintFileItem?) -> some View {
        VStack(spacing: 0) {
            tableHeaderRow
            Divider()

            List {
                ForEach(browserEntries) { entry in
                    switch entry {
                    case .single(let item):
                        let isSelected = selectedItemPaths.contains(item.filePath)
                            || (selectedItemPaths.isEmpty && activeItem?.filePath == item.filePath)
                        tableItemRow(for: item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                handleSelection(for: item, toggleMulti: NSEvent.modifierFlags.contains(.command))
                            }
                            .listRowBackground(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)

                    case .group(let group):
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedTableGroupIDs.contains(group.id) },
                                set: { isExpanded in
                                    if isExpanded {
                                        expandedTableGroupIDs.insert(group.id)
                                    } else {
                                        expandedTableGroupIDs.remove(group.id)
                                    }
                                }
                            )
                        ) {
                            ForEach(group.items, id: \.filePath) { part in
                                let isPartSelected = selectedItemPaths.contains(part.filePath)
                                    || (selectedItemPaths.isEmpty && activeItem?.filePath == part.filePath)
                                tableItemRow(for: part)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        handleSelection(for: part, toggleMulti: NSEvent.modifierFlags.contains(.command))
                                    }
                                    .listRowBackground(isPartSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: group.reason == .projectFolder ? "folder.fill" : "square.stack.3d.up.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                    Text(group.title)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                    Text("\(group.items.count) parts")
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.14))
                                        .foregroundStyle(Color.accentColor)
                                        .clipShape(Capsule())
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Group {
                                    if let cat = group.sharedCategory {
                                        Label(cat.name, systemImage: cat.iconName)
                                            .font(.caption)
                                            .foregroundStyle(cat.color)
                                            .lineLimit(1)
                                    } else if group.items.contains(where: { $0.category != nil }) {
                                        Text("Mixed Categories")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Uncategorized")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 150, alignment: .leading)

                                Text(group.reason.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 145, alignment: .leading)

                                Text("—")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .trailing)

                                Text(group.formattedTotalFileSize)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 75, alignment: .trailing)

                                Button {
                                    Task {
                                        _ = await slicerService.sendToSlicer(items: group.items)
                                    }
                                } label: {
                                    Label("Slice All", systemImage: "paperplane.fill")
                                }
                                .controlSize(.small)
                                .frame(width: 75, alignment: .center)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                openedGroupID = group.id
                                selectedItemPaths = [group.primaryItem.filePath]
                                primarySelectedPath = group.primaryItem.filePath
                            }
                            .onTapGesture {
                                selectedItemPaths = [group.primaryItem.filePath]
                                primarySelectedPath = group.primaryItem.filePath
                            }
                            .draggable(group.items.map(\.filePath).joined(separator: "\n"))
                            .contextMenu {
                                Button {
                                    openedGroupID = group.id
                                    selectedItemPaths = [group.primaryItem.filePath]
                                    primarySelectedPath = group.primaryItem.filePath
                                } label: {
                                    Label("Open \(group.items.count) Parts", systemImage: "square.stack.3d.up")
                                }

                                Button {
                                    Task {
                                        _ = await slicerService.sendToSlicer(items: group.items)
                                    }
                                } label: {
                                    Label("Send All \(group.items.count) to \(slicerService.defaultProfile.name)", systemImage: "paperplane.fill")
                                }

                                Divider()

                                Menu("Assign Category to All \(group.items.count)") {
                                    Button("Uncategorized") {
                                        for item in group.items { item.category = nil }
                                        try? modelContext.save()
                                    }
                                    Divider()
                                    ForEach(categories) { category in
                                        Button {
                                            for item in group.items { item.category = category }
                                            try? modelContext.save()
                                        } label: {
                                            Label(category.name, systemImage: category.iconName)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    @ViewBuilder
    private func tableRowContextMenu(for item: PrintFileItem) -> some View {
        Button {
            Task {
                _ = await slicerService.sendToSlicer(items: [item])
            }
        } label: {
            Label("Send to \(slicerService.defaultProfile.name)", systemImage: "paperplane.fill")
        }

        Menu("Send to Specific Slicer") {
            ForEach(slicerService.profiles) { profile in
                Button(profile.name) {
                    Task {
                        _ = await slicerService.sendToSlicer(items: [item], using: profile)
                    }
                }
            }
        }

        Button {
            expandedPreviewItem = item
        } label: {
            Label("Expand 3D Preview", systemImage: "cube.transparent")
        }

        Divider()

        Menu("Assign Category") {
            Button("Uncategorized") { item.category = nil }
            Divider()
            ForEach(categories) { category in
                Button {
                    item.category = category
                } label: {
                    Label(category.name, systemImage: category.iconName)
                }
            }
        }

        Menu("Set Print Status") {
            ForEach(PrintStatus.allCases) { status in
                Button {
                    item.printStatus = status
                } label: {
                    Label(status.label, systemImage: status.systemImage)
                }
            }
        }

        Button {
            item.isFavorite.toggle()
        } label: {
            Label(item.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: "heart")
        }

        Divider()

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }

        Button(role: .destructive) {
            modelContext.delete(item)
            try? modelContext.save()
        } label: {
            Label("Remove from Library", systemImage: "trash")
        }
    }

    private func handleSelection(for item: PrintFileItem, toggleMulti: Bool) {
        if toggleMulti {
            if selectedItemPaths.contains(item.filePath) {
                selectedItemPaths.remove(item.filePath)
                if primarySelectedPath == item.filePath {
                    primarySelectedPath = selectedItemPaths.first
                }
            } else {
                selectedItemPaths.insert(item.filePath)
                primarySelectedPath = item.filePath
            }
        } else {
            selectedItemPaths = [item.filePath]
            primarySelectedPath = item.filePath
        }
    }

    private var emptyBrowserView: some View {
        VStack(spacing: 14) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No 3D Print Models Match This Filter")
                .font(.title3.weight(.semibold))

            Text("Drop .STL or .3MF files here, add a Watched Folder, scan Spotlight, or generate sample 3D models to test.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 10) {
                Button {
                    Task {
                        await scanner.performFullScan(context: modelContext, includeSpotlight: true)
                    }
                } label: {
                    Label("Scan Spotlight & Folders", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task {
                        let urls = SampleMeshGenerator.createSampleModelsOnDisk()
                        _ = await scanner.importURLs(urls, into: modelContext)
                        if let first = computeFilteredItems().first {
                            selectedItemPaths = [first.filePath]
                            primarySelectedPath = first.filePath
                        }
                    }
                } label: {
                    Label("Create Sample .STL & .3MF Models", systemImage: "sparkles")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyInspectorPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "cube.box")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Select a 3D Model")
                .font(.headline)
            Text("Inspect interactive 3D geometry, categorize, sync Finder tags, and send directly to your slicer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ScanToolbarButton(scanner: scanner) {
                Task {
                    await scanner.performFullScan(context: modelContext, includeSpotlight: true)
                }
            }

            Button {
                promptImportFilesOrFolders()
            } label: {
                Label("Import", systemImage: "plus.rectangle.on.folder")
            }
            .help("Import 3D model files or folders")

            Menu {
                Button {
                    Task {
                        let urls = SampleMeshGenerator.createSampleModelsOnDisk()
                        _ = await scanner.importURLs(urls, into: modelContext)
                        if primarySelectedPath == nil, let first = allItems.first {
                            selectedItemPaths = [first.filePath]
                            primarySelectedPath = first.filePath
                        }
                    }
                } label: {
                    Label("Generate Sample .STL & .3MF Models", systemImage: "sparkles")
                }

                Divider()

                Button {
                    _ = scanner.pruneMissingFiles(context: modelContext)
                } label: {
                    Label("Prune Missing Files from Library", systemImage: "trash.slash")
                }

                Button {
                    let (removed, moved) = VLMCategorizerService.mergeDuplicateCategories(context: modelContext)
                    scanner.statusMessage = removed > 0
                        ? "Merged \(removed) duplicate categor\(removed == 1 ? "y" : "ies") (\(moved) model\(moved == 1 ? "" : "s") moved)."
                        : "No duplicate categories found."
                } label: {
                    Label("Merge Duplicate Categories", systemImage: "arrow.triangle.merge")
                }

                Button {
                    preferEmbedded3MFThumbnails.toggle()
                    ThumbnailService.shared.preferEmbedded3MFThumbnails = preferEmbedded3MFThumbnails
                    ThumbnailService.shared.clearCache()
                    thumbnailGeneration += 1
                    scanner.statusMessage = preferEmbedded3MFThumbnails
                        ? "Showing embedded .3MF preview images."
                        : "Rendering uniform 3D studio thumbnails for all models."
                } label: {
                    Label(
                        preferEmbedded3MFThumbnails ? "Use Uniform 3D Thumbnails for .3MF" : "Use Embedded .3MF Previews",
                        systemImage: preferEmbedded3MFThumbnails ? "cube.fill" : "photo"
                    )
                }

                Button {
                    ThumbnailService.shared.clearCache()
                    thumbnailGeneration += 1
                    scanner.statusMessage = "Cleared thumbnail cache."
                } label: {
                    Label("Clear Thumbnail Cache", systemImage: "photo.stack")
                }
            } label: {
                Label("Library Tools", systemImage: "ellipsis.circle")
            }
            .help("Sample Models & Library Maintenance")

            Button {
                showSlicerSettings = true
            } label: {
                Label("Slicer Hooks", systemImage: "printer.fill")
            }
            .help("Configure Bambu Studio, OrcaSlicer, PrusaSlicer, Cura, and CLI hooks")
        }
    }

    // MARK: - Create / Edit Category Sheet

    private func beginCreateCategory() {
        editingCategory = nil
        categoryNameDraft = ""
        categoryIconDraft = "cube.box.fill"
        categoryColorDraft = .blue
        showCategorySheet = true
    }

    private func beginEditCategory(_ category: PrintCategory) {
        editingCategory = category
        categoryNameDraft = category.name
        categoryIconDraft = category.iconName
        categoryColorDraft = category.color
        showCategorySheet = true
    }

    private var categoryEditorSheet: some View {
        let icons = [
            "cube.box.fill", "gearshape.2.fill", "square.grid.3x3.topleft.filled",
            "figure.stand", "house.fill", "theatermasks.fill", "ruler.fill",
            "wrench.and.screwdriver.fill", "gamecontroller.fill", "cpu.fill"
        ]

        return VStack(alignment: .leading, spacing: 14) {
            Text(editingCategory == nil ? "Create Category" : "Edit Category")
                .font(.headline)

            TextField("Category Name (e.g. Multiboard, Voron Parts, Desk Setup)", text: $categoryNameDraft)
                .textFieldStyle(.roundedBorder)

            ColorPicker("Badge Color", selection: $categoryColorDraft, supportsOpacity: false)

            Text("Icon")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                ForEach(icons, id: \.self) { icon in
                    Button {
                        categoryIconDraft = icon
                    } label: {
                        Image(systemName: icon)
                            .font(.title3)
                            .frame(width: 36, height: 36)
                            .background(categoryIconDraft == icon ? categoryColorDraft.opacity(0.25) : Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showCategorySheet = false
                }
                Button(editingCategory == nil ? "Create" : "Save") {
                    let trimmed = categoryNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if let existing = editingCategory {
                        existing.name = trimmed
                        existing.iconName = categoryIconDraft
                        existing.colorHex = categoryColorDraft.toHex()
                    } else {
                        let cat = PrintCategory(
                            name: trimmed,
                            iconName: categoryIconDraft,
                            colorHex: categoryColorDraft.toHex(),
                            sortOrder: categories.count
                        )
                        modelContext.insert(cat)
                    }
                    try? modelContext.save()
                    showCategorySheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(categoryNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    // MARK: - Bootstrap & File Dialog Helpers

    private func bootstrapInitialDataAndScan() async {
        // Remove any previously indexed unsupported formats (e.g. .obj, .ply) and collapse slug duplicate categories
        _ = scanner.pruneUnsupportedFormats(context: modelContext)
        _ = VLMCategorizerService.mergeDuplicateCategories(context: modelContext)

        if categories.isEmpty {
            for (idx, seed) in PrintCategory.defaultSeeds.enumerated() {
                let cat = PrintCategory(
                    name: seed.name,
                    iconName: seed.icon,
                    colorHex: seed.hex,
                    sortOrder: idx
                )
                modelContext.insert(cat)
            }
            try? modelContext.save()
        }

        if watchedFolders.isEmpty {
            let fm = FileManager.default
            if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                modelContext.insert(WatchedFolder(path: downloads.path, displayName: "Downloads"))
            }
            if let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                modelContext.insert(WatchedFolder(path: documents.path, displayName: "Documents"))
            }
            try? modelContext.save()
        }

        if allItems.isEmpty {
            let sampleURLs = SampleMeshGenerator.createSampleModelsOnDisk()
            _ = await scanner.importURLs(sampleURLs, into: modelContext)
        }

        await scanner.performFullScan(context: modelContext, includeSpotlight: true)

        if primarySelectedPath == nil, let first = allItems.first {
            selectedItemPaths = [first.filePath]
            primarySelectedPath = first.filePath
        }
    }

    private func promptAddWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch Folder"
        if panel.runModal() == .OK, let url = panel.url {
            if !watchedFolders.contains(where: { $0.path == url.path }) {
                let wf = WatchedFolder(path: url.path)
                modelContext.insert(wf)
                try? modelContext.save()
                Task {
                    await scanner.scanWatchedFolders(context: modelContext)
                    await scanner.analyzeUnprocessedMeshes(context: modelContext)
                }
            }
        }
    }

    private func promptImportFilesOrFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import 3D Files"
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task {
                _ = await scanner.importURLs(urls, into: modelContext)
            }
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        Task {
            var collectedURLs: [URL] = []
            for provider in providers {
                if let url = await loadFileURL(from: provider) {
                    collectedURLs.append(url)
                }
            }
            if !collectedURLs.isEmpty {
                _ = await scanner.importURLs(collectedURLs, into: modelContext)
            }
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Isolated Subviews (Prevent Status/Scan Updates from Re-rendering Model Grid)

private struct StatusFooterBar: View {
    let scanner: FileScannerService
    let slicerService: SlicerService

    var body: some View {
        HStack(spacing: 10) {
            if scanner.isBusy || scanner.isAnalyzingMeshes {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
            }

            Text(scanner.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let banner = slicerService.lastStatusBanner {
                Text(banner)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text("Default Slicer: \(slicerService.defaultProfile.name)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ScanToolbarButton: View {
    let scanner: FileScannerService
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Scan Files", systemImage: "arrow.clockwise")
        }
        .disabled(scanner.isBusy)
        .help("Scan Watched Folders and macOS Spotlight for .stl and .3mf files")
    }
}
