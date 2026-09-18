import Foundation
import Testing
@testable import AgentBar

struct ServerSentEventParserTests {
    private func feed(_ parser: inout ServerSentEventParser, _ text: String) -> [String] {
        parser.feed(Data(text.utf8))
    }

    @Test func parsesTwoCompleteEvents() {
        var parser = ServerSentEventParser()
        #expect(feed(&parser, "data: {\"a\":1}\n\ndata: {\"b\":2}\n\n") == ["{\"a\":1}", "{\"b\":2}"])
    }

    @Test func eventSplitAcrossChunksEmitsOnlyWhenComplete() {
        var parser = ServerSentEventParser()
        #expect(feed(&parser, "dat").isEmpty)
        #expect(feed(&parser, "a: {\"hel").isEmpty)
        #expect(feed(&parser, "lo\":1}\n").isEmpty)          // line done, event not yet terminated
        #expect(feed(&parser, "\n") == ["{\"hello\":1}"])
    }

    @Test func blankLineArrivingInItsOwnChunkTerminatesTheEvent() {
        var parser = ServerSentEventParser()
        #expect(feed(&parser, "data: x\n\n") == ["x"])
        #expect(feed(&parser, "data: y\n").isEmpty)
        #expect(feed(&parser, "\ndata: z\n\n") == ["y", "z"])
    }

    @Test func byteAtATimeDeliveryStillWorks() {
        var parser = ServerSentEventParser()
        var events: [String] = []
        for byte in Array("data: {\"k\":\"v\"}\n\n".utf8) {
            events += parser.feed(Data([byte]))
        }
        #expect(events == ["{\"k\":\"v\"}"])
    }

    @Test func multiByteCharacterSplitAcrossChunksSurvives() {
        var parser = ServerSentEventParser()
        let bytes = Array("data: ✶ working\n\n".utf8)
        let splitInsideStar = 8  // "data: " is 6 bytes; the star is 3 bytes (6..<9)
        var events = parser.feed(Data(bytes[..<splitInsideStar]))
        events += parser.feed(Data(bytes[splitInsideStar...]))
        #expect(events == ["✶ working"])
    }

    @Test func handlesCRLFCommentsAndOtherFields() {
        var parser = ServerSentEventParser()
        let events = feed(&parser, ": keep-alive\r\n\r\nevent: state\r\nid: 7\r\ndata: one\r\n\r\n")
        #expect(events == ["one"])
    }

    @Test func multipleDataLinesJoinWithNewline() {
        var parser = ServerSentEventParser()
        #expect(feed(&parser, "data: a\ndata: b\n\n") == ["a\nb"])
    }

    @Test func dataWithoutSpaceAfterColonKeepsValue() {
        var parser = ServerSentEventParser()
        #expect(feed(&parser, "data:{\"a\":1}\n\n") == ["{\"a\":1}"])
    }

    @Test func blankLinesWithoutDataEmitNothing() {
        var parser = ServerSentEventParser()
        #expect(feed(&parser, "\n\n\n").isEmpty)
    }
}
