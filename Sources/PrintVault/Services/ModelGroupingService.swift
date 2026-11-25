import Foundation

// MARK: - Model Group & Browser Entry

public enum ModelGroupReason: String, Sendable, Equatable {
    case projectFolder = "Project Folder"
    case sharedStem = "Multi-Part Set"
}

public struct ModelGroup: Identifiable {
    public let id: String
    public let title: String
    public let items: [PrintFileItem]
    public let primaryItem: PrintFileItem
    public let reason: ModelGroupReason

    public var totalFileSize: Int64 {
        items.reduce(0) { $0 + $1.fileSize }
    }

    public var formattedTotalFileSize: String {
        ByteCountFormatter.string(fromByteCount: totalFileSize, countStyle: .file)
    }

    public var sharedCategory: PrintCategory? {
        let nonNil = items.compactMap(\.category)
        guard let first = nonNil.first else { return nil }
        let allSame = nonNil.allSatisfy { $0.id == first.id }
        return allSame ? first : nil
    }

    public var hasFavorite: Bool {
        items.contains(where: \.isFavorite)
    }

    public var formats: [PrintFileFormat] {
        var seen = Set<PrintFileFormat>()
        var out: [PrintFileFormat] = []
        for item in items where seen.insert(item.format).inserted {
            out.append(item.format)
        }
        return out
    }
}

public enum BrowserEntry: Identifiable {
    case single(PrintFileItem)
    case group(ModelGroup)

    public var id: String {
        switch self {
        case .single(let item): return "single:\(item.filePath)"
        case .group(let group): return group.id
        }
    }

    public var primaryItem: PrintFileItem {
        switch self {
        case .single(let item): return item
        case .group(let group): return group.primaryItem
        }
    }

    public var allItems: [PrintFileItem] {
        switch self {
        case .single(let item): return [item]
        case .group(let group): return group.items
        }
    }
}

// MARK: - ModelGroupingService

public enum ModelGroupingService {

    /// Wrapper subfolders commonly created by Thingiverse, Printables, MakerWorld, and Cults3D archives.
    private static let wrapperFolderNames: Set<String> = [
        "files", "stl", "stls", "3mf", "models", "parts", "meshes",
        "presupported", "pre-supported", "supported", "unsupported", "no supports",
        "plates", "print files", "model files", "components", "pieces",
        "v1", "v2", "v3", "print", "prints", "resources"
    ]

    /// Generic catch-all folders whose direct contents should never be blindly grouped together.
    private static let genericContainerNames: Set<String> = [
        "downloads", "documents", "desktop", "home", "users", "shared",
        "3d prints", "3d printing", "3d print", "3d models", "3d", "prints", "models",
        "stl", "stls", "stl files", "3mf", "3mf files", "thing", "things", "workspaces",
        "misc", "miscellaneous", "other", "unsorted", "temp", "tmp", "new folder",
        "to print", "printvault sample models", "icloud drive", "dropbox",
        "google drive", "onedrive", "archive", "backups", "files", "parts"
    ]

    /// Common assembly/multi-part tokens indicating parts of a single build rather than unrelated models.
    private static let assemblyPartTokens: Set<String> = [
        "part", "piece", "plate", "assembly", "complete", "full", "combined",
        "left", "right", "top", "bottom", "front", "back", "upper", "lower",
        "inner", "outer", "mid", "middle", "center", "side", "end",
        "body", "base", "lid", "cover", "cap", "frame", "shell", "core", "housing",
        "head", "torso", "chest", "arm", "leg", "hand", "foot", "wing", "tail", "horn",
        "visor", "jaw", "neck", "stand", "insert", "tray", "drawer", "divider",
        "pin", "peg", "clip", "ring", "rim", "handle", "grip", "blade", "hilt", "guard",
        "pommel", "door", "panel", "wall", "roof", "floor", "gate", "arch", "pillar",
        "nut", "bolt", "screw", "clamp", "knob", "bracket", "hinge", "plug", "track",
        "supported", "presupported", "unsupported", "hollow", "solid", "split", "cut",
        "solo", "mini", "copy", "flat", "recessed", "no-support", "nosupport"
    ]

