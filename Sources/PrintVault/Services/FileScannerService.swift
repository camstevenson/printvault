import Foundation
import SwiftData
import Observation

// MARK: - Discovered Candidate

public struct DiscoveredFileCandidate: Sendable {
    public let filePath: String
    public let fileName: String
    public let fileExtension: String
    public let fileSize: Int64
    public let dateModified: Date
    public let source: DiscoverySource
    public let finderTags: [String]
}

// MARK: - FileScannerService

@MainActor
@Observable
public final class FileScannerService {
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
        statusMessage = "Scanning watched folders..."

        let descriptor = FetchDescriptor<WatchedFolder>(
            predicate: #Predicate { $0.isEnabled == true }
        )
        let folders = (try? context.fetch(descriptor)) ?? []

        var totalAdded = 0
        for folder in folders {
            let folderURL = folder.url
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            statusMessage = "Scanning \(folder.displayName)..."

            let candidates = await Task.detached(priority: .utility) {
                Self.enumerateFolderRecursively(at: folderURL, source: .watchedFolder)
            }.value

            folder.lastScannedAt = Date()
            folder.discoveredFileCount = candidates.count

            let added = ingestCandidates(candidates, into: context)
            totalAdded += added
        }

        try? context.save()
        lastScanNewCount += totalAdded
        isScanningFolders = false
        statusMessage = totalAdded > 0
            ? "Added \(totalAdded) new 3D model(s) from folders."
            : "Watched folders up to date."
    }

    // MARK: - Spotlight (NSMetadataQuery) System-Wide Discovery

    public func runSpotlightQuery(context: ModelContext, timeoutSeconds: Double = 15.0) async {
        guard !isScanningSpotlight else { return }
        isScanningSpotlight = true
        statusMessage = "Searching macOS Spotlight for .stl and .3mf files..."

        let query = NSMetadataQuery()
        self.metadataQuery = query
        query.predicate = NSPredicate(
            format: "kMDItemFSName LIKE[c] '*.stl' OR kMDItemFSName LIKE[c] '*.3mf'"
        )
        query.searchScopes = [NSMetadataQueryUserHomeScope]

        var rawItems: [(path: String, size: Int64, modDate: Date)] = []

        if query.start() {
            // Race Spotlight finish notification against a timeout on MainActor without crossing Sendable boundaries
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                @MainActor
                final class WaitState {
                    var hasResumed = false
                    var observer: NSObjectProtocol?
                    var timeoutTask: Task<Void, Never>?

                    func finish(_ continuation: CheckedContinuation<Void, Never>) {
                        guard !hasResumed else { return }
                        hasResumed = true
                        if let observer {
                            NotificationCenter.default.removeObserver(observer)
                        }
                        observer = nil
                        timeoutTask?.cancel()
                        timeoutTask = nil
                        continuation.resume()
                    }
                }

                let state = WaitState()
                state.observer = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering,
                    object: query,
                    queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        state.finish(continuation)
                    }
                }

                state.timeoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    state.finish(continuation)
                }
            }

            query.disableUpdates()
            query.stop()

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
                rawItems.append((path, size, modDate))
            }
        }
        self.metadataQuery = nil

        // Read Finder tags off the main actor
        let capturedRaw = rawItems
        let candidates: [DiscoveredFileCandidate] = await Task.detached(priority: .utility) {
            capturedRaw.map { entry in
                let url = URL(fileURLWithPath: entry.path)
                let tags = FinderTagService.readTags(for: url)
                return DiscoveredFileCandidate(
                    filePath: entry.path,
                    fileName: url.lastPathComponent,
                    fileExtension: url.pathExtension.lowercased(),
                    fileSize: entry.size,
                    dateModified: entry.modDate,
                    source: .spotlight,
                    finderTags: tags
                )
            }
        }.value

        let added = ingestCandidates(candidates, into: context)
        try? context.save()
        lastScanNewCount += added
        isScanningSpotlight = false
        statusMessage = "Spotlight scan finished (\(candidates.count) found, \(added) new)."
    }

    // MARK: - Manual File / Folder Import

    @discardableResult
    public func importURLs(_ urls: [URL], into context: ModelContext) async -> Int {
        var allCandidates: [DiscoveredFileCandidate] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let sub = await Task.detached(priority: .userInitiated) {
                    Self.enumerateFolderRecursively(at: url, source: .manual)
                }.value
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
        try? context.save()
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
            try? context.save()
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
            try? context.save()
            statusMessage = "Removed \(removed) missing file(s) from library."
        } else {
            statusMessage = "All library files are present on disk."
        }
        return removed
    }

    // MARK: - Candidate Ingestion & Smart Auto-Categorization

    private func ingestCandidates(_ candidates: [DiscoveredFileCandidate], into context: ModelContext) -> Int {
        guard !candidates.isEmpty else { return 0 }

        let existingItems = (try? context.fetch(FetchDescriptor<PrintFileItem>())) ?? []
        var existingByPath = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.filePath, $0) })

        let categories = (try? context.fetch(FetchDescriptor<PrintCategory>())) ?? []
        var addedCount = 0

        for candidate in candidates {
            if let existing = existingByPath[candidate.filePath] {
                if existing.fileSize != candidate.fileSize || existing.dateModified != candidate.dateModified {
                    existing.fileSize = candidate.fileSize
                    existing.dateModified = candidate.dateModified
                    existing.meshAnalyzed = false
                }
                if !candidate.finderTags.isEmpty {
                    let merged = Set(existing.tags).union(candidate.finderTags)
                    existing.tags = Array(merged).sorted()
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
                    tags: candidate.finderTags
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
        try? context.save()
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
            predicate: #Predicate { $0.meshAnalyzed == false }
        )
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }

        isAnalyzingMeshes = true
        analyzedProgress = 0
        let batch = Array(pending.prefix(200))
        let total = batch.count
        let chunkSize = 12

        var processed = 0
        while processed < total {
            if Task.isCancelled { break }
            let end = min(processed + chunkSize, total)
            let chunk = Array(batch[processed..<end])
            let urls = chunk.map(\.fileURL)

            // Analyze chunk off the main actor before mutating SwiftData models to avoid per-item @Query storms
            let results: [MeshMetadata?] = await Task.detached(priority: .utility) {
                var out: [MeshMetadata?] = []
                out.reserveCapacity(urls.count)
                for url in urls {
                    if Task.isCancelled { break }
                    out.append(await MeshLoaderService.analyzeMetadata(at: url))
                }
                return out
            }.value

            for (offset, meta) in results.enumerated() {
                let item = chunk[offset]
                if let meta {
                    item.vertexCount = meta.vertexCount
                    item.triangleCount = meta.triangleCount
                    item.dimensionX = meta.dimensionX
                    item.dimensionY = meta.dimensionY
                    item.dimensionZ = meta.dimensionZ
                    item.estimatedVolumeCm3 = meta.volumeCm3
                    item.embeddedSubModelCount = meta.subModelCount
                }
                item.meshAnalyzed = true
            }

            processed = end
            analyzedProgress = Double(processed) / Double(total)
            try? context.save()
            await Task.yield()
        }

        isAnalyzingMeshes = false
        statusMessage = "Ready"
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
        return DiscoveredFileCandidate(
            filePath: url.path,
            fileName: url.lastPathComponent,
            fileExtension: url.pathExtension.lowercased(),
            fileSize: size,
            dateModified: modified,
            source: source,
            finderTags: tags
        )
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
