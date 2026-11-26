import Foundation
import SwiftData
import Observation
import os

// MARK: - Discovered Candidate

public struct DiscoveredFileCandidate: Sendable {
    public let filePath: String
    public let fileName: String
    public let fileExtension: String
    public let fileSize: Int64
    public let dateModified: Date
    public let source: DiscoverySource
    public let finderTags: [String]
    public let sourceURL: String?
    public let designer: String?
    public let license: String?

    public init(
        filePath: String,
        fileName: String,
        fileExtension: String,
        fileSize: Int64,
        dateModified: Date,
        source: DiscoverySource,
        finderTags: [String],
        sourceURL: String? = nil,
        designer: String? = nil,
        license: String? = nil
    ) {
        self.filePath = filePath
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.dateModified = dateModified
        self.source = source
        self.finderTags = finderTags
        self.sourceURL = sourceURL
        self.designer = designer
        self.license = license
    }
}

// MARK: - FileScannerService

@MainActor
@Observable
public final class FileScannerService {
    private static let logger = Logger(subsystem: "com.printvault.PrintVault", category: "FileScanner")

    public var isScanningSpotlight: Bool = false
    public var isScanningFolders: Bool = false
    public var isAnalyzingMeshes: Bool = false
    public var statusMessage: String = "Ready"
    public var lastScanNewCount: Int = 0
    public var analyzedProgress: Double = 0

    private var metadataQuery: NSMetadataQuery?

    public init() {}

    public var isBusy: Bool {
        isScanningSpotlight || isScanningFolders
    }

    private func saveContext(_ context: ModelContext, operation: String) {
        do {
            try context.save()
        } catch {
            Self.logger.error("Failed to save SwiftData context during \(operation, privacy: .public): \(error.localizedDescription, privacy: .public)")
            statusMessage = "Save error during \(operation): \(error.localizedDescription)"
        }
    }

    // MARK: - Folder Path Boundary Helper

    /// Checks whether `filePath` is strictly inside `folderPath` (avoiding prefix collisions like `/Downloads2` matching `/Downloads`).
    public nonisolated static func matchesFolder(_ filePath: String, folderPath: String) -> Bool {
        let normalizedFolder = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        return filePath == folderPath || filePath.hasPrefix(normalizedFolder)
    }

    // MARK: - Combined Scan (Watched Folders + Spotlight)

    public func performFullScan(context: ModelContext, includeSpotlight: Bool = true) async {
        lastScanNewCount = 0
        await scanWatchedFolders(context: context)
        if includeSpotlight {
            await runSpotlightQuery(context: context)
        }
        await analyzeUnprocessedMeshes(context: context)
    }

    // MARK: - Watched Folders Scanner

