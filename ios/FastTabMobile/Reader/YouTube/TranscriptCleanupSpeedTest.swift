#if DEBUG
import Foundation
import IndieTextCleanup
import IndieTranscripts

/// Debug-only timing run: launch with `-cleanupSpeedTest <videoID>` (devicectl `--console` shows
/// the output). Fetches the transcript, keeps its first 30 minutes, then cleans it at 1, 2 and 4
/// concurrent chunks and prints wall time and fallback counts per level.
enum TranscriptCleanupSpeedTest {
    static let launchArgument = "-cleanupSpeedTest"
    static let levels = [1, 2, 4]
    static let windowMs = 30 * 60 * 1000

    static var requestedVideoID: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: launchArgument), flag + 1 < arguments.count else { return nil }
        return arguments[flag + 1]
    }

    static func runIfRequested() async {
        guard let videoID = requestedVideoID else { return }
        report("start video=\(videoID) available=\(FoundationModelTextCleaner.isAvailable)")
        guard FoundationModelTextCleaner.isAvailable else { return report("done: model unavailable") }
        let items: [String]
        do {
            let transcript = try await YouTubeTranscriptLoader.live.transcript(videoID: videoID, lang: "en")
            items = TranscriptParagraphs(transcript).paragraphs.filter { $0.startMs < windowMs }.map(\.text)
        } catch {
            return report("done: transcript failed \(error)")
        }
        let characters = items.reduce(0) { $0 + $1.count }
        let chunks = TextChunker.chunks(for: items).count
        report("paragraphs=\(items.count) characters=\(characters) chunks=\(chunks)")

        // Warm-up: the first call pays the model load; keep it out of the timings.
        _ = try? await FoundationModelTextCleaner().clean("[[1]]\nok so um hello", instruction: TranscriptCleanup.instruction)

        for level in levels {
            let start = ContinuousClock.now
            let firstChunk = FirstChunkClock()
            let run = ChunkedTextCleanup(items: items, instruction: TranscriptCleanup.instruction,
                                         cleaner: FoundationModelTextCleaner(), maxConcurrentChunks: level)
            guard let result = try? await run.run(onChunkSettled: { _ in await firstChunk.mark() }) else {
                report("level=\(level) cancelled"); continue
            }
            let total = start.duration(to: .now)
            let firstAfter = await firstChunk.elapsed(since: start)
            let fallbacks = Dictionary(grouping: result.compactMap(\.fallback), by: { kind($0) }).mapValues(\.count)
            report("level=\(level) total=\(seconds(total))s firstChunk=\(firstAfter.map(seconds) ?? "-")s "
                   + "cleaned=\(result.filter(\.isCleaned).count)/\(result.count) fallbacks=\(fallbacks)")
            if level == levels.first, let sample = result.first(where: \.isCleaned) {
                report("sample before: \(items[sample.index].prefix(300))")
                report("sample after:  \(sample.text.prefix(300))")
            }
        }
        report("done")
    }

    private actor FirstChunkClock {
        private var at: ContinuousClock.Instant?
        func mark() { if at == nil { at = .now } }
        func elapsed(since start: ContinuousClock.Instant) -> Duration? { at.map { start.duration(to: $0) } }
    }

    private static func kind(_ reason: CleanupFallbackReason) -> String {
        switch reason {
        case .cleanerFailed(let detail): "error:\(detail.prefix(60))"
        case .malformedReply: "malformed"
        case .lengthOutOfRange: "length"
        case .refusal: "refusal"
        }
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    private static func report(_ line: String) { print("[cleanup-speedtest] \(line)") }
}
#endif
