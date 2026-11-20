import SwiftUI
import SwiftData
import AppKit

struct InspectorPaneView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: PrintFileItem
    let categories: [PrintCategory]
    @Bindable var slicerService: SlicerService
    let onOpenSlicerSettings: () -> Void

    @State private var newTagText: String = ""
    @State private var slicerFeedbackBanner: String?
    @State private var showExpandedPreview: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Top 3D Viewport
            Preview3DView(item: item, onExpand: { showExpandedPreview = true })
                .frame(height: 295)

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

                    Divider()

                    // Categorization & Print Status
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Category & Status", systemImage: "folder.badge.gearshape")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if item.category == nil {
                                Button("Auto-Suggest") {
                                    if let suggested = FileScannerService.suggestCategory(
                                        fileName: item.fileName,
                                        filePath: item.filePath,
                                        finderTags: item.tags,
                                        availableCategories: categories
                                    ) {
                                        item.category = suggested
                                    }
                                }
                                .controlSize(.mini)
                            }
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
                                FinderTagService.syncToFinder(for: item)
                                slicerFeedbackBanner = "Synced tags & category to macOS Finder."
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
                        Label("3D Geometry & Print Metrics", systemImage: "cube.transparent")
                            .font(.subheadline.weight(.semibold))

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
                                Text("Est. PLA (~35%)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(item.estimatedPLAWeightGrams > 0 ? String(format: "~%.1f g", item.estimatedPLAWeightGrams) : "—")
                                    .font(.caption.monospacedDigit())
                            }
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
                                    profile.isInstalled ? profile.name : "\(profile.name) (Configure Path)",
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