    public func scanWatchedFolders(context: ModelContext) async {
        guard !isScanningFolders else { return }
        isScanningFolders = true
        defer { isScanningFolders = false }
        statusMessage = "Scanning watched folders..."

        let descriptor = FetchDescriptor<WatchedFolder>(
            predicate: #Predicate { $0.isEnabled == true }
        )
        let folders: [WatchedFolder]
        do {
            folders = try context.fetch(descriptor)
        } catch {
            Self.logger.error("Failed to fetch watched folders: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Failed to load watched folders."
            return
        }

        var totalAdded = 0
        for folder in folders {
            if Task.isCancelled { break }
            let folderURL = folder.url
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            statusMessage = "Scanning \(folder.displayName)..."

            let candidates = await Self.enumerateFolderRecursivelyAsync(at: folderURL, source: .watchedFolder)
            if Task.isCancelled { break }

            folder.lastScannedAt = Date()
            folder.discoveredFileCount = candidates.count

            let added = ingestCandidates(candidates, into: context)
            totalAdded += added
        }

        saveContext(context, operation: "watched folder scan")
        lastScanNewCount += totalAdded
        statusMessage = totalAdded > 0
            ? "Added \(totalAdded) new 3D model(s) from folders."
            : "Watched folders up to date."
    }

    // MARK: - Spotlight (NSMetadataQuery) System-Wide Discovery

    public func runSpotlightQuery(context: ModelContext, timeoutSeconds: Double = 15.0) async {
        guard !isScanningSpotlight else { return }
        isScanningSpotlight = true
        defer {
            isScanningSpotlight = false
            self.metadataQuery = nil
        }
        statusMessage = "Searching macOS Spotlight for .stl and .3mf files..."

        let query = NSMetadataQuery()
        self.metadataQuery = query
        query.predicate = NSPredicate(
            format: "kMDItemFSName LIKE[c] '*.stl' OR kMDItemFSName LIKE[c] '*.3mf'"
        )
        query.searchScopes = [NSMetadataQueryUserHomeScope]

        var rawItems: [(path: String, size: Int64, modDate: Date, whereFroms: [String])] = []

        if !Task.isCancelled && query.start() {
            @MainActor
            final class WaitState {
                var hasResumed = false
                var query: NSMetadataQuery?
                var observer: NSObjectProtocol?
                var timeoutTask: Task<Void, Never>?
                var continuation: CheckedContinuation<Void, Never>?

                init(query: NSMetadataQuery) {
                    self.query = query
                }

                func finish(stopQuery: Bool = false) {
                    guard !hasResumed else { return }
                    hasResumed = true
                    if stopQuery {
                        query?.disableUpdates()
                        query?.stop()
                    }
                    query = nil
                    if let observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    observer = nil
                    timeoutTask?.cancel()
                    timeoutTask = nil
                    let cont = continuation
                    continuation = nil
                    cont?.resume()
                }
            }

            let state = WaitState(query: query)

            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if Task.isCancelled {
                        state.query = nil
                        continuation.resume()
                        return
                    }
                    state.continuation = continuation
                    state.observer = NotificationCenter.default.addObserver(
                        forName: .NSMetadataQueryDidFinishGathering,
                        object: query,
                        queue: .main
                    ) { _ in
                        MainActor.assumeIsolated {
                            state.finish()
                        }
                    }

                    state.timeoutTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(timeoutSeconds))
                        state.finish()
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    state.finish(stopQuery: true)
                }
            }

            query.disableUpdates()
            query.stop()

