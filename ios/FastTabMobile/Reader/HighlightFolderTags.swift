import Foundation
import FastTabSync
import IndieTags

/// Tags derived from bookmark folders: an article bookmarked in `Work / SSV` gives its
/// highlights the tag `Work/SSV`. Computed at read time from the synced bookmarks (never
/// stored on the highlight), so moving a bookmark moves the tag.
public enum HighlightFolderTags {
    /// Folder tags per article, keyed by `URL.readerCanonicalKey` (the key highlights use,
    /// not `LocalCache.findBookmark`'s normaliser). An article bookmarked in several folders
    /// gets each folder once; bookmarks without a folder add nothing.
    public static func tagsByArticleKey(from blobs: [SyncedBookmarkBlob]) -> [String: [TagPath]] {
        var tagsByKey: [String: [TagPath]] = [:]
        for bookmark in blobs.flatMap(\.bookmarks) {
            guard let folderTag = tag(forFolderPath: bookmark.folderPath),
                  let articleKey = URL(string: bookmark.url)?.readerCanonicalKey else { continue }
            let existing = tagsByKey[articleKey, default: []]
            guard !existing.contains(where: { $0.normalizedPath == folderTag.normalizedPath }) else { continue }
            tagsByKey[articleKey] = existing + [folderTag]
        }
        return tagsByKey
    }

    /// `"Work / SSV"` → `Work/SSV`; `nil` for no folder.
    public static func tag(forFolderPath folderPath: String?) -> TagPath? {
        guard let folderPath else { return nil }
        let segments = BookmarkTreeBuilder.splitPath(folderPath)
        return TagPath(segments.joined(separator: String(TagPath.separator)))
    }
}
