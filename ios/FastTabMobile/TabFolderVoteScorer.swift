import Foundation

/// One existing bookmark, flattened to what folder scoring needs.
struct ScoredBookmark: Sendable, Equatable {
    let title: String
    let url: String
    let browserName: String
    let profileName: String
    let folderPath: [String]
}

/// An existing folder chosen for a tab, with how sure we are (0...1).
struct TabFolderRecommendation: Sendable, Equatable {
    let browserName: String
    let profileName: String
    let folderPath: [String]
    let confidence: Double

    var folderName: String { folderPath.last ?? "Top Level" }
    var destination: BookmarkMoveDestination {
        BookmarkMoveDestination(browserName: browserName, profileName: profileName, folderPath: folderPath)
    }
}

/// Pure "similar bookmarks vote for their folder" scoring. Same host counts
/// double, a similar title counts once; confidence is the winning folder's
/// share of all votes. Returns nil when evidence is too thin to trust, so the
/// caller can fall back to the on-device model.
enum TabFolderVoteScorer {
    static let minimumConfidence = 0.80
    static let minimumVotes = 3.0
    static let hostVoteWeight = 2.0
    static let titleVoteWeight = 1.0

    static func recommend(
        tabURL: String,
        tabTitle: String,
        bookmarks: [ScoredBookmark],
        isTitleSimilar: (String, String) -> Bool
    ) -> TabFolderRecommendation? {
        let tabHost = normalizedHost(tabURL)
        var votesByFolder: [String: (bookmark: ScoredBookmark, votes: Double)] = [:]
        var totalVotes = 0.0

        for bookmark in bookmarks {
            var vote = 0.0
            if let tabHost, normalizedHost(bookmark.url) == tabHost { vote += hostVoteWeight }
            if !tabTitle.isEmpty, !bookmark.title.isEmpty, isTitleSimilar(tabTitle, bookmark.title) {
                vote += titleVoteWeight
            }
            guard vote > 0 else { continue }
            let key = folderKey(bookmark)
            votesByFolder[key] = (bookmark, (votesByFolder[key]?.votes ?? 0) + vote)
            totalVotes += vote
        }

        guard totalVotes >= minimumVotes,
              let winner = votesByFolder.values.max(by: { $0.votes < $1.votes }) else { return nil }
        return TabFolderRecommendation(
            browserName: winner.bookmark.browserName,
            profileName: winner.bookmark.profileName,
            folderPath: winner.bookmark.folderPath,
            confidence: winner.votes / totalVotes
        )
    }

    /// True when the exact page (host + path) is already bookmarked.
    static func isAlreadyBookmarked(tabURL: String, bookmarks: [ScoredBookmark]) -> Bool {
        let key = pageKey(tabURL)
        return bookmarks.contains { pageKey($0.url) == key }
    }

    static func folderKey(_ bookmark: ScoredBookmark) -> String {
        "\(bookmark.browserName)|\(bookmark.profileName)|\(bookmark.folderPath.joined(separator: "/"))"
    }

    static func normalizedHost(_ urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func pageKey(_ urlString: String) -> String {
        let path = URL(string: urlString)?.path() ?? ""
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return "\(normalizedHost(urlString) ?? urlString)\(trimmed)".lowercased()
    }

    /// Parses the model's "<number>|<confidence>" reply into a folder index
    /// (0-based) and confidence. Accepts confidence as 0...1 or 0...100.
    static func parseModelChoice(_ reply: String, folderCount: Int) -> (index: Int, confidence: Double)? {
        let parts = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let number = Int(parts[0]), (1...folderCount).contains(number),
              var confidence = Double(parts[1].replacingOccurrences(of: "%", with: "")) else { return nil }
        if confidence > 1 { confidence /= 100 }
        guard (0...1).contains(confidence) else { return nil }
        return (number - 1, confidence)
    }
}