            if !Task.isCancelled {
                let count = min(query.resultCount, 2500)
                rawItems.reserveCapacity(count)
                for i in 0..<count {
                    guard let item = query.result(at: i) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else {
                        continue
                    }
                    if Self.shouldSkipPath(path) { continue }
                    let ext = (path as NSString).pathExtension.lowercased()
                    guard PrintFileFormat.supportedExtensions.contains(ext) else { continue }

                    let size = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0
                    let modDate = (item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date) ?? Date()
                    let whereFroms = (item.value(forAttribute: "kMDItemWhereFroms") as? [String]) ?? []
                    rawItems.append((path, size, modDate, whereFroms))
                }
            }
        }
        self.metadataQuery = nil

        guard !Task.isCancelled else {
            statusMessage = "Spotlight scan cancelled."
            return
        }

        // Read Finder tags off the main actor while cooperating with cancellation
        let candidates = await Self.buildSpotlightCandidatesAsync(from: rawItems)
        guard !Task.isCancelled else {
            statusMessage = "Spotlight scan cancelled."
            return
        }

        let added = ingestCandidates(candidates, into: context)
        saveContext(context, operation: "Spotlight scan")
        lastScanNewCount += added
        statusMessage = "Spotlight scan finished (\(candidates.count) found, \(added) new)."
    }

    // MARK: - Manual File / Folder Import

    @discardableResult
    public func importURLs(_ urls: [URL], into context: ModelContext) async -> Int {
        var allCandidates: [DiscoveredFileCandidate] = []
        for url in urls {
            if Task.isCancelled { break }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let sub = await Self.enumerateFolderRecursivelyAsync(at: url, source: .manual)
                allCandidates.append(contentsOf: sub)
            } else {
                let ext = url.pathExtension.lowercased()
                guard PrintFileFormat.supportedExtensions.contains(ext) else { continue }
                if let candidate = Self.makeCandidate(from: url, source: .manual) {
                    allCandidates.append(candidate)
                }
            }
        }

        let added = ingestCandidates(allCandidates, into: context)
        saveContext(context, operation: "file import")
        await analyzeUnprocessedMeshes(context: context)
        return added
    }

    // MARK: - Prune Missing & Unsupported Files

    @discardableResult
    public func pruneUnsupportedFormats(context: ModelContext) -> Int {
        let items = (try? context.fetch(FetchDescriptor<PrintFileItem>())) ?? []
        var removed = 0
        for item in items where !PrintFileFormat.supportedExtensions.contains(item.fileExtension.lowercased()) {
            context.delete(item)
            removed += 1
        }
        if removed > 0 {
            saveContext(context, operation: "pruning unsupported formats")
        }
        return removed
    }

    @discardableResult
    public func pruneMissingFiles(context: ModelContext) -> Int {
        let items = (try? context.fetch(FetchDescriptor<PrintFileItem>())) ?? []
        var removed = 0
        for item in items where !item.fileExistsOnDisk {
            context.delete(item)
            removed += 1
        }
        if removed > 0 {
            saveContext(context, operation: "pruning missing files")
            statusMessage = "Removed \(removed) missing file(s) from library."
        } else {
            statusMessage = "All library files are present on disk."
        }
        return removed
    }

    // MARK: - Candidate Ingestion & Smart Auto-Categorization

    private func ingestCandidates(_ candidates: [DiscoveredFileCandidate], into context: ModelContext) -> Int {
        guard !candidates.isEmpty else { return 0 }

        let existingItems: [PrintFileItem]
        do {
            existingItems = try context.fetch(FetchDescriptor<PrintFileItem>())
        } catch {
            Self.logger.error("Failed to fetch existing items before ingestion: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        var existingByPath = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.filePath, $0) })

        let categories = (try? context.fetch(FetchDescriptor<PrintCategory>())) ?? []
        var addedCount = 0

        for candidate in candidates {
            if let existing = existingByPath[candidate.filePath] {
                if existing.fileSize != candidate.fileSize || existing.dateModified != candidate.dateModified {
                    existing.fileSize = candidate.fileSize
                    existing.dateModified = candidate.dateModified
                    existing.meshAnalyzed = false
                    existing.surfaceAreaCm2 = 0
                }
                if !candidate.finderTags.isEmpty {
                    let merged = Set(existing.tags).union(candidate.finderTags)
                    existing.tags = Array(merged).sorted()
                }
                let existingURLBlank = existing.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
                if let discoveredURL = candidate.sourceURL {
                    let canUpgradeBareOrigin = DownloadProvenanceService.isBareOriginURL(existing.sourceURL)
                        && !DownloadProvenanceService.isBareOriginURL(discoveredURL)
                    if existingURLBlank || canUpgradeBareOrigin {
                        existing.sourceURL = discoveredURL
                    }
                }
                if (existing.designer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                   let discoveredDesigner = candidate.designer {
                    existing.designer = discoveredDesigner
                }
                if (existing.license?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                   let discoveredLicense = candidate.license {
                    existing.license = discoveredLicense
                }
            } else {
                let autoCat = Self.suggestCategory(
                    fileName: candidate.fileName,
                    filePath: candidate.filePath,
                    finderTags: candidate.finderTags,
                    availableCategories: categories
                )
                let newItem = PrintFileItem(
                    filePath: candidate.filePath,
                    fileName: candidate.fileName,
                    fileExtension: candidate.fileExtension,
                    fileSize: candidate.fileSize,
                    dateModified: candidate.dateModified,
                    discoverySource: candidate.source,
                    category: autoCat,
                    tags: candidate.finderTags,
                    sourceURL: candidate.sourceURL,
                    designer: candidate.designer,
                    license: candidate.license
                )
                context.insert(newItem)
                existingByPath[candidate.filePath] = newItem
                addedCount += 1
            }
        }
        return addedCount
    }

    /// Runs keyword heuristics to auto-categorize uncategorized items.
    @discardableResult
    public func autoCategorizeUncategorized(context: ModelContext) -> Int {
        let items = (try? context.fetch(FetchDescriptor<PrintFileItem>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<PrintCategory>())) ?? []
        var updatedCount = 0

        for item in items where item.category == nil {
            if let match = Self.suggestCategory(
                fileName: item.fileName,
                filePath: item.filePath,
                finderTags: item.tags,
                availableCategories: categories
            ) {
                item.category = match
                updatedCount += 1
            }
        }
        saveContext(context, operation: "auto-categorization")
        return updatedCount
    }

    public static func suggestCategory(
        fileName: String,
        filePath: String,
        finderTags: [String],
        availableCategories: [PrintCategory]
    ) -> PrintCategory? {
        let haystack = "\(fileName) \(URL(fileURLWithPath: filePath).deletingLastPathComponent().lastPathComponent) \(finderTags.joined(separator: " "))".lowercased()

        // First check if a Finder tag directly matches a category name
        for cat in availableCategories {
            if finderTags.contains(where: { $0.caseInsensitiveCompare(cat.name) == .orderedSame }) {
                return cat
            }
        }

        let rules: [(categorySubstring: String, keywords: [String])] = [
            ("Organizers", ["gridfinity", "multiboard", "bin", "organizer", "tray", "drawer", "box", "holder", "container", "divider", "rack", "spool"]),
            ("Calibration", ["benchy", "calibration", "calicat", "temp_tower", "temptower", "retraction", "tolerance", "xyz", "test", "first_layer"]),
            ("Miniatures", ["mini", "miniature", "dragon", "figurine", "statue", "bust", "dnd", "tabletop", "character", "monster", "articulated"]),
            ("Functional", ["gear", "bracket", "adapter", "clip", "hinge", "clamp", "bushing", "spacer", "bolt", "nut", "knob", "enclosure", "duct", "fan"]),
            ("Household", ["mount", "wall", "hook", "stand", "planter", "vase", "coaster", "lamp", "cable", "kitchen", "bath", "phone"]),
            ("Cosplay", ["helmet", "mask", "sword", "armor", "prop", "blaster", "cosplay", "shield", "wand"])
        ]

        for rule in rules {
            if rule.keywords.contains(where: { haystack.contains($0) }) {
                if let match = availableCategories.first(where: { $0.name.localizedCaseInsensitiveContains(rule.categorySubstring) }) {
                    return match
                }
            }
        }
        return nil
    }

    // MARK: - Background 3D Mesh Geometry Analyzer

    public func analyzeUnprocessedMeshes(context: ModelContext) async {
        guard !isAnalyzingMeshes else { return }
        let descriptor = FetchDescriptor<PrintFileItem>(
            predicate: #Predicate { $0.meshAnalyzed == false || $0.surfaceAreaCm2 == 0 }
        )
        let pending: [PrintFileItem]
        do {
            pending = try context.fetch(descriptor)
        } catch {
            Self.logger.error("Failed to fetch pending meshes for analysis: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !pending.isEmpty else { return }

        isAnalyzingMeshes = true
        defer { isAnalyzingMeshes = false }
        analyzedProgress = 0
        let total = pending.count
        let chunkSize = 12

        var processed = 0
        while processed < total {
            if Task.isCancelled { break }
            let end = min(processed + chunkSize, total)
            let chunk = Array(pending[processed..<end])
            let urls = chunk.map(\.fileURL)

            // Analyze chunk off the main actor while inheriting cancellation from the parent task
            let results = await Self.analyzeMetadataChunkAsync(urls: urls)

            for (offset, meta) in results.enumerated() {
                let item = chunk[offset]
                if let meta {
                    item.vertexCount = meta.vertexCount
                    item.triangleCount = meta.triangleCount
                    item.dimensionX = meta.dimensionX
                    item.dimensionY = meta.dimensionY
                    item.dimensionZ = meta.dimensionZ
                    item.estimatedVolumeCm3 = meta.volumeCm3
                    // Use -1 sentinel when surface area is unavailable (e.g. ModelIO fallback) so this item is not re-analyzed forever
                    item.surfaceAreaCm2 = meta.surfaceAreaCm2 > 0 ? meta.surfaceAreaCm2 : -1
                    item.embeddedSubModelCount = meta.subModelCount
                } else {
                    item.surfaceAreaCm2 = -1
                }
                item.meshAnalyzed = true
            }

            processed += results.count
            analyzedProgress = Double(processed) / Double(total)
            saveContext(context, operation: "mesh analysis")
            if Task.isCancelled { break }
            await Task.yield()
        }

        statusMessage = "Ready"
    }

    // MARK: - Off-Main-Actor Cooperative Async Helpers

    private nonisolated static func enumerateFolderRecursivelyAsync(
        at folderURL: URL,
        source: DiscoverySource
    ) async -> [DiscoveredFileCandidate] {
        enumerateFolderRecursively(at: folderURL, source: source)
    }

    private nonisolated static func buildSpotlightCandidatesAsync(
        from rawItems: [(path: String, size: Int64, modDate: Date, whereFroms: [String])]
    ) async -> [DiscoveredFileCandidate] {
        var candidates: [DiscoveredFileCandidate] = []
        candidates.reserveCapacity(rawItems.count)
        for entry in rawItems {
            if Task.isCancelled { break }
            let url = URL(fileURLWithPath: entry.path)
            let tags = FinderTagService.readTags(for: url)
            let provenance = DownloadProvenanceService.readProvenance(
                for: url,
                spotlightWhereFroms: entry.whereFroms
            )
            candidates.append(
                DiscoveredFileCandidate(
                    filePath: entry.path,
                    fileName: url.lastPathComponent,
                    fileExtension: url.pathExtension.lowercased(),
                    fileSize: entry.size,
                    dateModified: entry.modDate,
                    source: .spotlight,
                    finderTags: tags,
                    sourceURL: provenance.sourceURL,
                    designer: provenance.designer,
                    license: provenance.license
                )
            )
        }
        return candidates
    }

    private nonisolated static func analyzeMetadataChunkAsync(urls: [URL]) async -> [MeshMetadata?] {
        var out: [MeshMetadata?] = []
        out.reserveCapacity(urls.count)
        for url in urls {
            if Task.isCancelled { break }
            out.append(await MeshLoaderService.analyzeMetadata(at: url))
        }
        return out
    }

    // MARK: - File System Enumeration Helpers

    public nonisolated static func enumerateFolderRecursively(
        at folderURL: URL,
        source: DiscoverySource
    ) -> [DiscoveredFileCandidate] {
        var results: [DiscoveredFileCandidate] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            let path = fileURL.path
            if shouldSkipPath(path) {
                enumerator.skipDescendants()
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            guard PrintFileFormat.supportedExtensions.contains(ext) else { continue }
            if let candidate = makeCandidate(from: fileURL, source: source) {
                results.append(candidate)
            }
        }
        return results
    }

    public nonisolated static func makeCandidate(from url: URL, source: DiscoverySource) -> DiscoveredFileCandidate? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true else {
            return nil
        }
        let size = Int64(values.fileSize ?? 0)
        let modified = values.contentModificationDate ?? Date()
        let tags = FinderTagService.readTags(for: url)
        let provenance = DownloadProvenanceService.readProvenance(for: url)
        return DiscoveredFileCandidate(
            filePath: url.path,
            fileName: url.lastPathComponent,
            fileExtension: url.pathExtension.lowercased(),
            fileSize: size,
            dateModified: modified,
            source: source,
            finderTags: tags,
            sourceURL: provenance.sourceURL,
            designer: provenance.designer,
            license: provenance.license
        )
    }

    /// Clears all category assignments, tags, and notes from every indexed model and deletes all categories.
    /// Optionally restores the default category seeds immediately. Never modifies or deletes 3D files on disk.
    @discardableResult
    public func clearAllOrganizationMetadata(
        context: ModelContext,
        restoreDefaultCategories: Bool = false
    ) -> (clearedItems: Int, deletedCategories: Int) {
        let items = (try? context.fetch(FetchDescriptor<PrintFileItem>())) ?? []
        var clearedItems = 0
        for item in items {
            let hadMetadata = item.category != nil || !item.tags.isEmpty || !item.notes.isEmpty
            item.category = nil
            item.tags = []
            item.notes = ""
            if hadMetadata {
                clearedItems += 1
            }
        }

        let existingCategories = (try? context.fetch(FetchDescriptor<PrintCategory>())) ?? []
        let deletedCategories = existingCategories.count
        for category in existingCategories {
            context.delete(category)
        }

        if restoreDefaultCategories {
            for (idx, seed) in PrintCategory.defaultSeeds.enumerated() {
                let cat = PrintCategory(
                    name: seed.name,
                    iconName: seed.icon,
                    colorHex: seed.hex,
                    sortOrder: idx
                )
                context.insert(cat)
            }
        }

        saveContext(context, operation: "clearing organization metadata")
        statusMessage = restoreDefaultCategories
            ? "Cleared metadata on \(clearedItems) model(s) and restored \(PrintCategory.defaultSeeds.count) default categories."
            : "Cleared metadata on \(clearedItems) model(s) and removed \(deletedCategories) categor\(deletedCategories == 1 ? "y" : "ies")."
        return (clearedItems, deletedCategories)
    }

    public nonisolated static func shouldSkipPath(_ path: String) -> Bool {
        let ignoredSegments = [
            "/.Trash/",
            "/Library/Caches/",
            "/Library/Application Support/CrashReporter/",
            "/node_modules/",
            "/.git/",
            "/.build/",
            "/DerivedData/"
        ]
        return ignoredSegments.contains { path.contains($0) }
    }
}
