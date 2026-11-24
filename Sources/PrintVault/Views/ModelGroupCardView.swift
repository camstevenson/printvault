import SwiftUI
import SwiftData
import AppKit

struct ModelGroupCardView: View {
    @Environment(\.modelContext) private var modelContext
    let group: ModelGroup
    let isSelected: Bool
    let categories: [PrintCategory]
    let defaultSlicerName: String
    let slicerProfiles: [SlicerProfile]
    let thumbnailGeneration: Int
    let onSendAllToSlicer: ([PrintFileItem], SlicerProfile?) -> Void
    let onSelect: () -> Void
    let onOpenGroup: () -> Void

    @State private var thumbnailImage: NSImage?

    init(
        group: ModelGroup,
        isSelected: Bool,
        categories: [PrintCategory],
        defaultSlicerName: String,
        slicerProfiles: [SlicerProfile],
        thumbnailGeneration: Int = 0,
        onSendAllToSlicer: @escaping ([PrintFileItem], SlicerProfile?) -> Void,
        onSelect: @escaping () -> Void,
        onOpenGroup: @escaping () -> Void
    ) {
        self.group = group
        self.isSelected = isSelected
        self.categories = categories
        self.defaultSlicerName = defaultSlicerName
        self.slicerProfiles = slicerProfiles
        self.thumbnailGeneration = thumbnailGeneration
        self.onSendAllToSlicer = onSendAllToSlicer
        self.onSelect = onSelect
        self.onOpenGroup = onOpenGroup
        _thumbnailImage = State(initialValue: ThumbnailService.shared.cachedThumbnail(for: group.primaryItem.filePath))
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Back card (3rd layer of the stack)
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            // Middle card (2nd layer of the stack)
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                )
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 6)

            // Front card
            VStack(alignment: .leading, spacing: 0) {
                // Hero Thumbnail Preview Area
                ZStack(alignment: .topLeading) {
                    Color(red: 0.14, green: 0.15, blue: 0.18)
                        .frame(height: 134)

                    if let thumbnailImage {
                        Image(nsImage: thumbnailImage)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: 134)
                            .clipped()
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.45))
                            Text("\(group.items.count) parts")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .frame(maxWidth: .infinity, maxHeight: 134)
                    }

                    GroupCardHoverOverlay(
                        partCount: group.items.count,
                        defaultSlicerName: defaultSlicerName,
                        onSliceAll: { onSendAllToSlicer(group.items, nil) }
                    )

                    // Top badges: format + clickable "N parts ▸" drill-in pill (above hover overlay so clicks hit the pill)
                    HStack(spacing: 5) {
                        ForEach(group.formats.prefix(2)) { fmt in
                            Text(fmt.badgeText)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(fmt.badgeColor.opacity(0.9))
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }

                        Spacer()

                        PartsPillButton(
                            partCount: group.items.count,
                            action: onOpenGroup
                        )
                    }
                    .padding(8)
                }
                .frame(height: 134)
                .clipped()

                Divider()

                // Card Footer Details
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 2)
                        if group.hasFavorite {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.red)
                                .font(.caption2)
                        }
                    }

                    HStack(spacing: 6) {
                        if let category = group.sharedCategory {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(category.color)
                                    .frame(width: 7, height: 7)
                                Text(category.name)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(category.color.opacity(0.14))
                            .clipShape(Capsule())
                        } else if group.items.contains(where: { $0.category != nil }) {
                            Text("Mixed Categories")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Uncategorized")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(group.formattedTotalFileSize)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: group.reason == .projectFolder ? "folder.fill" : "square.stack.3d.up.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.accentColor)
                        Text("\(group.items.count) parts • \(group.reason.rawValue)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.20),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            )
            .padding(.top, 8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2) {
            onOpenGroup()
        }
        .onTapGesture {
            onSelect()
        }
        .draggable(group.items.map(\.filePath).joined(separator: "\n"))
        .contextMenu {
            contextMenuItems
        }
        .task(id: "\(group.primaryItem.filePath)|\(group.primaryItem.dateModified.timeIntervalSince1970)|\(thumbnailGeneration)") {
            if let cached = ThumbnailService.shared.cachedThumbnail(for: group.primaryItem.filePath), thumbnailImage !== cached {
                thumbnailImage = cached
            }
            let loaded = await ThumbnailService.shared.thumbnail(for: group.primaryItem.fileURL)
            if !Task.isCancelled {
                thumbnailImage = loaded
            }
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            onOpenGroup()
        } label: {
            Label("Open \(group.items.count) Parts", systemImage: "square.stack.3d.up")
        }

        Button {
            onSendAllToSlicer(group.items, nil)
        } label: {
            Label("Send All \(group.items.count) to \(defaultSlicerName)", systemImage: "paperplane.fill")
        }

        Menu("Send All \(group.items.count) to Specific Slicer") {
            ForEach(slicerProfiles) { profile in
                Button(profile.name) {
                    onSendAllToSlicer(group.items, profile)
                }
            }
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

        Menu("Set Print Status for All \(group.items.count)") {
            ForEach(PrintStatus.allCases) { status in
                Button {
                    for item in group.items { item.printStatus = status }
                    try? modelContext.save()
                } label: {
                    Label(status.label, systemImage: status.systemImage)
                }
            }
        }

        Divider()

        Button {
            let folderURL = group.primaryItem.fileURL.deletingLastPathComponent()
            NSWorkspace.shared.open(folderURL)
        } label: {
            Label("Reveal Folder in Finder", systemImage: "folder")
        }
    }
}

// MARK: - Clickable Parts Pill

private struct PartsPillButton: View {
    let partCount: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "square.stack.3d.up.fill")
                Text("\(partCount) parts")
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(isHovering ? 1.0 : 0.90))
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if isHovering != hovering {
                isHovering = hovering
            }
        }
        .help("Open all \(partCount) parts in this model")
    }
}

// MARK: - Isolated Hover Overlay

private struct GroupCardHoverOverlay: View {
    let partCount: Int
    let defaultSlicerName: String
    let onSliceAll: () -> Void

    @State private var isHovering = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay(alignment: .bottomTrailing) {
                if isHovering {
                    Button(action: onSliceAll) {
                        Label("Slice All", systemImage: "paperplane.fill")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(8)
                    .help("Send all \(partCount) parts to \(defaultSlicerName)")
                }
            }
            .onHover { hovering in
                if isHovering != hovering {
                    isHovering = hovering
                }
            }
    }
}
