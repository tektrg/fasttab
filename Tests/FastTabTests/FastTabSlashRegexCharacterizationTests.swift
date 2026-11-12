import Foundation
import Testing
import IndieSearch
import IndieCommandBar

/// Gap 11: the shared slash-command hook must never swallow Fast Tab's `/regex/` searches.
/// Fast Tab supplies no commands, so a leading "/" stays search text.
struct FastTabSlashRegexCharacterizationTests {
    /// Fast Tab's command list: none.
    private let fastTabCommands: [CommandBarCommand] = []

    @Test func regexQueryIsNotACommand() {
        for query in ["/", "/git.*hub/", "/^docs/", "/new"] {
            #expect(CommandBarCommandRows.matching(query, in: fastTabCommands).isEmpty)
            #expect(CommandBarCommandRows.exact(query, in: fastTabCommands) == nil)
        }
    }

    @Test func regexQueryStillFiltersTitles() {
        let query = SearchBoxQuery("/git.*hub/")
        #expect(query.isPattern)
        #expect(query.matches(["GitHub - pulls", nil]))
        #expect(!query.matches(["Gitlab", "example.com"]))
    }
}
