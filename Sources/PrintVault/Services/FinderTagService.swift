import Foundation

/// Reads and writes macOS native Finder tags (`kMDItemUserTags` / `NSURLTagNamesKey`)
enum FinderTagService {
    private static let tagKey = URLResourceKey(rawValue: "NSURLTagNamesKey")

    /// Reads the current Finder tags attached to a file URL on disk.
    static func readTags(for url: URL) -> [String] {
        guard let values = try? url.resourceValues(forKeys: [tagKey]),
              let rawTags = values.allValues[tagKey] as? [String] else {
            return []
        }
        return rawTags
    }

    /// Writes the given tags (and optional category name) to the file's macOS Finder tags.
    @discardableResult
    static func writeTags(_ tags: [String], categoryName: String? = nil, to url: URL) -> Bool {
        var combined = tags
        if let categoryName, !categoryName.isEmpty, !combined.contains(categoryName) {
            combined.insert(categoryName, at: 0)
        }
        let nsURL = url as NSURL
        do {
            try nsURL.setResourceValue(combined, forKey: URLResourceKey(rawValue: "NSURLTagNamesKey"))
            return true
        } catch {
            return false
        }
    }

    /// Merges any existing Finder tags on disk into the item's tag list.
    @MainActor
    static func syncFromFinder(for item: PrintFileItem) {
        let diskTags = readTags(for: item.fileURL)
        guard !diskTags.isEmpty else { return }
        var current = Set(item.tags)
        for tag in diskTags {
            current.insert(tag)
        }
        item.tags = Array(current).sorted()
    }

    /// Pushes the item's tags and category name out to macOS Finder tags.
    @MainActor
    @discardableResult
    static func syncToFinder(for item: PrintFileItem, includeCategory: Bool = true) -> Bool {
        writeTags(
            item.tags,
            categoryName: includeCategory ? item.category?.name : nil,
            to: item.fileURL
        )
    }
}
