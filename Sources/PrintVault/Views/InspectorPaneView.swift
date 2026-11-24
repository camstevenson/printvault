import SwiftUI
import SwiftData
import AppKit

struct InspectorPaneView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: PrintFileItem
    let categories: [PrintCategory]
    @Bindable var slicerService: SlicerService
    @Bindable var vlmService: VLMCategorizerService
    let onOpenSlicerSettings: () -> Void
    let onOpenAICategorize: () -> Void
    var containingGroup: ModelGroup? = nil
    var watchedFolderPaths: [String] = []
    var onSelectSiblingPart: ((PrintFileItem) -> Void)? = nil
    var onOpenGroup: (() -> Void)? = nil

    @AppStorage("PrintVault.EstimatedInfillPercent") private var estimatedInfillPercent: Double = 20.0
    @State private var newTagText: String = ""
    @State private var slicerFeedbackBanner: String?
    @State private var showExpandedPreview: Bool = false
    @State private var classifyingItemPath: String?
    @State private var aiClassificationTask: Task<Void, Never>?
    @State private var aiFeedbackText: String?

    private var isClassifyingCurrentItem: Bool {
        classifyingItemPath == item.filePath
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top 3D Viewport
            Preview3DView(item: item, onExpand: { showExpandedPreview = true })
                .frame(height: 295)
                .clipped()

            Divider()

            // Primary Send to Slicer Action Bar
            slicerActionBar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Scrollable Inspector Details
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !item.fileExistsOnDisk {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("File is missing on disk. It may have been moved or deleted.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    // Title & Quick Actions
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.displayTitle)
                                .font(.headline)
                                .textSelection(.enabled)
                            Text(item.fileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            item.isFavorite.toggle()
                        } label: {
                            Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                                .foregroundStyle(item.isFavorite ? .red : .secondary)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .help("Toggle Favorite")
                    }

                    // Star Rating
                    HStack(spacing: 4) {
                        Text("Rating")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ForEach(1...5, id: \.self) { star in
                            Button {
                                item.rating = (item.rating == star) ? 0 : star
                            } label: {
                                Image(systemName: star <= item.rating ? "star.fill" : "star")
                                    .foregroundStyle(star <= item.rating ? .yellow : .secondary.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let group = containingGroup, group.items.count > 1 {
                        Divider()
                        groupPartsSwitcher(group: group)
                    }

                    Divider()

                    // Categorization & Print Status
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Category & Status", systemImage: "folder.badge.gearshape")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if isClassifyingCurrentItem {
                                HStack(spacing: 5) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Analyzing...")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Button {
                                    runSingleItemAICategorize()
                                } label: {
                                    Label("AI Categorize", systemImage: "sparkles")
                                }
                                .controlSize(.mini)
                                .help("Classify this 3D model visually using your local Vision-Language Model")
                            }
                        }

                        if let aiFeedbackText {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkles")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                                Text(aiFeedbackText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Spacer()
                                Button {
                                    self.aiFeedbackText = nil
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(6)
                            .background(Color.accentColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        Picker("Category", selection: $item.category) {
                            Text("Uncategorized").tag(Optional<PrintCategory>.none)
                            Divider()
                            ForEach(categories) { category in
                                Label(category.name, systemImage: category.iconName)
                                    .tag(Optional(category))
                            }
                        }

                        Picker("Print Status", selection: $item.printStatus) {
                            ForEach(PrintStatus.allCases) { status in
                                Label(status.label, systemImage: status.systemImage)
                                    .tag(status)
                            }
                        }
                    }

                    Divider()

                    // Tags & macOS Finder Tag Sync
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Tags", systemImage: "tag.fill")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button {
                                let synced = FinderTagService.syncToFinder(for: item)
                                slicerFeedbackBanner = synced
                                    ? "Synced tags & category to macOS Finder."
                                    : "Failed to write macOS Finder tags (file missing or read-only)."
                            } label: {
                                Label("Push to Finder", systemImage: "arrow.up.doc")
                            }
                            .controlSize(.mini)
                            .help("Write category and tags to native macOS Finder tags")
                        }

                        if !item.tags.isEmpty {
                            FlowTagLayout(spacing: 6) {
                                ForEach(item.tags, id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        Text(tag)
                                            .font(.caption)
                                        Button {
                                            item.tags.removeAll { $0 == tag }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.14))
                                    .clipShape(Capsule())
                                }
                            }
                        }

                        HStack(spacing: 6) {
                            TextField("Add tag (e.g. PLA, Gridfinity, VaseMode)...", text: $newTagText)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onSubmit {
                                    addTag()
                                }
                            Button("Add") {
                                addTag()
                            }
                            .controlSize(.small)
                            .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    Divider()

                    // 3D Geometry & Filament Estimates
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("3D Geometry & Print Metrics", systemImage: "cube.transparent")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Picker("Infill", selection: $estimatedInfillPercent) {
                                Text("15% infill").tag(15.0)
                                Text("20% infill").tag(20.0)
                                Text("35% infill").tag(35.0)
                                Text("50% infill").tag(50.0)
                                Text("100% solid").tag(100.0)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.mini)
                            .fixedSize()
                            .help("Interior infill % used with 1.0 mm outer walls for filament estimates (excludes slicer supports & brims)")
                        }

                        let effectiveFillPct = Int((item.estimatedEffectiveFillFraction(infillPercent: estimatedInfillPercent) * 100.0).rounded())
                        let weightGrams = item.estimatedPLAWeightGrams(infillPercent: estimatedInfillPercent)
                        let filamentLengthText = item.formattedEstimatedFilamentLength(infillPercent: estimatedInfillPercent)

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            GridRow {
                                Text("Dimensions")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(item.formattedDimensions)
                                    .font(.caption.monospacedDigit().weight(.medium))
                            }
                            GridRow {
                                Text("Triangles")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(item.triangleCount > 0 ? item.triangleCount.formatted() : "—")
                                    .font(.caption.monospacedDigit())
                            }
                            if item.embeddedSubModelCount > 1 {
                                GridRow {
                                    Text("Sub-Models")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(item.embeddedSubModelCount) meshes")
                                        .font(.caption.monospacedDigit())
                                }
                            }
                            GridRow {
                                Text("Mesh Volume")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(item.estimatedVolumeCm3 > 0 ? String(format: "%.2f cm³", item.estimatedVolumeCm3) : "—")
                                    .font(.caption.monospacedDigit())
                            }
                            GridRow {
                                Text(effectiveFillPct > 0 ? "Est. PLA (~\(effectiveFillPct)% fill)" : "Est. PLA")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(weightGrams > 0 ? String(format: "~%.1f g", weightGrams) : "—")
                                    .font(.caption.monospacedDigit())
                            }
                            .help("Shell + infill geometry estimate (1.0 mm walls, \(Int(estimatedInfillPercent))% infill, 1.24 g/cm³ PLA). Excludes slicer supports, brims, and rafts.")
                            GridRow {
                                Text("Est. Filament (1.75mm)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(filamentLengthText)
                                    .font(.caption.monospacedDigit())
                            }
                            .help("Estimated 1.75 mm filament length before slicer supports, brims, or purge lines.")
                            GridRow {
                                Text("File Size")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(item.formattedFileSize)
                                    .font(.caption)
                            }
                            GridRow {
                                Text("Source")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(item.discoverySourceRaw)
                                    .font(.caption)
                            }
                            if let lastSliced = item.lastSentToSlicerDate {
                                GridRow {
                                    Text("Last Sliced")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(item.lastUsedSlicerName ?? "Slicer") • \(lastSliced.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                }
                            }
                        }
                    }

                    Divider()

                    // Print Notes
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Print Notes & Slicer Settings", systemImage: "note.text")
                            .font(.subheadline.weight(.semibold))
                        TextEditor(text: $item.notes)
                            .font(.caption)
                            .frame(minHeight: 72)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }

                    // File Path & Reveal in Finder
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.filePath)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)

                        HStack {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                            .controlSize(.small)

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.filePath, forType: .string)
                            } label: {
                                Label("Copy Path", systemImage: "doc.on.doc")
                            }
                            .controlSize(.small)

                            Spacer()

                            Button(role: .destructive) {
                                modelContext.delete(item)
                                try? modelContext.save()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .controlSize(.small)
                            .help("Remove from PrintVault Library (does not delete file on disk)")
                        }
                    }
                }
                .padding(14)
            }
        }
        .sheet(isPresented: $showExpandedPreview) {
            ExpandedPreview3DSheet(item: item, slicerService: slicerService)
        }
        .onChange(of: item.filePath) { _, _ in
            aiFeedbackText = nil
            slicerFeedbackBanner = nil
            newTagText = ""
        }
        .onDisappear {
            aiClassificationTask?.cancel()
            aiClassificationTask = nil
            classifyingItemPath = nil
        }
    }

    // MARK: - Multi-Part Group Switcher

    private func groupPartsSwitcher(group: ModelGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("\(group.title) (\(group.items.count))", systemImage: "square.stack.3d.up")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let onOpenGroup {
                    Button("Open", action: onOpenGroup)
                        .controlSize(.mini)
                        .help("Open all parts of \(group.title) in the browser")
                }
                Button {
                    Task {
                        _ = await slicerService.sendToSlicer(items: group.items, using: slicerService.defaultProfile)
                        slicerFeedbackBanner = slicerService.lastStatusBanner
                    }
                } label: {
                    Label("Slice All", systemImage: "paperplane.fill")
                }
                .controlSize(.mini)
                .help("Send all \(group.items.count) parts to \(slicerService.defaultProfile.name)")
            }

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(group.items, id: \.filePath) { part in
                        let isCurrent = part.filePath == item.filePath
                        Button {
                            onSelectSiblingPart?(part)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isCurrent ? "checkmark.circle.fill" : "cube")
                                    .font(.caption2)
                                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                                    .frame(width: 14)

                                Text(part.displayTitle)
                                    .font(.caption.weight(isCurrent ? .semibold : .regular))
                                    .foregroundStyle(isCurrent ? .primary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer(minLength: 4)

                                Text(part.format.badgeText)
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(part.format.badgeColor.opacity(0.8))
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())

                                Text(part.formattedFileSize)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isCurrent ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.03))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: group.items.count > 4 ? 136 : nil)
        }
    }

    // MARK: - Slicer Action Bar

    private var slicerActionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    Task {
                        let ok = await slicerService.sendToSlicer(items: [item], using: slicerService.defaultProfile)
                        slicerFeedbackBanner = slicerService.lastStatusBanner
                        if !ok {
                            // Keep banner visible
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill")
                        Text("Send to \(slicerService.defaultProfile.name)")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Menu {
                    Section("Send to Specific Slicer") {
                        ForEach(slicerService.profiles) { profile in
                            Button {
                                Task {
                                    _ = await slicerService.sendToSlicer(items: [item], using: profile)
                                    slicerFeedbackBanner = slicerService.lastStatusBanner
                                }
                            } label: {
                                Label(
                                    slicerService.isInstalled(profile) ? profile.name : "\(profile.name) (Configure Path)",
                                    systemImage: profile.iconSystemName
                                )
                            }
                        }
                    }
                    Divider()
                    Button {
                        onOpenSlicerSettings()
                    } label: {
                        Label("Configure Slicers & CLI Hooks...", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderedButton)
                .menuIndicator(.hidden)
                .controlSize(.large)
                .fixedSize()
                .help("Choose Slicer or Configure Hooks")
            }

            if let banner = slicerFeedbackBanner {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                    Text(banner)
                        .font(.caption2)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        slicerFeedbackBanner = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func addTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !item.tags.contains(trimmed) {
            item.tags.append(trimmed)
        }
        newTagText = ""
    }

    private func runSingleItemAICategorize() {
        let targetItem = item
        let targetPath = targetItem.filePath
        guard classifyingItemPath != targetPath else { return }

        aiClassificationTask?.cancel()
        classifyingItemPath = targetPath
        aiFeedbackText = nil

        let capturedGroup = containingGroup
        let capturedFolders = watchedFolderPaths

        aiClassificationTask = Task {
            defer {
                if classifyingItemPath == targetPath {
                    classifyingItemPath = nil
                }
            }

            if case .connected = vlmService.connectionState {
                // Already connected
            } else {
                await vlmService.detectLocalRuntimes()
            }
            guard !Task.isCancelled else { return }

            guard case .connected = vlmService.connectionState, !vlmService.config.selectedModel.isEmpty else {
                // Open the full AI Auto-Categorize sheet so the user can 1-click Start Ollama or Download qwen2.5vl:3b
                onOpenAICategorize()
                return
            }

            let liveCategories = (try? modelContext.fetch(FetchDescriptor<PrintCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? categories
            let suggestion = await vlmService.classifySingleItem(
                targetItem,
                existingCategories: liveCategories,
                containingGroup: capturedGroup,
                watchedFolderPaths: capturedFolders
            )
            guard !Task.isCancelled else { return }

            if let err = suggestion.errorMessage {
                if item.filePath == targetPath {
                    aiFeedbackText = err
                }
                return
            }

            let refreshedCategories = (try? modelContext.fetch(FetchDescriptor<PrintCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? liveCategories
            let applied = vlmService.applySingleSuggestion(
                suggestion,
                to: targetItem,
                existingCategories: refreshedCategories,
                context: modelContext
            )
            if applied {
                try? modelContext.save()
                if item.filePath == targetPath {
                    let pct = Int((suggestion.confidence * 100).rounded())
                    aiFeedbackText = "\(suggestion.suggestedCategoryName) (\(pct)%)" + (suggestion.summary.isEmpty ? "" : " — \(suggestion.summary)")
                }
            } else if item.filePath == targetPath {
                aiFeedbackText = "No category match found."
            }
        }
    }
}

// MARK: - FlowTagLayout

struct FlowTagLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 260
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
