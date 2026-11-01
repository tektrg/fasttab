import FastTabSync
import Foundation

/// A cleaned-up article as the Mac reader shows it (Readability output). Same fields as the
/// phone's `ReaderArticle`; cached per FastTab List item so reopening is instant and offline.
struct MacReaderArticle: Codable, Equatable, Sendable {
    let title: String
    let byline: String
    let siteName: String
    /// Sanitised article HTML from Readability.
    let content: String
    let url: URL
    let extractedAt: Date

    var isEmpty: Bool { content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// One JSON file per article under `…/com.trungluong.FastTab/ReaderCache/`, keyed by the
/// FastTab List item id (canonical URL hash), so the same link always hits the same file.
struct MacReaderArticleCache: Sendable {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.trungluong.FastTab", isDirectory: true)
            .appendingPathComponent("ReaderCache", isDirectory: true)
    }

    func article(forURL urlString: String) -> MacReaderArticle? {
        guard let data = try? Data(contentsOf: fileURL(forURL: urlString)),
              let article = try? JSONDecoder().decode(MacReaderArticle.self, from: data),
              !article.isEmpty else { return nil }
        return article
    }

    func store(_ article: MacReaderArticle, forURL urlString: String) {
        guard !article.isEmpty, let data = try? JSONEncoder().encode(article) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(forURL: urlString), options: .atomic)
    }

    func fileURL(forURL urlString: String) -> URL {
        directory.appendingPathComponent(FastTabListLibrary.itemID(for: urlString) + ".json")
    }
}

/// The reader's web resources, shared with the iPhone app (single copy in
/// `ios/FastTabMobile/Resources/`; the Mac build scripts copy them into
/// `FastTab.app/Contents/Resources/`).
enum MacReaderResources {
    static var readabilityJS: String? { load("Readability", "js") }
    static var readerTemplateHTML: String? { load("reader_template", "html") }

    private static func load(_ name: String, _ ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
