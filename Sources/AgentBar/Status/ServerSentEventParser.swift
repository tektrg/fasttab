import Foundation

/// Incremental parser for a `text/event-stream` body. Feed it bytes in whatever
/// chunks the network delivers (even mid-line or mid-UTF-8-character); it
/// returns the `data:` payload of each event as soon as the event is complete
/// (terminated by a blank line). `event:`, `id:`, `retry:` and `:comment`
/// lines are ignored: the dashboard only ever sends `data:` events.
struct ServerSentEventParser {
    private static let newlineByte = UInt8(ascii: "\n")

    private var pendingBytes = Data()
    private var currentEventDataLines: [String] = []

    /// Returns the data payloads of every event completed by this chunk.
    mutating func feed(_ chunk: Data) -> [String] {
        pendingBytes.append(chunk)
        var completedEvents: [String] = []
        while let newlineIndex = pendingBytes.firstIndex(of: Self.newlineByte) {
            let lineBytes = pendingBytes[pendingBytes.startIndex..<newlineIndex]
            pendingBytes = Data(pendingBytes[(newlineIndex + 1)...])
            if let event = consumeLine(String(decoding: lineBytes, as: UTF8.self)) {
                completedEvents.append(event)
            }
        }
        return completedEvents
    }

    /// Returns the event payload if this line completes one.
    private mutating func consumeLine(_ rawLine: String) -> String? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { currentEventDataLines = [] }
            return currentEventDataLines.isEmpty ? nil : currentEventDataLines.joined(separator: "\n")
        }
        guard line.hasPrefix("data:") else { return nil }  // comments and other fields
        var value = line.dropFirst("data:".count)
        if value.first == " " { value = value.dropFirst() }
        currentEventDataLines.append(String(value))
        return nil
    }
}
