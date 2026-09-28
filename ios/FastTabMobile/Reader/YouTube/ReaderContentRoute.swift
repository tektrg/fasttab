import Foundation
import IndieLinks

/// Which pipeline the reader uses for a URL: a YouTube video (not a Short) shows its
/// transcript; everything else goes through Readability (`ReaderExtractor`).
enum ReaderContentRoute: Equatable {
    case article
    case youtubeTranscript(videoID: String)

    static func route(for url: URL) -> ReaderContentRoute {
        guard case .youtubeVideo(let videoID, let isShort)? = LinkSiteDetector.match(url)?.target,
              !isShort else { return .article }
        return .youtubeTranscript(videoID: videoID)
    }
}
