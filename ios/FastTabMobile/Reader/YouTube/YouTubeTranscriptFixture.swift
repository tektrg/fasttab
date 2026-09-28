#if DEBUG
import Foundation
import IndieTranscripts

/// DEBUG-only stand-in for the transcript server (launch with `-FastTabTranscriptFixture`),
/// for checking the reader before theindie-api serves `/v1/youtube/transcript`.
enum YouTubeTranscriptFixture {
    static let launchArgument = "-FastTabTranscriptFixture"

    static func transcript(videoID: String) -> Transcript {
        let sentences = [
            "Welcome back to the channel.", "Today we look at how transcripts become readable paragraphs.",
            "Each caption line is only a few seconds long.", "Grouping them gives you something you can actually read.",
            "Tap any timestamp to jump the video there.", "Scroll by hand and the reader stops following.",
            "Tap back to live to follow again.", "That is the whole idea.",
        ]
        let lines = (0..<120).map { i in
            TranscriptLine(startMs: i * 4_000, durationMs: 4_000, text: sentences[i % sentences.count])
        }
        return Transcript(videoId: videoID, title: "Fixture transcript", lang: "en", kind: .asr,
                          availableLangs: ["en"], lines: lines)
    }
}
#endif