    /// Tokens that are valid explicit part suffixes (e.g. `tower_top`, `dragon_base`) when stripping stems.
    private static let stemSuffixTokens: Set<String> = [
        "part", "pt", "piece", "plate", "assembly", "complete", "full", "combined",
        "left", "right", "top", "bottom", "front", "back", "upper", "lower",
        "inner", "outer", "mid", "middle", "center", "side", "end",
        "body", "base", "lid", "cover", "cap", "frame", "shell", "core",
        "head", "torso", "arm", "leg", "hand", "foot", "wing", "tail",
        "stand", "insert", "tray", "divider", "clip", "handle", "blade", "pommel",
        "door", "wall", "roof", "floor", "plug", "hinge", "clips", "solo",
        "supported", "presupported", "unsupported", "hollow", "solid", "split", "cut",
        "fdm", "mmu", "copy", "version", "ver", "rev", "final", "fixed", "remix", "alt"
    ]

    /// Non-distinctive stop words excluded when testing token overlap between filenames and folder names.
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "stl", "3mf", "file", "files",
        "model", "models", "print", "prints", "3d", "mesh", "object", "new",
        "final", "fixed", "repaired", "scaled", "remix", "version", "ver", "rev",
        "mm", "cm", "inch", "mini", "big", "small", "large", "medium", "test",
        "fdm", "unsupported", "supported", "presupported", "free", "pack", "all"
    ]

    /// Lightweight `Sendable` snapshot of a `PrintFileItem` so grouping heuristics and disk companion checks
    /// can execute completely off the main actor without touching SwiftData `@Model` instances off-thread.
    private struct GroupingItemSnapshot: Sendable {
        let index: Int
        let filePath: String
        let fileName: String
        let displayTitle: String
        let fileSize: Int64
        let categoryID: UUID?

        var fileURL: URL {
            URL(fileURLWithPath: filePath)
        }
    }

    private struct ResolvedGroupPlan: Sendable {
        let id: String
        let title: String
        let memberIndices: [Int]
        let primaryIndex: Int
        let reason: ModelGroupReason
        let sortRank: Int
    }

    private enum ResolvedEntryPlan: Sendable {
        case single(index: Int, sortRank: Int)
        case group(ResolvedGroupPlan)

        var sortRank: Int {
            switch self {
            case .single(_, let rank): return rank
            case .group(let plan): return plan.sortRank
            }
        }
    }

    private nonisolated static func makeExcludedRoots(watchedFolderPaths: [String]) -> Set<String> {
        let normalizedWatchedRoots = Set(watchedFolderPaths.map { normalizeDirPath($0) })
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return normalizedWatchedRoots.union([
            normalizeDirPath(home),
            normalizeDirPath("\(home)/Downloads"),
            normalizeDirPath("\(home)/Documents"),
            normalizeDirPath("\(home)/Desktop")
        ])
    }

    /// Groups related 3D print files asynchronously off the main actor (keeping regexes and companion-file
    /// disk checks off the UI thread) while preserving the incoming sort order of `items`.
    @MainActor
    public static func groupItemsAsync(
        _ items: [PrintFileItem],
        watchedFolderPaths: [String]
    ) async -> [BrowserEntry] {
        guard items.count > 1 else {
            return items.map { .single($0) }
        }
        let snapshots = items.enumerated().map { idx, item in
            GroupingItemSnapshot(
                index: idx,
                filePath: item.filePath,
                fileName: item.fileName,
                displayTitle: item.displayTitle,
                fileSize: item.fileSize,
                categoryID: item.category?.id
            )
        }
        let plans = await computeGroupPlansOffMain(
            snapshots: snapshots,
            watchedFolderPaths: watchedFolderPaths
        )
        guard !Task.isCancelled else { return [] }
        return materializeEntries(from: plans, items: items)
    }

    /// Groups related 3D print files into multi-part `ModelGroup`s while keeping dissimilar files standalone.
    /// Preserves the incoming sort order of `items`.
    @MainActor
    public static func groupItems(
        _ items: [PrintFileItem],
        watchedFolderPaths: [String]
    ) -> [BrowserEntry] {
        guard items.count > 1 else {
            return items.map { .single($0) }
        }
        let snapshots = items.enumerated().map { idx, item in
            GroupingItemSnapshot(
                index: idx,
                filePath: item.filePath,
                fileName: item.fileName,
                displayTitle: item.displayTitle,
                fileSize: item.fileSize,
                categoryID: item.category?.id
            )
        }
        let plans = computeGroupPlans(
            snapshots: snapshots,
            watchedFolderPaths: watchedFolderPaths
        )
        return materializeEntries(from: plans, items: items)
    }

    @MainActor
    private static func materializeEntries(
        from plans: [ResolvedEntryPlan],
        items: [PrintFileItem]
    ) -> [BrowserEntry] {
        plans.compactMap { plan in
            switch plan {
            case .single(let idx, _):
                guard idx < items.count else { return nil }
                return .single(items[idx])
            case .group(let groupPlan):
                let members = groupPlan.memberIndices.compactMap { $0 < items.count ? items[$0] : nil }
                guard !members.isEmpty else { return nil }
                let primary = groupPlan.primaryIndex < items.count ? items[groupPlan.primaryIndex] : members[0]
                return .group(
                    ModelGroup(
                        id: groupPlan.id,
                        title: groupPlan.title,
                        items: members,
                        primaryItem: primary,
                        reason: groupPlan.reason
                    )
                )
            }
        }
    }

    private nonisolated static func computeGroupPlansOffMain(
        snapshots: [GroupingItemSnapshot],
        watchedFolderPaths: [String]
    ) async -> [ResolvedEntryPlan] {
        computeGroupPlans(snapshots: snapshots, watchedFolderPaths: watchedFolderPaths)
    }

    private nonisolated static func computeGroupPlans(
        snapshots: [GroupingItemSnapshot],
        watchedFolderPaths: [String]
    ) -> [ResolvedEntryPlan] {
        guard snapshots.count > 1 else {
            return snapshots.map { .single(index: $0.index, sortRank: $0.index) }
        }

        let excludedRoots = makeExcludedRoots(watchedFolderPaths: watchedFolderPaths)

        // Step 1: Bucket items by their resolved "project folder" (unwrapping Thingiverse/Printables `files/` or `STLs/` wrappers)
        struct FolderBucket {
            let folderPath: String
            let folderName: String
            var items: [GroupingItemSnapshot] = []
            var hadWrapperSubfolder: Bool = false
        }

        var buckets: [String: FolderBucket] = [:]
        for item in snapshots {
            if Task.isCancelled { return [] }
            let (projectFolderURL, unwrapped) = resolveProjectFolder(
                for: item.fileURL,
                excludedRoots: excludedRoots
            )
            let key = normalizeDirPath(projectFolderURL.path)
            var bucket = buckets[key] ?? FolderBucket(
                folderPath: key,
                folderName: projectFolderURL.lastPathComponent
            )
            bucket.items.append(item)
            if unwrapped { bucket.hadWrapperSubfolder = true }
            buckets[key] = bucket
        }

        var formedGroups: [ResolvedGroupPlan] = []
        var groupedIndices = Set<Int>()
        var companionFileCache: [String: Bool] = [:]

        // Step 2: Evaluate each folder bucket conservatively
        for (_, bucket) in buckets {
            if Task.isCancelled { return [] }
            guard bucket.items.count >= 2 else { continue }

            let isGenericOrRoot = excludedRoots.contains(bucket.folderPath)
                || genericContainerNames.contains(bucket.folderName.lowercased())

            if !isGenericOrRoot,
               let cohesiveMembers = cohesiveProjectMembers(
                   bucket.items,
                   folderPath: bucket.folderPath,
                   folderName: bucket.folderName,
                   hadWrapperSubfolder: bucket.hadWrapperSubfolder,
                   companionFileCache: &companionFileCache
               ),
               cohesiveMembers.count >= 2 {
                let sortedMembers = sortPartsInsideGroup(cohesiveMembers)
                let primary = pickPrimaryItem(from: sortedMembers)
                let bestRank = sortedMembers.map(\.index).min() ?? Int.max
                let group = ResolvedGroupPlan(
                    id: "folder:\(bucket.folderPath)",
                    title: cleanDisplayTitle(bucket.folderName),
                    memberIndices: sortedMembers.map(\.index),
                    primaryIndex: primary.index,
                    reason: .projectFolder,
                    sortRank: bestRank
                )
                formedGroups.append(group)
                for member in sortedMembers { groupedIndices.insert(member.index) }
            } else {
                // Generic root or mixed subfolder: only group items that share an unmistakable multi-part filename stem
                let stemGroups = groupBySharedMultiPartStem(bucket.items, containerPath: bucket.folderPath)
                for g in stemGroups {
                    formedGroups.append(g)
                    for idx in g.memberIndices { groupedIndices.insert(idx) }
                }
            }
        }

        // Step 3: Merge groups and remaining standalone items back in the caller's sort order
        var orderedEntries: [ResolvedEntryPlan] = []
        orderedEntries.reserveCapacity(formedGroups.count + (snapshots.count - groupedIndices.count))

        for group in formedGroups {
            orderedEntries.append(.group(group))
        }
        for item in snapshots where !groupedIndices.contains(item.index) {
            orderedEntries.append(.single(index: item.index, sortRank: item.index))
        }

        orderedEntries.sort { $0.sortRank < $1.sortRank }
        return orderedEntries
    }

    /// Print-variant subfolder names that should be unwrapped when extracting semantic project context for AI classification.
    private static let printVariantFolderNames: Set<String> = [
        "fdm", "fdm_monochrome", "fdm_multi_color", "fdm monochrome", "fdm multi color",
        "resin", "sla", "multicolor", "multi-color", "multi color", "multi_color",
        "monochrome", "single color", "single_color", "single-color"
    ]

    /// System/internal ancestor directory names that carry no semantic meaning for 3D model classification.
    private static let systemNoiseFolderNames: Set<String> = [
        "users", "library", "application support", "plugins", "presets", "system", "ota",
        "caches", "var", "private", "tmp", "volumes"
    ]

    /// Resolves a clean, semantic enclosing project folder (and optional meaningful ancestor folder) for AI classification.
    /// Unwraps archive wrappers (`files/`, `STLs/`, `FDM_Multi_Color/`) and omits generic/root folders (`Downloads`, `STL files`).
    public nonisolated static func meaningfulProjectContext(
        for fileURL: URL,
        watchedFolderPaths: [String] = []
    ) -> (projectFolder: String?, ancestorFolder: String?) {
        let excludedRoots = makeExcludedRoots(watchedFolderPaths: watchedFolderPaths)

        var dir = fileURL.deletingLastPathComponent()

        // Step up past archive wrappers and print-variant subfolders (up to 3 levels)
        for _ in 0..<3 {
            let dirNorm = normalizeDirPath(dir.path)
            if excludedRoots.contains(dirNorm) || dirNorm == "/" { break }
            let nameLower = dir.lastPathComponent.lowercased()
            let isWrapper = wrapperFolderNames.contains(nameLower) || printVariantFolderNames.contains(nameLower)
            guard isWrapper else { break }

            let parent = dir.deletingLastPathComponent()
            let parentNorm = normalizeDirPath(parent.path)
            let parentLower = parent.lastPathComponent.lowercased()
            if excludedRoots.contains(parentNorm)
                || genericContainerNames.contains(parentLower)
                || systemNoiseFolderNames.contains(parentLower)
                || parentNorm == "/" {
                break
            }
            dir = parent
        }

        let resolvedNorm = normalizeDirPath(dir.path)
        let resolvedName = dir.lastPathComponent
        let resolvedLower = resolvedName.lowercased()

        // If the resolved folder itself is a root, generic dump, wrapper, or system noise dir, return nil
        if excludedRoots.contains(resolvedNorm)
            || genericContainerNames.contains(resolvedLower)
            || wrapperFolderNames.contains(resolvedLower)
            || printVariantFolderNames.contains(resolvedLower)
            || systemNoiseFolderNames.contains(resolvedLower)
            || resolvedNorm == "/" {
            return (nil, nil)
        }

        let projectTitle = cleanDisplayTitle(resolvedName)

        // Optionally inspect the immediate parent for a meaningful collection/theme folder (e.g. `4-Environment` or `Terrain`)
        let parent = dir.deletingLastPathComponent()
        let parentNorm = normalizeDirPath(parent.path)
        let parentName = parent.lastPathComponent
        let parentLower = parentName.lowercased()

        var ancestorTitle: String? = nil
        if parentNorm != resolvedNorm
            && parentNorm != "/"
            && !excludedRoots.contains(parentNorm)
            && !genericContainerNames.contains(parentLower)
            && !wrapperFolderNames.contains(parentLower)
            && !printVariantFolderNames.contains(parentLower)
            && !systemNoiseFolderNames.contains(parentLower)
            && parentLower != resolvedLower {
            let cleaned = cleanDisplayTitle(parentName)
            if cleaned.lowercased() != projectTitle.lowercased() && cleaned.count >= 3 {
                ancestorTitle = cleaned
            }
        }

        return (projectTitle, ancestorTitle)
    }

    // MARK: - Project Folder Resolution

    private static func resolveProjectFolder(
        for fileURL: URL,
        excludedRoots: Set<String>
    ) -> (folderURL: URL, unwrappedWrapper: Bool) {
        var dir = fileURL.deletingLastPathComponent()
        var unwrapped = false

        // Step up at most 2 wrapper levels (e.g., MyModel/STLs/presupported/part1.stl -> MyModel)
        for _ in 0..<2 {
            let dirNorm = normalizeDirPath(dir.path)
            if excludedRoots.contains(dirNorm) { break }
            let nameLower = dir.lastPathComponent.lowercased()
            if wrapperFolderNames.contains(nameLower) {
                let parent = dir.deletingLastPathComponent()
                let parentNorm = normalizeDirPath(parent.path)
                // Don't step up into a watched root or generic dump folder (e.g. ~/Downloads/STLs shouldn't collapse to ~/Downloads)
                if excludedRoots.contains(parentNorm) || genericContainerNames.contains(parent.lastPathComponent.lowercased()) {
                    break
                }
                dir = parent
                unwrapped = true
            } else {
                break
            }
        }
        return (dir, unwrapped)
    }

    // MARK: - Subfolder Cohesion Check (Anti-False-Positive Guard)

    private nonisolated static func cohesiveProjectMembers(
        _ items: [GroupingItemSnapshot],
        folderPath: String,
        folderName: String,
        hadWrapperSubfolder: Bool,
        companionFileCache: inout [String: Bool]
    ) -> [GroupingItemSnapshot]? {
        let distinctCategoryIDs = Set(items.compactMap { $0.categoryID })
        let hasConflictingCategories = distinctCategoryIDs.count > 1

        let folderTokens = meaningfulTokens(from: folderName)
        let perFileTokens = items.map { meaningfulTokens(from: $0.displayTitle) }

        // Strong Signal 1: Known 3D Print Archive Package Signature
        // (e.g. `<Model>/files/*.stl`, Thingiverse/Printables numeric ID suffix, or Printables `-model_files` folder).
        // Individual parts of a single archive (e.g. handle vs blade, clips vs terrain) often receive different AI categories,
        // so explicit archive packages are trusted up to 60 parts without a category veto.
        let isExplicitModelArchive = hadWrapperSubfolder
            || hasModelRepositoryIDSuffix(folderName)
            || hasModelFilesSuffix(folderName)

        if isExplicitModelArchive && items.count <= 60 {
            return items
        }

        // Compute dominant non-assembly inter-file token
        var tokenDocFreq: [String: Int] = [:]
        for tokens in perFileTokens {
            for t in tokens where !assemblyPartTokens.contains(t) {
                tokenDocFreq[t, default: 0] += 1
            }
        }
        let dominantEntry = tokenDocFreq.max { $0.value < $1.value }
        let hasDominantSharedToken = (dominantEntry?.value ?? 0) >= 2
            && Double(dominantEntry?.value ?? 0) / Double(items.count) >= 0.60

        // Strong Signal 2: Folder-to-Filename Token Affinity (>= 50% of files share a distinctive token with the folder name)
        // Strong Signal 3: Inter-File Shared Token Affinity (a single distinctive non-assembly token appears in >= 60% of files)
        let folderMatchFlags = perFileTokens.map { !folderTokens.isEmpty && !$0.isDisjoint(with: folderTokens) }
        let matchingFolderCount = folderMatchFlags.filter { $0 }.count
        let hasFolderAffinity = !folderTokens.isEmpty
            && Double(matchingFolderCount) / Double(items.count) >= 0.50

        if hasFolderAffinity || hasDominantSharedToken {
            let dominantToken = hasDominantSharedToken ? dominantEntry?.key : nil
            var coreIndices = Set<Int>()
            for idx in items.indices {
                let matchesFolder = folderMatchFlags[idx]
                let matchesDominant = dominantToken.map { perFileTokens[idx].contains($0) } ?? false
                if matchesFolder || matchesDominant {
                    coreIndices.insert(idx)
                }
            }
            let coreCategoryIDs = Set(coreIndices.compactMap { items[$0].categoryID })

            // Exclude obvious stray unrelated files dropped into a non-archive project folder
            // (zero token overlap + no assembly vocabulary + different category from the matching model files).
            let kept = items.enumerated().compactMap { idx, item -> GroupingItemSnapshot? in
                if coreIndices.contains(idx) { return item }
                if hasAssemblyVocabulary(item.displayTitle) { return item }
                if let catID = item.categoryID, !coreCategoryIDs.isEmpty, !coreCategoryIDs.contains(catID) {
                    return nil
                }
                return item
            }
            return kept.count >= 2 ? kept : nil
        }

        // Weak Signal 4 (Category-Vetoed): Multi-Part Assembly Vocabulary or Companion README/LICENSE
        // Without a strong folder/filename/archive match, conflicting categories veto grouping so grab-bag subfolders
        // with unrelated parts stay ungrouped.
        if hasConflictingCategories {
            return nil
        }

        if items.count <= 30 {
            let assemblyCount = items.filter { hasAssemblyVocabulary($0.displayTitle) }.count
            if Double(assemblyCount) / Double(items.count) >= 0.60 {
                return items
            }
        }

        if items.count <= 12 {
            let hasCompanions: Bool
            if let cached = companionFileCache[folderPath] {
                hasCompanions = cached
            } else {
                let checked = hasArchiveCompanionFiles(at: folderPath)
                companionFileCache[folderPath] = checked
                hasCompanions = checked
            }
            if hasCompanions {
                return items
            }
        }

        return nil
    }

    // MARK: - Strict Shared Multi-Part Stem Grouping (for Generic / Mixed Folders)

    private nonisolated static func groupBySharedMultiPartStem(
        _ items: [GroupingItemSnapshot],
        containerPath: String
    ) -> [ResolvedGroupPlan] {
        // Group strictly by (immediateParentDir, extractedMultiPartStem)
        struct StemKey: Hashable {
            let dir: String
            let stem: String
        }

        var stemBuckets: [StemKey: [(item: GroupingItemSnapshot, displayStem: String, hadExplicitSuffix: Bool)]] = [:]
        var unmatchedItems: [(dir: String, normalizedTitle: String, item: GroupingItemSnapshot)] = []

        for item in items {
            let dir = normalizeDirPath(item.fileURL.deletingLastPathComponent().path)
            if let (normalizedStem, displayStem) = extractExplicitMultiPartStem(from: item.displayTitle) {
                stemBuckets[StemKey(dir: dir, stem: normalizedStem), default: []].append((item, displayStem, true))
            } else {
                let normalizedTitle = normalizedWordSequence(from: stripSecondaryMeshExtension(item.displayTitle))
                unmatchedItems.append((dir, normalizedTitle, item))
            }
        }

        // Allow an exact base-name sibling (e.g. `Planter.stl` alongside `Planter_tray.stl`,
        // `AK_lichking.3mf` alongside `AK_lichking-center.3mf`, or `tower.stl` alongside `tower_top.stl`)
        // to join its matching explicit-suffix stem bucket in the same directory.
        // Also group identical base names in different formats (e.g. `Model.stl` + `Model.3mf`).
        var exactNameBuckets: [StemKey: [GroupingItemSnapshot]] = [:]
        for candidate in unmatchedItems where candidate.normalizedTitle.count >= 4 {
            let key = StemKey(dir: candidate.dir, stem: candidate.normalizedTitle)
            if stemBuckets[key] != nil {
                stemBuckets[key]?.append((candidate.item, candidate.item.displayTitle, false))
            } else {
                exactNameBuckets[key, default: []].append(candidate.item)
            }
        }

        for (key, sameNameItems) in exactNameBuckets where sameNameItems.count >= 2 {
            // Only group identical base titles (e.g. `.stl` + `.3mf` export of the same model)
            let display = sameNameItems.first?.displayTitle ?? key.stem
            stemBuckets[key] = sameNameItems.map { ($0, display, true) }
        }

        var groups: [ResolvedGroupPlan] = []
        for (key, entries) in stemBuckets where entries.count >= 2 && entries.contains(where: \.hadExplicitSuffix) {
            let bucketItems = entries.map(\.item)
            let sortedMembers = sortPartsInsideGroup(bucketItems)
            let primary = pickPrimaryItem(from: sortedMembers)
            let bestRank = sortedMembers.map(\.index).min() ?? Int.max
            let title = cleanDisplayTitle(entries.first(where: \.hadExplicitSuffix)?.displayStem ?? key.stem)
            groups.append(
                ResolvedGroupPlan(
                    id: "stem:\(containerPath)|\(key.dir)|\(key.stem)",
                    title: title,
                    memberIndices: sortedMembers.map(\.index),
                    primaryIndex: primary.index,
                    reason: .sharedStem,
                    sortRank: bestRank
                )
            )
        }
        return groups
    }

    private static func stripSecondaryMeshExtension(_ title: String) -> String {
        let lower = title.lowercased()
        if lower.hasSuffix(".3mf") || lower.hasSuffix(".stl") {
            return String(title.dropLast(4))
        }
        return title
    }

    private static func normalizedWordSequence(from title: String) -> String {
        title
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "+", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
            .joined(separator: " ")
    }

    /// Extracts a shared multi-part stem ONLY when the filename has an explicit part/plate/side/version suffix
    /// (e.g. `Hogwarts_-_part_1` -> `hogwarts`, `Hogwarts_-_assembly` -> `hogwarts`, `AK_lichking-center-1.3mf` -> `ak lichking`).
    public nonisolated static func extractExplicitMultiPartStem(from displayTitle: String) -> (normalized: String, display: String)? {
        let cleanedTitle = stripSecondaryMeshExtension(displayTitle)
        // Tokenize preserving word boundaries around `_`, `-`, `+`, parentheses, spaces
        let rawTokens = cleanedTitle
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        guard !rawTokens.isEmpty else { return nil }

        // Handle single-token trailing digits like `tower1` -> (`tower`, `tower`)
        if rawTokens.count == 1 {
            let single = rawTokens[0]
            let trimmedDigits = single.reversed().drop(while: \.isNumber).reversed()
            let base = String(trimmedDigits)
            if base.count >= 4 && base.count < single.count && !stopWords.contains(base.lowercased()) {
                return (base.lowercased(), base)
            }
            return nil
        }

        var end = rawTokens.count
        var strippedExplicitSuffix = false

        // Strip trailing multi-part tokens (e.g. `part`, `1`, `v2`, `assembly`, `left`, `center`, `plate`, `01`)
        while end > 1 {
            let token = rawTokens[end - 1].lowercased()
            let isPureDigits = token.allSatisfy(\.isNumber) && token.count <= 3
            let isPartNumber = (token.hasPrefix("part") && token.dropFirst(4).allSatisfy(\.isNumber))
                || (token.hasPrefix("pt") && token.count >= 3 && token.dropFirst(2).allSatisfy(\.isNumber))
            let isPlateNumber = token.hasPrefix("plate") && token.dropFirst(5).allSatisfy(\.isNumber)
            let isVersion = (token.hasPrefix("v") || token.hasPrefix("p"))
                && token.count >= 2 && token.count <= 4
                && token.dropFirst().allSatisfy(\.isNumber)
            let isSingleLetterPart = token.count == 1 && token.first!.isLetter && end == rawTokens.count
            let isSuffixWord = stemSuffixTokens.contains(token)

            if isSuffixWord || isPartNumber || isPlateNumber || isVersion || isPureDigits || isSingleLetterPart {
                end -= 1
                strippedExplicitSuffix = true
            } else {
                break
            }
        }

        guard strippedExplicitSuffix, end >= 1 else { return nil }

        let stemWords = Array(rawTokens[0..<end])
        let normalized = stemWords.map { $0.lowercased() }.joined(separator: " ")
        let meaningful = stemWords
            .map { $0.lowercased() }
            .filter { $0.count >= 3 && !stopWords.contains($0) && !$0.allSatisfy(\.isNumber) }

        // Require a distinctive stem (at least 4 chars total and at least one meaningful non-stopword)
        guard normalized.count >= 4, !meaningful.isEmpty else { return nil }
        return (normalized, stemWords.joined(separator: " "))
    }

    // MARK: - Helpers

    private static func meaningfulTokens(from text: String) -> Set<String> {
        let raw = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                token.count >= 3
                    && !token.allSatisfy(\.isNumber)
                    && !stopWords.contains(token)
            }
        return Set(raw)
    }

    private static func hasAssemblyVocabulary(_ title: String) -> Bool {
        let tokens = title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for t in tokens {
            if assemblyPartTokens.contains(t) { return true }
            if t.hasPrefix("part") && t.dropFirst(4).allSatisfy(\.isNumber) && t.count > 4 { return true }
            if t.hasPrefix("plate") && t.dropFirst(5).allSatisfy(\.isNumber) && t.count > 5 { return true }
        }
        return false
    }

    /// Matches common Thingiverse / Printables / MakerWorld folder ID patterns like `Hogwarts-482910`, `Model_123456`, or `Feet_5407836(1)`.
    private static func hasModelRepositoryIDSuffix(_ folderName: String) -> Bool {
        let strippedCopy = folderName.replacingOccurrences(
            of: #"\s*\(\d+\)\s*$"#,
            with: "",
            options: .regularExpression
        )
        let parts = strippedCopy.components(separatedBy: CharacterSet(charactersIn: "-_ "))
            .filter { !$0.isEmpty }
        guard parts.count >= 2, let last = parts.last else { return false }
        return last.count >= 5 && last.allSatisfy(\.isNumber)
    }

    /// Matches Printables archive extraction folder names like `barrel-chest-with-re-keyable-lock-model_files`.
    private static func hasModelFilesSuffix(_ folderName: String) -> Bool {
        let lower = folderName.lowercased()
        return lower.hasSuffix("-model_files") || lower.hasSuffix("_model_files") || lower.hasSuffix(" model_files")
    }

    private static func hasArchiveCompanionFiles(at folderPath: String) -> Bool {
        let fm = FileManager.default
        let markers = ["README.txt", "README.md", "LICENSE.txt", "images", "files", "STLs", "stls"]
        return markers.contains { fm.fileExists(atPath: (folderPath as NSString).appendingPathComponent($0)) }
    }

    private nonisolated static func sortPartsInsideGroup(_ items: [GroupingItemSnapshot]) -> [GroupingItemSnapshot] {
        items.sorted { a, b in
            let aScore = heroPriorityScore(a.displayTitle)
            let bScore = heroPriorityScore(b.displayTitle)
            if aScore != bScore { return aScore > bScore }
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        }
    }

    private nonisolated static func pickPrimaryItem(from items: [GroupingItemSnapshot]) -> GroupingItemSnapshot {
        items.max { a, b in
            let sa = heroPriorityScore(a.displayTitle)
            let sb = heroPriorityScore(b.displayTitle)
            if sa != sb { return sa < sb }
            if a.fileSize != b.fileSize { return a.fileSize < b.fileSize }
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedDescending
        } ?? items[0]
    }

    private static func heroPriorityScore(_ title: String) -> Int {
        let lower = title.lowercased()
        if lower.contains("assembly") || lower.contains("complete") || lower.contains("combined") || lower.contains("full") {
            return 100
        }
        if lower.contains("plate_1") || lower.contains("plate 1") || lower.contains("plate1") {
            return 80
        }
        if lower.contains("main") || lower.contains("body") {
            return 60
        }
        if lower.contains("part_1") || lower.contains("part 1") || lower.contains("part1") {
            return 40
        }
        return 0
    }

    public nonisolated static func cleanDisplayTitle(_ raw: String) -> String {
        var cleaned = raw.replacingOccurrences(
            of: #"\s*\(\d+\)\s*$"#,
            with: "",
            options: .regularExpression
        )
        // Strip Printables `-model_files` / `_model_files` suffix
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)[-_\s]model_files$"#,
            with: "",
            options: .regularExpression
        )
        // Strip trailing `_Unsupported` / `_Supported` / `_Presupported`
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)[-_\s](?:pre-?supported|unsupported|supported)$"#,
            with: "",
            options: .regularExpression
        )
        // Strip trailing Thingiverse/Printables numeric ID suffix (e.g. `Hogwarts_Castle_5852367` or `Guldan - 4122379`)
        cleaned = cleaned.replacingOccurrences(
            of: #"[-_\s]+\d{5,}$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: " - ", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        let words = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return raw }
        let joined = words.joined(separator: " ")
        if joined == joined.lowercased() {
            return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        return joined
    }

    private static func normalizeDirPath(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }
}
