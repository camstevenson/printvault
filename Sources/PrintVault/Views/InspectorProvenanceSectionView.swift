import SwiftUI
import SwiftData

struct InspectorProvenanceSectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: PrintFileItem
    let containingGroupTitle: String?
    let watchedFolderPaths: [String]

    @State private var sourceURLDraft: String = ""
    @State private var designerDraft: String = ""
    @State private var licenseDraft: String = ""
    @State private var provenanceFeedback: String?
    @State private var isRefreshingFromDisk: Bool = false
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        let validSourceURL = item.resolvedSourceURL
        let isBareOrigin = item.isSourceURLBareOrigin
        let siteName = item.sourceHostDisplayName ?? "Source Site"
        let fallbackSearch: (query: String, url: URL)? = if isBareOrigin, let validSourceURL {
            makeFallbackSearch(for: validSourceURL)
        } else {
            nil
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Source & Attribution", systemImage: "globe")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let displaySite = item.sourceHostDisplayName {
                    Text(displaySite)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: .capsule)
                        .foregroundStyle(Color.accentColor)
                }
                if isRefreshingFromDisk {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Button(
                        "Refresh Download Provenance",
                        systemImage: "arrow.clockwise",
                        action: refreshProvenanceFromDisk
                    )
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .controlSize(.mini)
                    .foregroundStyle(.secondary)
                    .help("Re-read macOS download provenance (kMDItemWhereFroms), .3mf metadata, and folder README from disk")
                }
            }

            HStack(spacing: 6) {
                if let fallbackSearch {
                    Button {
                        openExternalURL(fallbackSearch.url)
                    } label: {
                        Label("Find on \(siteName)", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Search \(siteName) for \"\(fallbackSearch.query)\"")
                } else {
                    Button {
                        if let validSourceURL {
                            openExternalURL(validSourceURL)
                        }
                    } label: {
                        Label(
                            isBareOrigin ? "Open \(siteName)" : "Open Source Page",
                            systemImage: "arrow.up.right.square"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(validSourceURL == nil)
                    .help(validSourceURL?.absoluteString ?? "Add a valid http(s) source URL to open the original model page")
                }

                if let validSourceURL {
                    if fallbackSearch != nil {
                        Button("Open \(siteName) Homepage", systemImage: "arrow.up.right.square") {
                            openExternalURL(validSourceURL)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open \(validSourceURL.absoluteString)")
                    }

                    Button("Copy Source URL", systemImage: "link") {
                        copySourceURL(validSourceURL)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy Source URL")
                }
            }

            if isBareOrigin {
                Group {
                    if let fallbackSearch {
                        Text("macOS only recorded \(siteName)'s homepage (CDN downloads strip the model path). Find searches for \"\(fallbackSearch.query)\", or paste the exact URL below.")
                    } else {
                        Text("macOS only recorded \(siteName)'s homepage (CDN downloads strip the model path). Paste the exact model URL below if desired.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let provenanceFeedback {
                HStack(spacing: 5) {
                    Label(provenanceFeedback, systemImage: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss Provenance Notice", systemImage: "xmark", action: dismissFeedback)
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        .buttonStyle(.plain)
                }
            }

            InspectorProvenanceFieldsView(
                sourceURLDraft: $sourceURLDraft,
                designerDraft: $designerDraft,
                licenseDraft: $licenseDraft
            )
        }
        .onAppear(perform: syncDraftsFromItem)
        .onChange(of: item.filePath, handleItemChanged)
        .onChange(of: item.sourceURL, syncSourceURLFromModel)
        .onChange(of: item.designer, syncDesignerFromModel)
        .onChange(of: item.license, syncLicenseFromModel)
        .onChange(of: sourceURLDraft, persistSourceURLChange)
        .onChange(of: designerDraft, persistDesignerChange)
        .onChange(of: licenseDraft, persistLicenseChange)
        .onDisappear(perform: cancelRefresh)
    }

    // MARK: - Actions & Persistence

    private func makeFallbackSearch(for siteURL: URL) -> (query: String, url: URL)? {
        let query = DownloadProvenanceService.suggestedSearchQuery(
            for: item.fileURL,
            groupTitle: containingGroupTitle,
            watchedFolderPaths: watchedFolderPaths
        )
        guard let url = DownloadProvenanceService.siteSearchURL(for: siteURL, query: query) else {
            return nil
        }
        return (query, url)
    }

    private func openExternalURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func copySourceURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        provenanceFeedback = "Copied source URL."
    }

    private func dismissFeedback() {
        provenanceFeedback = nil
    }

    private func handleItemChanged() {
        cancelRefresh()
        provenanceFeedback = nil
        syncDraftsFromItem()
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshingFromDisk = false
    }

    private func syncDraftsFromItem() {
        let nextURL = item.sourceURL ?? ""
        if sourceURLDraft != nextURL {
            sourceURLDraft = nextURL
        }
        let nextDesigner = item.designer ?? ""
        if designerDraft != nextDesigner {
            designerDraft = nextDesigner
        }
        let nextLicense = item.license ?? ""
        if licenseDraft != nextLicense {
            licenseDraft = nextLicense
        }
    }

    private func syncSourceURLFromModel(_: String?, _ newValue: String?) {
        if normalizedOptionalText(sourceURLDraft) != newValue {
            sourceURLDraft = newValue ?? ""
        }
    }

    private func syncDesignerFromModel(_: String?, _ newValue: String?) {
        if normalizedOptionalText(designerDraft) != newValue {
            designerDraft = newValue ?? ""
        }
    }

    private func syncLicenseFromModel(_: String?, _ newValue: String?) {
        if normalizedOptionalText(licenseDraft) != newValue {
            licenseDraft = newValue ?? ""
        }
    }

    private func normalizedOptionalText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistSourceURLChange(_: String, _ newValue: String) {
        let normalized = normalizedOptionalText(newValue)
        guard item.sourceURL != normalized else { return }
        item.sourceURL = normalized
        saveChanges()
    }

    private func persistDesignerChange(_: String, _ newValue: String) {
        let normalized = normalizedOptionalText(newValue)
        guard item.designer != normalized else { return }
        item.designer = normalized
        saveChanges()
    }

    private func persistLicenseChange(_: String, _ newValue: String) {
        let normalized = normalizedOptionalText(newValue)
        guard item.license != normalized else { return }
        item.license = normalized
        saveChanges()
    }

    private func saveChanges() {
        do {
            try modelContext.save()
        } catch {
            provenanceFeedback = "Could not save provenance: \(error.localizedDescription)"
        }
    }

    private func refreshProvenanceFromDisk() {
        let targetPath = item.filePath
        let targetURL = item.fileURL
        guard item.fileExistsOnDisk else {
            provenanceFeedback = "File is missing on disk."
            return
        }

        refreshTask?.cancel()
        isRefreshingFromDisk = true
        provenanceFeedback = nil

        refreshTask = Task {
            let provenance = await DownloadProvenanceService.readProvenanceAsync(for: targetURL)
            guard !Task.isCancelled, item.filePath == targetPath else { return }
            isRefreshingFromDisk = false
            refreshTask = nil
            applyRefreshedProvenance(provenance)
        }
    }

    private func applyRefreshedProvenance(_ provenance: DownloadProvenance) {
        guard !provenance.isEmpty else {
            provenanceFeedback = "No macOS download provenance (kMDItemWhereFroms) found on this file."
            return
        }

        var updated = false
        if let url = provenance.sourceURL {
            let currentBlank = item.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            let upgradesBareOrigin = DownloadProvenanceService.isBareOriginURL(item.sourceURL)
                && !DownloadProvenanceService.isBareOriginURL(url)
            if currentBlank || upgradesBareOrigin || (item.sourceURL != url && !DownloadProvenanceService.isBareOriginURL(url)) {
                item.sourceURL = url
                sourceURLDraft = url
                updated = true
            }
        }
        if let designer = provenance.designer,
           (item.designer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            item.designer = designer
            designerDraft = designer
            updated = true
        }
        if let license = provenance.license,
           (item.license?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            item.license = license
            licenseDraft = license
            updated = true
        }

        if updated {
            do {
                try modelContext.save()
                provenanceFeedback = "Updated download provenance from macOS metadata."
            } catch {
                provenanceFeedback = "Could not save provenance: \(error.localizedDescription)"
            }
        } else {
            provenanceFeedback = "Download provenance is already up to date."
        }
    }
}
