import Foundation
import Testing
@testable import AgentBar

struct PermissionPromptTests {
    typealias P = PermissionFixtures

    private func prompt(_ labels: [String]) -> PermissionPrompt {
        PermissionPrompt(
            tool: "Bash", detail: "ls", title: "Do you want to proceed?",
            options: labels.enumerated().map { .init(index: $0 + 1, label: $1) }, cursorIndex: 1
        )
    }

    // MARK: - Which choices a box offers (the dashboard's own rules)

    @Test func aStandardBoxOffersAllowAllowAlwaysAndDenyMappedToItsRows() {
        #expect(P.bash.choices == [.allow, .allowAlways, .deny])
        #expect(P.bash.option(for: .allow)?.index == 1)
        #expect(P.bash.option(for: .allowAlways)?.index == 2)
        #expect(P.bash.option(for: .deny)?.index == 3)
    }

    @Test func aOneOffBoxOffersNoAllowAlways() {
        #expect(P.oneOff.choices == [.allow, .deny])
        #expect(P.oneOff.option(for: .allowAlways) == nil)
    }

    @Test func aChoiceTheBoxDoesNotHaveIsNotOffered() {
        #expect(prompt(["Yes", "Maybe"]).choices == [.allow])                 // last row is not a "No"
        #expect(prompt(["Proceed", "No"]).choices == [.deny])                 // first row is not a "Yes"
        #expect(prompt(["Yes"]).choices == [.allow])                          // (the reader never yields one row: two are needed)
        #expect(prompt(["No"]).choices == [.deny])
        #expect(prompt(["Sure", "Never"]).choices.isEmpty)
    }

    @Test func aFirstRowThatSaysDontAskAgainIsNeverPlainAllow() {
        let odd = prompt(["Yes, and don't ask again for ls", "No"])
        #expect(odd.option(for: .allow) == nil)
        #expect(odd.option(for: .allowAlways)?.index == 1)
    }

    @Test func rowsAreMappedByTheirNumbersNotTheirPositions() {
        let renumbered = PermissionPrompt(
            tool: "Bash", detail: "ls", title: "Do you want to proceed?",
            options: [.init(index: 4, label: "Yes"), .init(index: 7, label: "No")], cursorIndex: 4
        )
        #expect(renumbered.option(for: .deny)?.index == 7)
    }

    // MARK: - Identity

    @Test func twoReadingsOfTheSameBoxThatDifferOnlyInWhitespaceAreTheSameBox() {
        let spaced = PermissionPrompt(tool: "Bash", detail: "echo   a\n  b ", title: "Do you want to proceed?  ", options: P.bash.options, cursorIndex: 2)
        let tidy = PermissionPrompt(tool: "Bash", detail: "echo a b", title: "Do you want to proceed?", options: P.bash.options, cursorIndex: 1)
        #expect(spaced.identity == tidy.identity)
    }

    @Test func differentToolOrCommandIsADifferentBox() {
        let other = PermissionPrompt(tool: "Bash", detail: "rm -rf /", title: P.bash.title, options: P.bash.options, cursorIndex: 1)
        #expect(other.identity != P.bash.identity)
    }

    // MARK: - Wire names

    @Test func choicesUseTheDashboardsWords() {
        #expect(PermissionChoice.allCases.map(\.wireName) == ["allow", "allow-always", "deny"])
    }

    @Test func rowsSayApprovalOrDenialWhileSending() {
        #expect(PermissionChoice.allow.sendingLabel == "Sending approval…")
        #expect(PermissionChoice.allowAlways.sendingLabel == "Sending approval…")
        #expect(PermissionChoice.deny.sendingLabel == "Sending denial…")
    }

    // MARK: - An edit box's per-folder grant is its allow-always

    @Test func aForThisSessionRowIsAllowAlwaysButOnlyWhenItSaysYes() {
        let edit = prompt(["Yes", "Yes, and allow Claude to edit files in this project's .claude folder for this session", "No"])
        #expect(edit.choices == [.allow, .allowAlways, .deny])
        #expect(edit.option(for: .allowAlways)?.index == 2)
        let notYes = prompt(["Yes", "No, and allow edits for this session", "No"])
        #expect(notYes.option(for: .allowAlways) == nil)
    }

    @Test func aDetailWithADiffSplitsIntoTheFileAndTheExcerpt() {
        let edit = PermissionPrompt(tool: "Update", detail: "a.py\n 1 +x\n 2 -y", title: "Do you want to make this edit to a.py?", options: P.oneOff.options, cursorIndex: 1)
        #expect(edit.detailParts.headline == "a.py")
        #expect(edit.detailParts.body == " 1 +x\n 2 -y")
        #expect(edit.isFileEdit)
        #expect(P.bash.detailParts.body == nil)
        #expect(!P.bash.isFileEdit)
    }
}
