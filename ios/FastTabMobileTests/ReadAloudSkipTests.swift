import XCTest
@testable import FastTabMobile

/// Back / forward 15 s for spoken text (`ReadAloudSkip`). Short sentences and a 1-second
/// skip (15 characters at 1.0×) keep the arithmetic readable:
///
///     chunk 0 "Title"                                      global 0
///     chunk 1 "One fish swims. Two fish swim. Red fish."   sentences at 0, 16, 31 → global 5, 21, 36
///     chunk 2 "Blue fish dive. Old fish rest."             sentences at 0, 16     → global 45, 61 (end 75)
final class ReadAloudSkipTests: XCTestCase {
    private let chunks = ["Title", "One fish swims. Two fish swim. Red fish.", "Blue fish dive. Old fish rest."]

    private func skip(_ direction: ReadAloudSkip.Direction, from chunk: Int, _ offset: Int,
                      seconds: TimeInterval = 1, rate: Double = 1) -> ReadAloudSkip.Target {
        ReadAloudSkip.target(chunks: chunks, from: ReadAloudPosition(chunk: chunk, offset: offset),
                             rate: rate, direction: direction, seconds: seconds)
    }

    private func at(_ chunk: Int, _ offset: Int) -> ReadAloudSkip.Target {
        .position(ReadAloudPosition(chunk: chunk, offset: offset))
    }

    func testFifteenSecondsIsAboutTwoHundredCharactersScaledBySpeed() {
        XCTAssertEqual(ReadAloudSkip.characters(in: ReadAloudSkip.interval, rate: 1), 225)
        XCTAssertEqual(ReadAloudSkip.characters(in: ReadAloudSkip.interval, rate: 2), 450)
        XCTAssertEqual(ReadAloudSkip.characters(in: ReadAloudSkip.interval, rate: 0.75), 169)
    }

    func testMidParagraphJumpsToTheNearestSentenceStart() {
        XCTAssertEqual(skip(.forward, from: 1, 0), at(1, 16))  // goal 20 → "Two" (21)
        XCTAssertEqual(skip(.backward, from: 1, 31), at(1, 16)) // goal 21 → "Two"
    }

    func testSnapsFromMidSentenceToASentenceStart() {
        // At "swim" (global 25), the device voice's word-level position.
        XCTAssertEqual(skip(.forward, from: 1, 20), at(1, 31))  // goal 40: "Red" (36) beats "Blue" (45)
        XCTAssertEqual(skip(.backward, from: 1, 20), at(1, 0))  // goal 10: "One" (5) beats "Title" (0)
    }

    func testCrossesParagraphBoundaries() {
        XCTAssertEqual(skip(.forward, from: 1, 31), at(2, 0))               // goal 51: "Blue" (45)
        XCTAssertEqual(skip(.backward, from: 2, 16, seconds: 2), at(1, 31)) // goal 31: "Red" (36)
    }

    func testFasterSpeedSkipsFurther() {
        XCTAssertEqual(skip(.forward, from: 1, 0, rate: 1), at(1, 16))
        XCTAssertEqual(skip(.forward, from: 1, 0, rate: 2), at(1, 31)) // 30 characters → goal 35
    }

    func testAlwaysMovesInTheSkipDirection() {
        // A tiny skip from a sentence start still lands on the previous / next sentence.
        XCTAssertEqual(skip(.backward, from: 1, 16, seconds: 0.1), at(1, 0))
        XCTAssertEqual(skip(.forward, from: 1, 16, seconds: 0.1), at(1, 31))
    }

    func testBackPastTheStartRestartsFromTheBeginning() {
        XCTAssertEqual(skip(.backward, from: 1, 0), at(0, 0))
        XCTAssertEqual(skip(.backward, from: 0, 2), at(0, 0))
        XCTAssertEqual(skip(.backward, from: 0, 0), at(0, 0))
    }

    func testForwardPastTheEndEnds() {
        XCTAssertEqual(skip(.forward, from: 2, 0), at(2, 16))           // goal 60: "Old" (61)
        XCTAssertEqual(skip(.forward, from: 2, 16), .end)               // goal 76 > 75
        XCTAssertEqual(skip(.forward, from: 2, 20, seconds: 0.5), .end) // goal 73, but no sentence left
    }

    func testOutOfRangePositionsAreClamped() {
        XCTAssertEqual(skip(.forward, from: 9, 99), .end)
        XCTAssertEqual(skip(.backward, from: -1, -5), at(0, 0))
    }

    func testNoChunksEnds() {
        XCTAssertEqual(ReadAloudSkip.target(chunks: [], from: ReadAloudPosition(chunk: 0, offset: 0),
                                            rate: 1, direction: .forward), .end)
    }

    func testEstimatedTimelineForNowPlaying() {
        let timeline = ReadAloudSkip.estimatedTimeline(chunks: chunks, at: ReadAloudPosition(chunk: 1, offset: 16), rate: 1)
        XCTAssertEqual(timeline.elapsed, 21.0 / 15, accuracy: 0.001)
        XCTAssertEqual(timeline.duration, 75.0 / 15, accuracy: 0.001)
        XCTAssertEqual(ReadAloudSkip.estimatedTimeline(chunks: chunks, at: ReadAloudPosition(chunk: 1, offset: 16), rate: 2).duration,
                       75.0 / 30, accuracy: 0.001)
    }

    // MARK: - Starting mid-chunk (shared by skips and the engines' fallbacks)

    func testMidChunkStartCutsOnlyThatChunkAndShiftsItsRangesBack() {
        let cut = ReadAloudMidChunkStart.cut(chunks, chunk: 1, offset: 16)
        XCTAssertEqual(cut, ["Title", "Two fish swim. Red fish.", chunks[2]])
        XCTAssertEqual(ReadAloudMidChunkStart.cut(chunks, chunk: 1, offset: 0), chunks)

        let word = SpeechEngineEvent.word(chunk: 1, range: NSRange(location: 4, length: 4))
        XCTAssertEqual(ReadAloudMidChunkStart.shift(word, inChunk: 1, by: 16), .word(chunk: 1, range: NSRange(location: 20, length: 4)))
        let otherChunk = SpeechEngineEvent.sentence(chunk: 2, range: NSRange(location: 0, length: 5))
        XCTAssertEqual(ReadAloudMidChunkStart.shift(otherChunk, inChunk: 1, by: 16), otherChunk)
    }
}
