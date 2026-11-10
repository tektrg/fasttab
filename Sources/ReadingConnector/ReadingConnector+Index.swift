import FastTabReader
import Foundation

/// The connector's own data as index sources. Bookmarks, history and fetched text add theirs
/// beside these (see `ReadingTools.indexSources`).
extension ReadingConnector {
    /// List pages and phone-read pages. Pages with the user's highlights or comments rank up.
    public var listIndexSource: IndexSource {
        let connector = self
        return IndexSource(
            name: "list",
            signature: { IndexSource.fileSignature([connector.sources.listFile, connector.sources.activityFile,
                                                    connector.sources.readerDirectory.appendingPathComponent("highlights.json")]) },
            documents: {
                let highlighted = Set(await connector.highlights(limit: .max).map(\.highlight.urlKey))
                return connector.items().map { item in
                    let key = URL(string: item.url)?.readerCanonicalKey ?? item.url
                    return IndexDocument(source: "list", id: item.id, url: item.url, title: item.displayTitle,
                                         body: [item.url, item.domain ?? ""].joined(separator: " "),
                                         boost: highlighted.contains(key) ? 0.5 : 0, date: item.lastActivityAt)
                }
            })
    }

    /// One row per highlight (the quote) and one per highlight that has comments (the
    /// comments): the user's own words rank highest.
    public var highlightIndexSources: [IndexSource] {
        let connector = self
        let signature: @Sendable () -> String = {
            IndexSource.fileSignature([connector.sources.readerDirectory.appendingPathComponent("highlights.json"),
                                       connector.sources.readerDirectory.appendingPathComponent("comments")])
        }
        return [
            IndexSource(name: "highlights", signature: signature, documents: {
                await connector.highlights(limit: .max).map { entry in
                    let h = entry.highlight
                    return IndexDocument(source: "highlights", id: h.id, url: h.articleURL?.absoluteString ?? h.urlKey,
                                         title: h.pageTitle, body: ([h.selectedText] + (h.tags ?? [])).joined(separator: " "),
                                         boost: entry.comments.isEmpty ? 1 : 1.5, date: h.createdAt)
                }
            }),
            IndexSource(name: "comments", signature: signature, documents: {
                await connector.highlights(limit: .max).compactMap { entry in
                    let texts = entry.comments.compactMap(\.text)
                    guard !texts.isEmpty else { return nil }
                    let h = entry.highlight
                    return IndexDocument(source: "comments", id: h.id, url: h.articleURL?.absoluteString ?? h.urlKey,
                                         title: h.pageTitle, body: texts.joined(separator: "\n"), boost: 2, date: h.createdAt)
                }
            }),
        ]
    }
}
