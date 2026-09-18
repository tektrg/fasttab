import Foundation
import Testing
@testable import CommandBarKit

@Test func searchWordsSplitOnPunctuationAndFoldAccents() async throws {
    #expect(searchWords(in: "sevensystem.vn") == ["sevensystem", "vn"])
    #expect(searchWords(in: "e-commerce") == ["e", "commerce"])
    #expect(searchWords(in: "  Đơn   hàng ") == ["don", "hang"])
    #expect(searchWords(in: "|||").isEmpty)
}

@Test func foldForMatchingStripsPunctuationAccentsAndCaseButKeepsSpaces() async throws {
    #expect(foldForMatching("Realtime E-Commerce | Bi Hub") == "realtime ecommerce  bi hub")
    #expect(foldForMatching("Đơn Hàng") == "don hang")
}

@Test func foldedKeysRequireEveryWordInSomeKey() async throws {
    let keys = [foldForMatching("Realtime e-commerce order"), foldForMatching("bihub.sevensystem.vn")]

    #expect(foldedKeys(keys, containAllWordsOf: searchWords(in: "real time sevensystem")))
    #expect(!foldedKeys(keys, containAllWordsOf: searchWords(in: "real time invoice")))
    #expect(foldedKeys(keys, containAllWordsOf: []))
}
