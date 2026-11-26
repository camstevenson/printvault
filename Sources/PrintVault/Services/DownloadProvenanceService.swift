import Foundation
import Darwin

// MARK: - DownloadProvenanceService

/// Reads macOS download provenance (`com.apple.metadata:kMDItemWhereFroms`) extended attributes,
/// embedded `.3mf` `<metadata>` headers, and companion project `README`/`LICENSE` files to resolve
/// the exact source model page URL, designer, and license for downloaded 3D print files.
public enum DownloadProvenanceService {
    public static let whereFromsAttributeName = "com.apple.metadata:kMDItemWhereFroms"

    private static let metadataTagRegex = try? NSRegularExpression(
        pattern: #"<metadata\b[^>]*\bname\s*=\s*["']([^"']+)["'][^>]*>(.*?)</metadata>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static let thingiverseReadmeRegex = try? NSRegularExpression(
        pattern: #"\bby\s+([^\r\n:]+?)\s+on\s+Thingiverse\s*:\s*(https?://[^\s\r\n]+)"#,
        options: [.caseInsensitive]
    )

    private static let webURLRegex = try? NSRegularExpression(
        pattern: #"https?://[^\s<>\"'\]\)]+"#,
        options: [.caseInsensitive]
    )

    private static let camelCaseRegex = try? NSRegularExpression(
        pattern: #"([a-z0-9])([A-Z])"#,
        options: []
    )

    private static let versionOrPartTokenRegex = try? NSRegularExpression(
        pattern: #"^(?:v|ver|rev|r|part|pt|plate|p)\d+[a-z]?$"#,
        options: [.caseInsensitive]
    )

    private static let millimeterTokenRegex = try? NSRegularExpression(
        pattern: #"^\d+(?:\.\d+)?mm$"#,
        options: [.caseInsensitive]
    )

    private static let trailingNumericRegex = try? NSRegularExpression(
        pattern: #"[_-]{1,2}(\d{5,9})$"#,
        options: [.caseInsensitive]
    )

    private static let leadingNumericRegex = try? NSRegularExpression(
        pattern: #"^(\d{5,9})[-_]"#,
        options: [.caseInsensitive]
    )

    private static let trailingPrintablesNumericRegex = try? NSRegularExpression(
        pattern: #"[-_](\d{5,9})(?:[-_]model[-_]files)?$"#,
        options: [.caseInsensitive]
    )

    private static let stopAncestorDirectoryNames: Set<String> = [
        "Downloads",
        "Documents",
        "Desktop",
        "Movies",
        "Music",
        "Pictures",
        "Library",
        "Applications",
        "Public",
        "tmp"
    ]

    private static let searchEngineHosts: Set<String> = [
        "google.com",
        "bing.com",
        "duckduckgo.com",
        "search.yahoo.com",
        "search.brave.com",
        "ecosia.org",
        "yandex.com",
        "kagi.com"
    ]

    private static let directDownloadExtensions: Set<String> = [
        "stl", "3mf", "zip", "rar", "7z", "tar", "gz", "obj", "step", "stp", "gcode", "bgcode"
    ]

    private static let knownCDNHostPrefixes: [String] = [
        "cdn.",
        "files.",
        "media.",
        "dl.",
        "download.",
        "downloads.",
        "assets.",
        "static.",
        "storage.",
        "objects."
    ]

    private static let knownCDNHostSuffixes: [String] = [
        "bblmw.com",
        "cloudfront.net",
        "amazonaws.com",
        "googleusercontent.com",
        "githubusercontent.com",
        "r2.cloudflarestorage.com",
        "digitaloceanspaces.com",
        "blob.core.windows.net",
        "storage.googleapis.com"
    ]

    private static let ignoredCreatorToolNames: Set<String> = [
        "bambustudio",
        "bambu studio",
        "prusaslicer",
        "orcaslicer",
        "superslicer",
        "ultimaker cura",
        "cura",
        "lycheeslicer",
        "chitubox",
        "blender",
        "fusion 360",
        "autodesk fusion",
        "solidworks",
        "freecad",
        "openscad",
        "tinkercad",
        "rhino",
        "onshape",
        "3d builder",
        "meshlab",
        "meshmixer"
    ]

    // MARK: - Reading Extended Attributes

    /// Reads raw extended attribute bytes from disk using POSIX `getxattr`.
    public static func readExtendedAttributeData(named name: String, at url: URL) -> Data? {
        let path = url.path
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }

