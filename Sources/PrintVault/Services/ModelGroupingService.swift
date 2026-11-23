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

        let normalizedWatchedRoots = Set(watchedFolderPaths.map { normalizeDirPath($0) })
        let homeSubRoots: Set<String> = {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return Set([
                normalizeDirPath(home),
                normalizeDirPath("\(home)/Downloads"),
                normalizeDirPath("\(home)/Documents"),
                normalizeDirPath("\(home)/Desktop")
            ])
        }()
        let excludedRoots = normalizedWatchedRoots.union(homeSubRoots)

        // Preserve original sort index so groups stay ordered naturally according to current BrowserSortOrder
        let orderIndex = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.filePath, $0) })

        // Step 1: Bucket items by their resolved "project folder" (unwrapping Thingiverse/Printables `files/` or `STLs/` wrappers)
        struct FolderBucket {
            let folderPath: String
            let folderName: String
            var items: [PrintFileItem] = []
            var hadWrapperSubfolder: Bool = false
        }

        var buckets: [String: FolderBucket] = [:]
        for item in items {
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

        var formedGroups: [ModelGroup] = []
        var groupedPaths = Set<String>()

        // Step 2: Evaluate each folder bucket conservatively
        for (_, bucket) in buckets {
            guard bucket.items.count >= 2 else { continue }

            let isGenericOrRoot = excludedRoots.contains(bucket.folderPath)
                || genericContainerNames.contains(bucket.folderName.lowercased())

            if !isGenericOrRoot,
               let cohesiveMembers = cohesiveProjectMembers(
                   bucket.items,
                   folderPath: bucket.folderPath,
                   folderName: bucket.folderName,
                   hadWrapperSubfolder: bucket.hadWrapperSubfolder
               ),
               cohesiveMembers.count >= 2 {
                let sortedMembers = sortPartsInsideGroup(cohesiveMembers)
                let group = ModelGroup(
                    id: "folder:\(bucket.folderPath)",
                    title: cleanDisplayTitle(bucket.folderName),
                    items: sortedMembers,
                    primaryItem: pickPrimaryItem(from: sortedMembers),
                    reason: .projectFolder
                )
                formedGroups.append(group)
                for member in sortedMembers { groupedPaths.insert(member.filePath) }
            } else {
                // Generic root or mixed subfolder: only group items that share an unmistakable multi-part filename stem
                let stemGroups = groupBySharedMultiPartStem(bucket.items, containerPath: bucket.folderPath)
                for g in stemGroups {
                    formedGroups.append(g)
                    for member in g.items { groupedPaths.insert(member.filePath) }
                }
            }
        }

        // Step 3: Merge groups and remaining standalone items back in the caller's sort order
        var orderedEntries: [(rank: Int, entry: BrowserEntry)] = []
        orderedEntries.reserveCapacity(formedGroups.count + (items.count - groupedPaths.count))

        for group in formedGroups {
            let bestRank = group.items.compactMap { orderIndex[$0.filePath] }.min() ?? Int.max
            orderedEntries.append((bestRank, .group(group)))
        }
        for item in items where !groupedPaths.contains(item.filePath) {
            let rank = orderIndex[item.filePath] ?? Int.max
            orderedEntries.append((rank, .single(item)))
        }

        orderedEntries.sort { $0.rank < $1.rank }
        return orderedEntries.map(\.entry)
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

    @MainActor
    private static func cohesiveProjectMembers(
        _ items: [PrintFileItem],
        folderPath: String,
        folderName: String,
        hadWrapperSubfolder: Bool
    ) -> [PrintFileItem]? {
        let distinctCategoryIDs = Set(items.compactMap { $0.category?.id })
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
            let coreCategoryIDs = Set(coreIndices.compactMap { items[$0].category?.id })

            // Exclude obvious stray unrelated files dropped into a non-archive project folder
            // (zero token overlap + no assembly vocabulary + different category from the matching model files).
            let kept = items.enumerated().compactMap { idx, item -> PrintFileItem? in
                if coreIndices.contains(idx) { return item }
                if hasAssemblyVocabulary(item.displayTitle) { return item }
                if let catID = item.category?.id, !coreCategoryIDs.isEmpty, !coreCategoryIDs.contains(catID) {
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

        if items.count <= 12 && hasArchiveCompanionFiles(at: folderPath) {
            return items
        }

        return nil
    }

    // MARK: - Strict Shared Multi-Part Stem Grouping (for Generic / Mixed Folders)

    @MainActor
    private static func groupBySharedMultiPartStem(
        _ items: [PrintFileItem],
        containerPath: String
    ) -> [ModelGroup] {
        // Group strictly by (immediateParentDir, extractedMultiPartStem)
        struct StemKey: Hashable {
            let dir: String
            let stem: String
        }

        var stemBuckets: [StemKey: [(item: PrintFileItem, displayStem: String, hadExplicitSuffix: Bool)]] = [:]
        var unmatchedItems: [(dir: String, normalizedTitle: String, item: PrintFileItem)] = []

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
        var exactNameBuckets: [StemKey: [PrintFileItem]] = [:]
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

        var groups: [ModelGroup] = []
        for (key, entries) in stemBuckets where entries.count >= 2 && entries.contains(where: \.hadExplicitSuffix) {
            let bucketItems = entries.map(\.item)
            let sortedMembers = sortPartsInsideGroup(bucketItems)
            let title = cleanDisplayTitle(entries.first(where: \.hadExplicitSuffix)?.displayStem ?? key.stem)
            groups.append(
                ModelGroup(
                    id: "stem:\(containerPath)|\(key.dir)|\(key.stem)",
                    title: title,
                    items: sortedMembers,
                    primaryItem: pickPrimaryItem(from: sortedMembers),
                    reason: .sharedStem
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

    @MainActor
    private static func sortPartsInsideGroup(_ items: [PrintFileItem]) -> [PrintFileItem] {
        items.sorted { a, b in
            let aScore = heroPriorityScore(a.displayTitle)
            let bScore = heroPriorityScore(b.displayTitle)
            if aScore != bScore { return aScore > bScore }
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        }
    }

    @MainActor
    private static func pickPrimaryItem(from items: [PrintFileItem]) -> PrintFileItem {
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
