import Foundation

extension KeyedDecodingContainer {
    /// Decodes a field, returning nil when it is absent, null OR the wrong type,
    /// so one odd value never costs us the whole row.
    func lenient<Value: Decodable>(_ key: Key) -> Value? {
        try? decodeIfPresent(Value.self, forKey: key)
    }
}

/// An array that silently drops elements that fail to decode (and decodes to
/// empty when the value is not an array), so one bad row never drops the rest.
struct LenientArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        guard var container = try? decoder.unkeyedContainer() else {
            elements = []
            return
        }
        var decoded: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                decoded.append(element)
            } else {
                // A failed decode does not advance the container: skip the bad slot.
                _ = try? container.decode(SkippedValue.self)
            }
        }
        elements = decoded
    }
}

private struct SkippedValue: Decodable {
    init(from decoder: Decoder) throws {}
}