        var buffer = Data(count: length)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return getxattr(path, name, baseAddress, length, 0, 0)
        }
        guard bytesRead > 0 else { return nil }
        if bytesRead < length {
            buffer.count = bytesRead
        }
        return buffer
    }

    /// Decodes a binary or XML property list payload from `com.apple.metadata:kMDItemWhereFroms`.
    public static func decodeWhereFroms(from data: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            return []
        }

        if let strings = plist as? [String] {
            return strings
        }
        if let single = plist as? String {
            return [single]
        }
        if let items = plist as? [Any] {
            return items.compactMap { $0 as? String }
        }
        return []
    }

    /// Writes `com.apple.metadata:kMDItemWhereFroms` as a binary property list extended attribute.
    @discardableResult
    public static func writeWhereFroms(_ urls: [String], to url: URL) -> Bool {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: urls,
            format: .binary,
            options: 0
        ) else {
            return false
        }

        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            return setxattr(url.path, whereFromsAttributeName, baseAddress, data.count, 0, 0) == 0
        }
    }

    /// Reads `com.apple.metadata:kMDItemWhereFroms` from the file itself, optionally falling back
    /// to up to two enclosing project folders (useful when a downloaded `.zip` archive was unpacked
    /// and macOS attached quarantine/where-froms metadata to the extracted folder).
    public static func readWhereFroms(for url: URL, checkAncestors: Bool = true) -> [String] {
        if let data = readExtendedAttributeData(named: whereFromsAttributeName, at: url) {
            let decoded = decodeWhereFroms(from: data)
            if !decoded.isEmpty {
                return decoded
            }
        }

        guard checkAncestors else { return [] }

        for ancestor in safeProjectAncestors(for: url) {
            if let data = readExtendedAttributeData(named: whereFromsAttributeName, at: ancestor) {
                let decoded = decodeWhereFroms(from: data)
                if !decoded.isEmpty {
                    return decoded
                }
            }
        }

        return []
    }

    /// Reads and merges download provenance for a file on disk from:
    /// 1. `kMDItemWhereFroms` (Spotlight or `com.apple.metadata:kMDItemWhereFroms` xattr)
    /// 2. Embedded `.3mf` `<metadata>` tags (e.g., MakerWorld `DesignModelId`, `ProfileId`, `Designer`, `License`)
    /// 3. Companion `README.txt` / `README.md` / `LICENSE.txt` in unpacked project folders
    /// 4. Site-verified project folder ID recovery (when a browser stripped the referrer to a bare origin)
    public static func readProvenance(
        for url: URL,
        spotlightWhereFroms: [String] = [],
        checkAncestors: Bool = true
    ) -> DownloadProvenance {
        let nonEmptySpotlight = spotlightWhereFroms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let rawWhereFroms = !nonEmptySpotlight.isEmpty
            ? nonEmptySpotlight
            : readWhereFroms(for: url, checkAncestors: checkAncestors)

        let whereFromsProv = extractProvenance(fromWhereFroms: rawWhereFroms)
        let threeMFProv = url.pathExtension.lowercased() == "3mf"
            ? read3MFMetadataProvenance(at: url)
            : DownloadProvenance()
        let companionProv = checkAncestors
            ? readCompanionFolderProvenance(for: url)
            : DownloadProvenance()

        // Choose the most specific model page URL across all local signals.
        // Because modern browsers apply `strict-origin-when-cross-origin`, kMDItemWhereFroms often
        // contains only a bare homepage (`https://makerworld.com/`) when downloading from a CDN.
        var bestURL = pickMostSpecificURL(candidates: [
            whereFromsProv.sourceURL,
            threeMFProv.sourceURL,
            companionProv.sourceURL
        ])

        let needsFolderRecovery: Bool = {
            guard let bestURL, let parsed = validatedWebURL(from: bestURL) else { return true }
            return isBareOriginURL(parsed) || isDirectDownloadOrCDN(parsed, host: normalizedHost(for: parsed))
        }()

        if needsFolderRecovery {
            if let inferredFromFolder = inferModelURLFromFolderAndSite(
                fileURL: url,
                rawWhereFroms: rawWhereFroms,
                fallbackURL: bestURL
            ) {
                bestURL = inferredFromFolder
            }
        }

        let bestDesigner = firstNonEmpty([
            threeMFProv.designer,
            companionProv.designer,
            whereFromsProv.designer
        ])

        let bestLicense = firstNonEmpty([
            threeMFProv.license,
            companionProv.license,
            whereFromsProv.license
        ])

        return DownloadProvenance(
            sourceURL: bestURL,
            designer: bestDesigner,
            license: bestLicense,
            rawWhereFroms: rawWhereFroms
        )
    }

    /// Cooperative off-main-actor wrapper around `readProvenance(for:spotlightWhereFroms:checkAncestors:)`
    /// for UI-triggered refreshes so disk reads and `.3mf` header extraction never block `@MainActor`.
    public nonisolated static func readProvenanceAsync(
        for url: URL,
        spotlightWhereFroms: [String] = [],
        checkAncestors: Bool = true
    ) async -> DownloadProvenance {
        readProvenance(
            for: url,
            spotlightWhereFroms: spotlightWhereFroms,
            checkAncestors: checkAncestors
        )
    }

    // MARK: - Provenance Extraction & URL Resolution

    /// Resolves the best source webpage URL and any inferable designer attribution from a raw
    /// `kMDItemWhereFroms` array (typically `[directDownloadURL, referrerPageURL]`).
    public static func extractProvenance(fromWhereFroms rawEntries: [String]) -> DownloadProvenance {
        let cleanedEntries = rawEntries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let parsedURLs: [(index: Int, url: URL)] = cleanedEntries.enumerated().compactMap { index, entry in
            guard let url = validatedWebURL(from: entry) else { return nil }
            return (index, url)
        }

        guard !parsedURLs.isEmpty else {
            return DownloadProvenance(rawWhereFroms: cleanedEntries)
        }

        let bestURL = selectBestSourcePageURL(from: parsedURLs)
        let designer = inferDesigner(from: [bestURL] + parsedURLs.map(\.url))

        return DownloadProvenance(
            sourceURL: bestURL.absoluteString,
            designer: designer,
            license: nil,
            rawWhereFroms: cleanedEntries
        )
    }

    /// Validates an `http` or `https` URL string with a non-empty host.
    /// Rejects non-web schemes (`file://`, `javascript:`, `data:`, etc.).
    public static func validatedWebURL(from rawString: String?) -> URL? {
        guard let rawString else { return nil }
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        return components.url
    }

    /// Returns `true` when the URL points only to a site's bare origin/homepage
    /// (e.g. `https://makerworld.com/` or `https://www.printables.com`) with no model path, query, or fragment.
    public static func isBareOriginURL(_ url: URL) -> Bool {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let hasQuery = !(url.query?.isEmpty ?? true)
        let hasFragment = !(url.fragment?.isEmpty ?? true)
        return path.isEmpty && !hasQuery && !hasFragment
    }

    public static func isBareOriginURL(_ rawString: String?) -> Bool {
        guard let url = validatedWebURL(from: rawString) else { return false }
        return isBareOriginURL(url)
    }

    /// Returns a human-friendly site name for display in the Inspector (e.g. "Printables", "MakerWorld").
    public static func displaySiteName(for url: URL) -> String {
        guard let host = url.host?.lowercased() else { return "Web" }
        let normalized = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        if normalized == "printables.com" || normalized.hasSuffix(".printables.com") {
            return "Printables"
        }
        if normalized == "makerworld.com" || normalized.hasSuffix(".makerworld.com") || normalized.hasSuffix(".bblmw.com") {
            return "MakerWorld"
        }
        if normalized == "thingiverse.com" || normalized.hasSuffix(".thingiverse.com") {
            return "Thingiverse"
        }
        if normalized == "thangs.com" || normalized.hasSuffix(".thangs.com") {
            return "Thangs"
        }
        if normalized == "cults3d.com" || normalized.hasSuffix(".cults3d.com") {
            return "Cults3D"
        }
        if normalized == "myminifactory.com" || normalized.hasSuffix(".myminifactory.com") {
            return "MyMiniFactory"
        }
        if normalized == "grabcad.com" || normalized.hasSuffix(".grabcad.com") {
            return "GrabCAD"
        }
        if normalized == "github.com" || normalized.hasSuffix(".github.com") || normalized.hasSuffix(".githubusercontent.com") {
            return "GitHub"
        }
        if normalized == "patreon.com" || normalized.hasSuffix(".patreon.com") {
            return "Patreon"
        }
        if normalized == "gumroad.com" || normalized.hasSuffix(".gumroad.com") {
            return "Gumroad"
        }
        if normalized == "etsy.com" || normalized.hasSuffix(".etsy.com") {
            return "Etsy"
        }
        return normalized
    }

    /// Builds a site-specific model search URL when macOS only recorded a bare site origin
    /// (for example, Printables UUID CDN downloads where browsers strip the cross-origin referrer).
    public static func siteSearchURL(for siteURL: URL, query: String) -> URL? {
        let cleanedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuery.isEmpty else { return nil }

        let host = normalizedHost(for: siteURL)

        func buildURL(scheme: String = "https", host: String, path: String, queryItems: [URLQueryItem]) -> URL? {
            var comps = URLComponents()
            comps.scheme = scheme
            comps.host = host
            comps.path = path
            comps.queryItems = queryItems
            return comps.url
        }

        if host == "printables.com" || host.hasSuffix(".printables.com") {
            return buildURL(
                host: "www.printables.com",
                path: "/search/models",
                queryItems: [URLQueryItem(name: "q", value: cleanedQuery)]
            )
        }
        if host == "makerworld.com" || host.hasSuffix(".makerworld.com") || host.hasSuffix(".bblmw.com") {
            return buildURL(
                host: "makerworld.com",
                path: "/en/search/models",
                queryItems: [URLQueryItem(name: "keyword", value: cleanedQuery)]
            )
        }
        if host == "thingiverse.com" || host.hasSuffix(".thingiverse.com") {
            return buildURL(
                host: "www.thingiverse.com",
                path: "/search",
                queryItems: [
                    URLQueryItem(name: "q", value: cleanedQuery),
                    URLQueryItem(name: "type", value: "things")
                ]
            )
        }
        if host == "thangs.com" || host.hasSuffix(".thangs.com") {
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = "thangs.com"
            comps.path = "/search/\(cleanedQuery)"
            comps.queryItems = [URLQueryItem(name: "scope", value: "all")]
            return comps.url
        }
        if host == "cults3d.com" || host.hasSuffix(".cults3d.com") {
            return buildURL(
                host: "cults3d.com",
                path: "/en/search",
                queryItems: [URLQueryItem(name: "q", value: cleanedQuery)]
            )
        }
        if host == "myminifactory.com" || host.hasSuffix(".myminifactory.com") {
            return buildURL(
                host: "www.myminifactory.com",
                path: "/search/",
                queryItems: [URLQueryItem(name: "query", value: cleanedQuery)]
            )
        }
        if host == "grabcad.com" || host.hasSuffix(".grabcad.com") {
            return buildURL(
                host: "grabcad.com",
                path: "/library",
                queryItems: [URLQueryItem(name: "query", value: cleanedQuery)]
            )
        }
        if host == "github.com" || host.hasSuffix(".github.com") {
            return buildURL(
                host: "github.com",
                path: "/search",
                queryItems: [
                    URLQueryItem(name: "q", value: cleanedQuery),
                    URLQueryItem(name: "type", value: "repositories")
                ]
            )
        }
        return nil
    }

    private static let searchNoiseTokens: Set<String> = [
        "main", "part", "pt", "piece", "plate", "assembly", "complete", "full", "combined",
        "left", "right", "top", "bottom", "front", "back", "upper", "lower",
        "inner", "outer", "mid", "middle", "center", "side", "end",
        "body", "base", "lid", "cover", "cap", "shell", "core", "insert",
        "supported", "presupported", "unsupported", "nosupport", "hollow", "solid",
        "split", "cut", "half", "solo", "copy", "alt", "final", "fixed", "repaired",
        "scaled", "remix", "version", "ver", "rev", "new", "old", "test",
        "fdm", "sla", "resin", "pla", "petg", "abs", "asa", "tpu", "mmu", "ams",
        "multicolor", "color", "stl", "3mf", "mesh", "file", "files", "model", "models",
        "print", "prints", "nozzle"
    ]

    /// Derives a clean search query from a model's group title, meaningful project folder, or filename,
    /// stripping part-position prefixes/suffixes, version tags, and slicer tokens that break strict site search.
    public static func suggestedSearchQuery(
        for fileURL: URL,
        groupTitle: String? = nil,
        watchedFolderPaths: [String] = []
    ) -> String {
        if let groupTitle {
            let cleanedGroup = cleanSearchQueryString(groupTitle, stripPartNoise: false)
            if !cleanedGroup.isEmpty {
                return cleanedGroup
            }
        }

        let context = ModelGroupingService.meaningfulProjectContext(
            for: fileURL,
            watchedFolderPaths: watchedFolderPaths
        )
        if let projectFolder = context.projectFolder {
            let cleanedFolder = cleanSearchQueryString(projectFolder, stripPartNoise: false)
            if !cleanedFolder.isEmpty {
                return cleanedFolder
            }
        }

        let rawFileName = fileURL.deletingPathExtension().lastPathComponent
        return cleanSearchQueryString(rawFileName, stripPartNoise: true)
    }

    private static func cleanSearchQueryString(_ raw: String, stripPartNoise: Bool) -> String {
        // Split CamelCase boundaries (e.g. `MainPaintStation` -> `Main Paint Station`)
        let nsRaw = raw as NSString
        let camelSplit = camelCaseRegex?.stringByReplacingMatches(
            in: raw,
            range: NSRange(location: 0, length: nsRaw.length),
            withTemplate: "$1 $2"
        ) ?? raw
        let spaced = camelSplit
            .replacing("_", with: " ")
            .replacing("-", with: " ")
            .replacing(".", with: " ")
            .replacing("+", with: " ")

        let rawTokens = spaced
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !rawTokens.isEmpty else { return "" }

        let filtered = rawTokens.filter { token in
            let lower = token.lowercased()
            let fullRange = NSRange(location: 0, length: (lower as NSString).length)
            // Always drop version tags (`v1`, `v2`, `rev3`), part counters (`part1`, `plate2`), and nozzle sizes (`04mm`)
            if versionOrPartTokenRegex?.firstMatch(in: lower, range: fullRange) != nil {
                return false
            }
            if millimeterTokenRegex?.firstMatch(in: lower, range: fullRange) != nil {
                return false
            }
            if stripPartNoise {
                if searchNoiseTokens.contains(lower) {
                    return false
                }
                // Drop isolated single-letter suffixes/identifiers (e.g. `A`, `B`) and pure numbers
                if lower.count == 1 || lower.allSatisfy(\.isNumber) {
                    return false
                }
            }
            return true
        }

        let chosen = filtered.isEmpty ? rawTokens : filtered
        return chosen.joined(separator: " ")
    }

    /// Common 3D printing model licenses offered for quick selection in the Inspector.
    public static let commonLicenses: [String] = [
        "CC BY 4.0",
        "CC BY-SA 4.0",
        "CC BY-NC 4.0",
        "CC BY-NC-SA 4.0",
        "CC0 (Public Domain)",
        "Standard Digital File License",
        "MIT",
        "GPL-3.0",
        "Personal Use Only"
    ]

    // MARK: - Embedded .3mf <metadata> Extraction

    /// Extracts provenance (`DesignModelId`, `ProfileId`, `Origin`, `SourceUrl`, `Designer`, `License`)
    /// from the XML header of `3D/3dmodel.model` inside a `.3mf` archive without inflating mesh geometry.
    public static func read3MFMetadataProvenance(at url: URL) -> DownloadProvenance {
        guard let headerData = read3MFModelHeader(at: url),
              let headerText = String(data: headerData, encoding: .utf8)
                ?? String(data: headerData, encoding: .isoLatin1) else {
            return DownloadProvenance()
        }
        return extractProvenance(from3MFModelHeader: headerText)
    }

    /// Parses `<metadata name="...">value</metadata>` tags from a `.3mf` `.model` XML header.
    public static func extractProvenance(from3MFModelHeader xmlHeader: String) -> DownloadProvenance {
        let metadata = parse3MFMetadataTags(from: xmlHeader)
        guard !metadata.isEmpty else { return DownloadProvenance() }

        func value(forAny keys: [String]) -> String? {
            for key in keys {
                if let val = metadata[key.lowercased()] {
                    let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }

        // 1. Source URL: explicit MakerWorld DesignModelId/ProfileId, explicit URL fields, or URL inside Description
        var resolvedURL: String?

        if let designModelID = value(forAny: ["designmodelid", "makerworldmodelid", "modelid"]),
           let makerWorldURL = buildMakerWorldModelURL(
               modelID: designModelID,
               profileID: value(forAny: ["profileid", "designprofileid"])
           ) {
            resolvedURL = makerWorldURL
        }

        if resolvedURL == nil {
            if let explicitURL = value(forAny: ["sourceurl", "source", "origin", "url", "modelurl", "weblink"]),
               let valid = validatedWebURL(from: explicitURL),
               !isBareOriginURL(valid) {
                resolvedURL = valid.absoluteString
            }
        }

        if resolvedURL == nil,
           let description = value(forAny: ["description", "model description"]) {
            resolvedURL = extractKnownModelURL(fromText: description)
        }

        // 2. Designer
        let rawDesigner = value(forAny: ["designer", "creator", "created by", "author", "profileusername"])
        let designer: String? = rawDesigner.flatMap { candidate in
            let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty,
                  cleaned.count <= 80,
                  !ignoredCreatorToolNames.contains(cleaned.lowercased()) else {
                return nil
            }
            return cleaned
        }

        // 3. License
        let rawLicense = value(forAny: ["license", "copyright"])
        let license: String? = rawLicense.flatMap { candidate in
            let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.count <= 120 else { return nil }
            return normalizeLicenseText(cleaned) ?? cleaned
        }

        return DownloadProvenance(
            sourceURL: resolvedURL,
            designer: designer,
            license: license
        )
    }

    private static func read3MFModelHeader(at url: URL, maxBytes: Int = 65_536) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-qq", "-C", "-p", url.path, "3D/3dmodel.model"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return nil
        }

        let handle = pipe.fileHandleForReading
        var buffer = Data()
        buffer.reserveCapacity(min(maxBytes, 16_384))
        let resourcesMarker = Data("<resources".utf8)

        while buffer.count < maxBytes {
            let chunkSize = min(8_192, maxBytes - buffer.count)
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)
            if buffer.range(of: resourcesMarker) != nil {
                break
            }
        }

        try? handle.close()
        if proc.isRunning {
            proc.terminate()
        }
        proc.waitUntilExit()
        return buffer.isEmpty ? nil : buffer
    }

    private static func parse3MFMetadataTags(from xml: String) -> [String: String] {
        // Limit scanning to the header before `<resources` when present
        let headerSlice: Substring
        if let resourcesRange = xml.range(of: "<resources", options: .caseInsensitive) {
            headerSlice = xml[..<resourcesRange.lowerBound]
        } else {
            headerSlice = xml[...]
        }
        let headerString = String(headerSlice)
        let nsHeader = headerString as NSString

        guard let regex = metadataTagRegex else {
            return [:]
        }

        var result: [String: String] = [:]
        let matches = regex.matches(in: headerString, range: NSRange(location: 0, length: nsHeader.length))
        for match in matches where match.numberOfRanges >= 3 {
            let name = nsHeader.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rawValue = nsHeader.substring(with: match.range(at: 2))
            let decodedValue = decodeXMLEntities(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !decodedValue.isEmpty, result[name] == nil {
                result[name] = decodedValue
            }
        }
        return result
    }

    private static func buildMakerWorldModelURL(modelID: String, profileID: String?) -> String? {
        let cleanedModelID = normalizeMakerWorldModelID(modelID)
        guard let cleanedModelID, !cleanedModelID.isEmpty else { return nil }

        var urlString = "https://makerworld.com/en/models/\(cleanedModelID)"
        if let profileID {
            let trimmedProfile = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedProfile.isEmpty, trimmedProfile != "0", trimmedProfile.allSatisfy(\.isNumber) {
                urlString += "#profileId-\(trimmedProfile)"
            }
        }
        return urlString
    }

    private static func normalizeMakerWorldModelID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "0" else { return nil }

        // Standard numeric MakerWorld ID (e.g. "456789")
        if trimmed.allSatisfy(\.isNumber) {
            let stripped = trimmed.drop(while: { $0 == "0" })
            return stripped.isEmpty ? nil : String(stripped)
        }

        // MakerWorld DSM-prefixed numeric ID (e.g. "DSM00000001200654" -> "1200654")
        let upper = trimmed.uppercased()
        if upper.hasPrefix("DSM") {
            let remainder = trimmed.dropFirst(3)
            if !remainder.isEmpty, remainder.allSatisfy(\.isNumber) {
                let stripped = remainder.drop(while: { $0 == "0" })
                return stripped.isEmpty ? nil : String(stripped)
            }
        }

        return nil
    }

    // MARK: - Companion README / LICENSE Extraction

    /// Checks safe enclosing project directories (up to 2 levels up, never top-level user folders)
    /// for companion `README.txt` / `README.md` / `LICENSE.txt` files bundled in model archives.
    public static func readCompanionFolderProvenance(for fileURL: URL) -> DownloadProvenance {
        let fm = FileManager.default
        var foundURL: String?
        var foundDesigner: String?
        var foundLicense: String?

        let readmeNames = ["README.txt", "readme.txt", "README.md", "readme.md"]
        let licenseNames = ["LICENSE.txt", "license.txt", "LICENSE.md", "license.md"]

        for dir in safeProjectAncestors(for: fileURL) {
            if foundURL == nil || foundDesigner == nil {
                for name in readmeNames {
                    let candidate = dir.appending(path: name)
                    guard fm.fileExists(atPath: candidate.path),
                          let text = readUTF8Prefix(at: candidate, maxBytes: 16_384) else {
                        continue
                    }
                    let parsed = parseReadmeProvenance(from: text)
                    if foundURL == nil { foundURL = parsed.sourceURL }
                    if foundDesigner == nil { foundDesigner = parsed.designer }
                    if foundLicense == nil { foundLicense = parsed.license }
                    if foundURL != nil && foundDesigner != nil { break }
                }
            }

            if foundLicense == nil {
                for name in licenseNames {
                    let candidate = dir.appending(path: name)
                    guard fm.fileExists(atPath: candidate.path),
                          let text = readUTF8Prefix(at: candidate, maxBytes: 4_096) else {
                        continue
                    }
                    if let normalized = normalizeLicenseText(text) {
                        foundLicense = normalized
                        break
                    }
                }
            }

            if foundURL != nil && foundDesigner != nil && foundLicense != nil {
                break
            }
        }

        return DownloadProvenance(
            sourceURL: foundURL,
            designer: foundDesigner,
            license: foundLicense
        )
    }

    /// Parses source URL, designer, and license from companion archive README text
    /// (e.g., Thingiverse's `<Title> by <Creator> on Thingiverse: https://www.thingiverse.com/thing:12345`).
    public static func parseReadmeProvenance(from text: String) -> DownloadProvenance {
        var sourceURL = extractKnownModelURL(fromText: text)
        var designer: String?
        let license = normalizeLicenseText(text)

        let nsText = text as NSString
        // Thingiverse README format: "<Title> by <Creator> on Thingiverse: https://www.thingiverse.com/thing:<id>"
        if let regex = thingiverseReadmeRegex,
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
           match.numberOfRanges >= 3 {
            let creator = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let urlRaw = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !creator.isEmpty, creator.count <= 80 {
                designer = creator
            }
            if sourceURL == nil, let valid = validatedWebURL(from: urlRaw) {
                sourceURL = valid.absoluteString
            }
        }

        if designer == nil, let sourceURL, let parsedURL = URL(string: sourceURL) {
            designer = inferDesigner(from: [parsedURL])
        }

        return DownloadProvenance(
            sourceURL: sourceURL,
            designer: designer,
            license: license
        )
    }

    private static func readUTF8Prefix(at url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Site + Folder ID Recovery

    /// When a browser's `strict-origin-when-cross-origin` policy stripped `kMDItemWhereFroms`
    /// to a bare site homepage (e.g. `https://www.thingiverse.com/` or `https://www.printables.com/`),
    /// attempts high-precision recovery of the model ID from the unpacked project folder name.
    private static func inferModelURLFromFolderAndSite(
        fileURL: URL,
        rawWhereFroms: [String],
        fallbackURL: String?
    ) -> String? {
        var hosts = Set(rawWhereFroms.compactMap { validatedWebURL(from: $0).map(normalizedHost(for:)) })
        if let fallbackURL, let parsed = validatedWebURL(from: fallbackURL) {
            hosts.insert(normalizedHost(for: parsed))
        }
        guard !hosts.isEmpty else { return nil }

        let ancestors = safeProjectAncestors(for: fileURL)
        let folderNames = ancestors.map(\.lastPathComponent)

        // Thingiverse zip folders always end in `_<thingID>` or `__<thingID>` (e.g. `Shaving_Supplies_Stand__2741048`)
        if hosts.contains(where: { $0 == "thingiverse.com" || $0.hasSuffix(".thingiverse.com") }) {
            for folderName in folderNames {
                if let digits = capturedNumericID(in: folderName, using: trailingNumericRegex) {
                    return "https://www.thingiverse.com/thing:\(digits)"
                }
            }
        }

        // Printables folders/files sometimes carry `<modelID>-<slug>` or `<slug>-<modelID>-model_files`
        if hosts.contains(where: { $0 == "printables.com" || $0.hasSuffix(".printables.com") }) {
            for name in folderNames + [fileURL.deletingPathExtension().lastPathComponent] {
                if let digits = capturedNumericID(in: name, using: leadingNumericRegex) {
                    return "https://www.printables.com/model/\(digits)"
                }
                if let digits = capturedNumericID(in: name, using: trailingPrintablesNumericRegex) {
                    return "https://www.printables.com/model/\(digits)"
                }
            }
        }

        return nil
    }

    private static func capturedNumericID(in text: String, using regex: NSRegularExpression?) -> String? {
        guard let regex else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges >= 2 else {
            return nil
        }
        let digits = nsText.substring(with: match.range(at: 1))
        return digits.allSatisfy(\.isNumber) ? digits : nil
    }

    // MARK: - Private Heuristics

    private static func safeProjectAncestors(for url: URL) -> [URL] {
        let homePath = URL.homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let tempPath = URL.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        var current = url.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()
        var ancestors: [URL] = []

        for _ in 0..<2 {
            let currentPath = current.path
            if currentPath.isEmpty
                || currentPath == "/"
                || currentPath == homePath
                || currentPath == tempPath
                || currentPath == "/tmp"
                || currentPath == "/private/tmp"
                || stopAncestorDirectoryNames.contains(current.lastPathComponent) {
                break
            }

            ancestors.append(current)

            let parent = current.deletingLastPathComponent()
            if parent.path == currentPath { break }
            current = parent
        }

        return ancestors
    }

    private static func pickMostSpecificURL(candidates: [String?]) -> String? {
        var bestSpecific: (url: URL, score: Int)?
        var firstBareOrigin: URL?

        for raw in candidates {
            guard let url = validatedWebURL(from: raw) else { continue }
            if isBareOriginURL(url) {
                if firstBareOrigin == nil {
                    firstBareOrigin = url
                }
                continue
            }

            let score = scoreSourceCandidate(url, isReferrer: false)
            if bestSpecific.map({ score > $0.score }) ?? true {
                bestSpecific = (url, score)
            }
        }

        return (bestSpecific?.url ?? firstBareOrigin)?.absoluteString
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func selectBestSourcePageURL(from entries: [(index: Int, url: URL)]) -> URL {
        // Build scored candidates from both raw entries and canonicalized model-page equivalents
        var bestCandidate = entries[0].url
        var bestScore = Int.min

        for (index, url) in entries {
            let rawScore = scoreSourceCandidate(url, isReferrer: index > 0)
            if rawScore > bestScore {
                bestScore = rawScore
                bestCandidate = url
            }

            if let canonical = canonicalizeKnownDownloadURL(url) {
                // Canonicalized page derived from a CDN/zip download beats raw CDN links and bare homepages,
                // while still allowing an explicit richer referrer page (e.g. with slug) to win.
                let canonicalScore = scoreSourceCandidate(canonical, isReferrer: false) - 5
                if canonicalScore > bestScore {
                    bestScore = canonicalScore
                    bestCandidate = canonical
                }
            }
        }

        return bestCandidate
    }

    private static func scoreSourceCandidate(_ url: URL, isReferrer: Bool) -> Int {
        let host = normalizedHost(for: url)
        let lowerPath = url.path.lowercased()

        if searchEngineHosts.contains(host) {
            return -200
        }

        // Bare site homepages (e.g. `https://makerworld.com/` from strict-origin-when-cross-origin)
        // must always lose to any specific model page or canonicalized download URL,
        // while still beating raw expiring CDN/asset links that can't be canonicalized.
        if isBareOriginURL(url) {
            return isKnown3DHost(host) ? 10 : 0
        }

        var score = 0

        if isKnownModelPage(host: host, lowerPath: lowerPath) {
            score += 120
        } else if isKnown3DHost(host) && !isDirectDownloadOrCDN(url, host: host) {
            score += 60
        }

        if isDirectDownloadOrCDN(url, host: host) {
            score -= 80
        }

        // Referrer pages (index >= 1 in kMDItemWhereFroms) with a non-empty path are typically the
        // browser page rather than the direct file download URL at index 0.
        if isReferrer && !isDirectDownloadOrCDN(url, host: host) {
            score += 35
        }

        if url.path.count > 1 {
            score += 15
        }

        return score
    }

    private static func normalizedHost(for url: URL) -> String {
        let raw = url.host?.lowercased() ?? ""
        return raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
    }

    private static func isKnown3DHost(_ host: String) -> Bool {
        let domains = [
            "printables.com",
            "makerworld.com",
            "thingiverse.com",
            "thangs.com",
            "cults3d.com",
            "myminifactory.com",
            "grabcad.com",
            "github.com",
            "yeggi.com",
            "crealitycloud.com",
            "nexprint.com"
        ]
        return domains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func isKnownModelPage(host: String, lowerPath: String) -> Bool {
        if host == "printables.com", lowerPath.contains("/model/") {
            return true
        }
        if host == "makerworld.com", lowerPath.contains("/models/") {
            return true
        }
        if host == "thingiverse.com", lowerPath.contains("/thing:") {
            return !lowerPath.hasSuffix("/zip")
        }
        if host == "thangs.com", (lowerPath.contains("/3d-model/") || lowerPath.hasPrefix("/m/")) {
            return true
        }
        if host == "cults3d.com", lowerPath.contains("/3d-model/") {
            return true
        }
        if host == "myminifactory.com", lowerPath.contains("/object/") {
            return true
        }
        if host == "grabcad.com", lowerPath.contains("/library/") {
            return true
        }
        if host == "github.com", lowerPath.split(separator: "/").count >= 2 {
            return !lowerPath.contains("/releases/download/")
        }
        return false
    }

    private static func isDirectDownloadOrCDN(_ url: URL, host: String) -> Bool {
        if knownCDNHostPrefixes.contains(where: { host.hasPrefix($0) }) {
            return true
        }
        if knownCDNHostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return true
        }
        let ext = url.pathExtension.lowercased()
        if directDownloadExtensions.contains(ext) {
            return true
        }
        let lowerPath = url.path.lowercased()
        if lowerPath.hasSuffix("/zip")
            || lowerPath.contains("/releases/download/")
            || lowerPath.contains("/download/")
            || lowerPath.contains("/api/") {
            return true
        }
        return false
    }

    /// Maps known direct-download/CDN URLs back to their canonical human-browsable model page
    /// when no full referrer page URL was stored in `kMDItemWhereFroms`.
    private static func canonicalizeKnownDownloadURL(_ url: URL) -> URL? {
        let host = normalizedHost(for: url)
        let path = url.path
        let parts = path.split(separator: "/").map(String.init)
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        func queryDigits(_ names: [String]) -> String? {
            for item in queryItems {
                if names.contains(where: { $0.caseInsensitiveCompare(item.name) == .orderedSame }),
                   let val = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !val.isEmpty,
                   val.allSatisfy(\.isNumber) {
                    return val
                }
            }
            return nil
        }

        // Thingiverse zip, files, or things URL -> https://www.thingiverse.com/thing:<id>
        if host == "thingiverse.com" || host.hasSuffix(".thingiverse.com") {
            if let thingSegment = parts.first(where: { $0.lowercased().hasPrefix("thing:") }) {
                let digits = thingSegment.dropFirst("thing:".count)
                if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                    return URL(string: "https://www.thingiverse.com/thing:\(digits)")
                }
            }
            if let idx = parts.firstIndex(where: { $0.caseInsensitiveCompare("things") == .orderedSame }),
               idx + 1 < parts.count,
               parts[idx + 1].allSatisfy(\.isNumber) {
                return URL(string: "https://www.thingiverse.com/thing:\(parts[idx + 1])")
            }
            if let digits = queryDigits(["thing_id", "thingId"]) {
                return URL(string: "https://www.thingiverse.com/thing:\(digits)")
            }
        }

        // Printables CDN / download URL -> https://www.printables.com/model/<id>
        // e.g. https://files.printables.com/media/prints/123456/stls/.../part.stl
        if host == "printables.com" || host.hasSuffix(".printables.com") {
            if let printsIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("prints") == .orderedSame }),
               printsIndex + 1 < parts.count {
                let modelID = parts[printsIndex + 1]
                if !modelID.isEmpty, modelID.allSatisfy(\.isNumber) {
                    return URL(string: "https://www.printables.com/model/\(modelID)")
                }
            }
            if let dlIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("download") == .orderedSame }),
               dlIndex + 1 < parts.count {
                let modelID = parts[dlIndex + 1]
                if !modelID.isEmpty, modelID.allSatisfy(\.isNumber) {
                    return URL(string: "https://www.printables.com/model/\(modelID)")
                }
            }
            if let digits = queryDigits(["model_id", "print_id", "modelId"]) {
                return URL(string: "https://www.printables.com/model/\(digits)")
            }
        }

        // MakerWorld CDN URL -> https://makerworld.com/en/models/<id>
        // e.g. https://makerworld.bblmw.com/makerworld/model/DSM00000001200654/...
        if host == "makerworld.com" || host.hasSuffix(".makerworld.com") || host == "bblmw.com" || host.hasSuffix(".bblmw.com") {
            if let modelIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("model") == .orderedSame }),
               modelIndex + 1 < parts.count,
               let normalizedID = normalizeMakerWorldModelID(parts[modelIndex + 1]) {
                return URL(string: "https://makerworld.com/en/models/\(normalizedID)")
            }
            if let digits = queryDigits(["modelId", "designModelId", "model_id"]) {
                return URL(string: "https://makerworld.com/en/models/\(digits)")
            }
        }

        // MyMiniFactory download URL -> https://www.myminifactory.com/object/3d-print-<id>
        if host == "myminifactory.com" || host.hasSuffix(".myminifactory.com") {
            if let dlIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("download") == .orderedSame }),
               dlIndex + 1 < parts.count,
               parts[dlIndex + 1].allSatisfy(\.isNumber) {
                return URL(string: "https://www.myminifactory.com/object/3d-print-\(parts[dlIndex + 1])")
            }
            if let digits = queryDigits(["object_id", "objectId"]) {
                return URL(string: "https://www.myminifactory.com/object/3d-print-\(digits)")
            }
        }

        // Thangs download/file URL -> https://thangs.com/m/<id>
        if host == "thangs.com" || host.hasSuffix(".thangs.com") {
            if let fileIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("file") == .orderedSame }),
               fileIndex + 1 < parts.count,
               parts[fileIndex + 1].allSatisfy(\.isNumber) {
                return URL(string: "https://thangs.com/m/\(parts[fileIndex + 1])")
            }
            if let modelIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("model") == .orderedSame }),
               modelIndex + 1 < parts.count,
               parts[modelIndex + 1].allSatisfy(\.isNumber) {
                return URL(string: "https://thangs.com/m/\(parts[modelIndex + 1])")
            }
        }

        // GitHub release/raw download -> https://github.com/<owner>/<repo>
        if host == "raw.githubusercontent.com", parts.count >= 2 {
            return URL(string: "https://github.com/\(parts[0])/\(parts[1])")
        }
        if host == "github.com", path.lowercased().contains("/releases/download/"), parts.count >= 2 {
            return URL(string: "https://github.com/\(parts[0])/\(parts[1])")
        }

        return nil
    }

    private static func extractKnownModelURL(fromText text: String) -> String? {
        guard let regex = webURLRegex else {
            return nil
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            let rawCandidate = nsText.substring(with: match.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            guard let valid = validatedWebURL(from: rawCandidate),
                  !isBareOriginURL(valid) else {
                continue
            }
            let host = normalizedHost(for: valid)
            if isKnownModelPage(host: host, lowerPath: valid.path.lowercased()) {
                return valid.absoluteString
            }
            if let canonical = canonicalizeKnownDownloadURL(valid) {
                return canonical.absoluteString
            }
        }
        return nil
    }

    private static func normalizeLicenseText(_ raw: String) -> String? {
        let lower = raw.lowercased()
        if lower.contains("cc0") || lower.contains("public domain") {
            return "CC0 (Public Domain)"
        }
        if lower.contains("cc-by-nc-sa") || lower.contains("cc by-nc-sa")
            || (lower.contains("attribution") && lower.contains("non-commercial") && lower.contains("share alike"))
            || (lower.contains("attribution") && lower.contains("noncommercial") && lower.contains("sharealike")) {
            return "CC BY-NC-SA 4.0"
        }
        if lower.contains("cc-by-nc-nd") || lower.contains("cc by-nc-nd")
            || (lower.contains("attribution") && lower.contains("non-commercial") && lower.contains("no derivatives")) {
            return "CC BY-NC-ND 4.0"
        }
        if lower.contains("cc-by-nc") || lower.contains("cc by-nc")
            || (lower.contains("attribution") && (lower.contains("non-commercial") || lower.contains("noncommercial"))) {
            return "CC BY-NC 4.0"
        }
        if lower.contains("cc-by-sa") || lower.contains("cc by-sa")
            || (lower.contains("attribution") && (lower.contains("share alike") || lower.contains("sharealike"))) {
            return "CC BY-SA 4.0"
        }
        if lower.contains("cc-by-nd") || lower.contains("cc by-nd")
            || (lower.contains("attribution") && lower.contains("no derivatives")) {
            return "CC BY-ND 4.0"
        }
        if lower.contains("cc-by") || lower.contains("cc by") || lower.contains("creative commons - attribution") {
            return "CC BY 4.0"
        }
        if lower.contains("standard digital file license") {
            return "Standard Digital File License"
        }
        if lower.contains("mit license") || lower == "mit" {
            return "MIT"
        }
        if lower.contains("gnu general public license") || lower.contains("gpl-3") || lower.contains("gplv3") {
            return "GPL-3.0"
        }
        if lower.contains("personal use only") {
            return "Personal Use Only"
        }
        return nil
    }

    private static func decodeXMLEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var out = input
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'")
        ]
        for (entity, replacement) in entities {
            out = out.replacing(entity, with: replacement)
        }
        return out
    }

    /// Infers a designer / creator handle when explicitly encoded in a recognized source URL.
    private static func inferDesigner(from urls: [URL]) -> String? {
        for url in urls {
            let host = normalizedHost(for: url)
            let segments = url.pathComponents.filter { $0 != "/" }

            // Thangs: /designer/<DesignerName>/3d-model/...
            if host == "thangs.com",
               let idx = segments.firstIndex(where: { $0.caseInsensitiveCompare("designer") == .orderedSame }),
               idx + 1 < segments.count {
                if let name = cleanDesignerToken(segments[idx + 1]) {
                    return name
                }
            }

            // Printables & MakerWorld: /@<Handle>/... or /en/@<Handle>/...
            if host == "printables.com" || host == "makerworld.com" {
                if let handleSegment = segments.first(where: { $0.hasPrefix("@") }) {
                    if let name = cleanDesignerToken(String(handleSegment.dropFirst())) {
                        return name
                    }
                }
            }

            // Cults3D & MyMiniFactory: /users/<Handle>/...
            if host == "cults3d.com" || host == "myminifactory.com",
               let idx = segments.firstIndex(where: { $0.caseInsensitiveCompare("users") == .orderedSame }),
               idx + 1 < segments.count {
                if let name = cleanDesignerToken(segments[idx + 1]) {
                    return name
                }
            }

            // GitHub: github.com/<owner>/<repo> or raw.githubusercontent.com/<owner>/<repo>
            if (host == "github.com" || host == "raw.githubusercontent.com"),
               segments.count >= 2 {
                let reserved: Set<String> = ["topics", "explore", "search", "orgs", "settings", "notifications", "marketplace"]
                let candidate = segments[0]
                if !reserved.contains(candidate.lowercased()), let name = cleanDesignerToken(candidate) {
                    return name
                }
            }
        }
        return nil
    }

    private static func cleanDesignerToken(_ raw: String) -> String? {
        let decoded = raw.removingPercentEncoding ?? raw
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        return trimmed
    }
}
