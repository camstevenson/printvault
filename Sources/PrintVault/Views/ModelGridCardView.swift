import SwiftUI
import SwiftData
import AppKit

struct ModelGridCardView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: PrintFileItem
    let isSelected: Bool
    let categories: [PrintCategory]
    let defaultSlicerName: String
    let slicerProfiles: [SlicerProfile]
    let thumbnailGeneration: Int
    let onSendToSlicer: (PrintFileItem, SlicerProfile?) -> Void
    let onSelect: (_ toggleMultiSelect: Bool) -> Void
    var onDoubleClick: (() -> Void)? = nil

    @State private var thumbnailImage: NSImage?

    init(
        item: PrintFileItem,
        isSelected: Bool,
        categories: [PrintCategory],
        defaultSlicerName: String,
        slicerProfiles: [SlicerProfile],
        thumbnailGeneration: Int = 0,
        onSendToSlicer: @escaping (PrintFileItem, SlicerProfile?) -> Void,
        onSelect: @escaping (_ toggleMultiSelect: Bool) -> Void,
        onDoubleClick: (() -> Void)? = nil
    ) {
        self.item = item
        self.isSelected = isSelected
        self.categories = categories
        self.defaultSlicerName = defaultSlicerName
        self.slicerProfiles = slicerProfiles
        self.thumbnailGeneration = thumbnailGeneration
        self.onSendToSlicer = onSendToSlicer
        self.onSelect = onSelect
        self.onDoubleClick = onDoubleClick
        // Synchronous memory-cache hit avoids empty flash + layout churn during scrolling
        _thumbnailImage = State(initialValue: ThumbnailService.shared.cachedThumbnail(for: item.filePath))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail Preview Area
            ZStack(alignment: .topLeading) {
                Color(red: 0.14, green: 0.15, blue: 0.18)
                    .frame(height: 145)

                if let thumbnailImage {
                    Image(nsImage: thumbnailImage)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: 145)
                        .clipped()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.4))
                        Text(item.format.badgeText)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: 145)
                }

                // Top-left format badge + status (solid translucent backgrounds, no NSVisualEffectView)
                HStack(spacing: 5) {
                    Text(item.format.badgeText)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(item.format.badgeColor.opacity(0.9))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())

                    if item.printStatus != .unprinted {
                        HStack(spacing: 3) {
                            Image(systemName: item.printStatus.systemImage)
                            Text(item.printStatus.label)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(item.printStatus.color.opacity(0.88))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }

                    Spacer()

                    if item.isFavorite {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .padding(5)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                    }
                }
                .padding(8)

                // Isolated hover button so cursor movement during scroll doesn't re-render the card
                CardHoverSliceOverlay(defaultSlicerName: defaultSlicerName) {
                    onSendToSlicer(item, nil)
                }
            }
            .frame(height: 145)
            .clipped()

            Divider()

            // Card Footer Details
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if let category = item.category {
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
                    } else {
                        Text("Uncategorized")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(item.formattedFileSize)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: "ruler")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(item.hasDimensions ? item.formattedDimensions : item.parentFolderName)
                        .font(.caption2.monospacedDigit())
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
                    isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2) {
            onSelect(false)
            onDoubleClick?()
        }
        .onTapGesture {
            let isCmdPressed = NSEvent.modifierFlags.contains(.command)
            onSelect(isCmdPressed)
        }
        .draggable(item.filePath)
        .contextMenu {
            contextMenuItems
        }
        .task(id: "\(item.filePath)|\(item.dateModified.timeIntervalSince1970)|\(thumbnailGeneration)") {
            if let cached = ThumbnailService.shared.cachedThumbnail(for: item.filePath), thumbnailImage !== cached {
                thumbnailImage = cached
            }
            let loaded = await ThumbnailService.shared.thumbnail(for: item.fileURL)
            if !Task.isCancelled {
                thumbnailImage = loaded
            }
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            onSendToSlicer(item, nil)
        } label: {
            Label("Send to \(defaultSlicerName)", systemImage: "paperplane.fill")
        }

        Menu("Send to Specific Slicer") {
            ForEach(slicerProfiles) { profile in
                Button(profile.name) {
                    onSendToSlicer(item, profile)
                }
            }
        }

        Divider()

        Menu("Assign Category") {
            Button("Uncategorized") {
                item.category = nil
                try? modelContext.save()
            }
            Divider()
            ForEach(categories) { category in
                Button {
                    item.category = category
                    try? modelContext.save()
                } label: {
                    Label(category.name, systemImage: category.iconName)
                }
            }
        }

        Menu("Set Print Status") {
            ForEach(PrintStatus.allCases) { status in
                Button {
                    item.printStatus = status
                    try? modelContext.save()
                } label: {
                    Label(status.label, systemImage: status.systemImage)
                }
            }
        }

        Button {
            item.isFavorite.toggle()
            try? modelContext.save()
        } label: {
            Label(item.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: "heart")
        }

        Button {
            FinderTagService.syncToFinder(for: item)
        } label: {
            Label("Sync Category & Tags to Finder", systemImage: "tag")
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
}

// MARK: - Isolated Hover Overlay

private struct CardHoverSliceOverlay: View {
    let defaultSlicerName: String
    let onSlice: () -> Void

    @State private var isHovering = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay(alignment: .bottomTrailing) {
                if isHovering {
                    Button(action: onSlice) {
                        Label("Slice", systemImage: "paperplane.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Send to \(defaultSlicerName)")
                    .padding(8)
                }
            }
            .onHover { hovering in
                if isHovering != hovering {
                    isHovering = hovering
                }
            }
    }
}
