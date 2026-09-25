import Foundation
import Testing
import CommandBarKit
@testable import AgentBar

/// `AgentListScrollTarget` — where `AgentListView` scrolls on selection change so a selected
/// worker's chief anchor and section header stay visible instead of being pushed off the top
/// (2026-09-25, fixing a launch bug: the first selectable row was a chief's first child, scrolled
/// flush to the top, hiding "Needs you" and the dimmed chief placeholder above it). Pure — rows are
/// hand-built `AgentListRow` values, no `AgentListGrouping`/tree/snapshot machinery needed.
@MainActor
struct AgentListScrollTargetTests {
    typealias F = AgentListFixtures

    private func placeholder(_ chiefID: String, section: AgentSection = .working) -> AgentTreeNode {
        AgentTreeNode(
            id: chiefID, label: chiefID, project: "proj", projectRoot: nil, machine: "local", paneId: "w1:\(chiefID)",
            alive: true, status: nil, crossProject: false, isChiefMode: true
        )
    }

    // MARK: - Rule 1: selection is the list's first selectable row -> scroll to the very top

    @Test func firstSelectableChildInTheWholeListScrollsToTheHeaderAboveItsPlaceholder() {
        // section header, dimmed chief placeholder (not selectable), then the first child selected.
        let rows: [AgentListRow] = [
            .header(.needsYou),
            .chiefPlaceholder(placeholder("c"), section: .needsYou, needsYouHint: 0),
            .agent(F.agent("w", section: .needsYou), nesting: .child(crossProject: false, machineBadge: nil))
        ]
        #expect(AgentListScrollTarget.id(forSelecting: "w", in: rows) == "section-0")
    }

    @Test func selectingTheChiefsOwnRowWhenItsTheFirstSelectableRowScrollsToTheHeader() {
        // The chief's real row is itself selectable, so IT is the list's first selectable row here
        // (not its child) — rule 1 applies to the chief, not rule 2 to the child below it.
        let rows: [AgentListRow] = [
            .header(.working),
            .agent(F.agent("c", section: .working), nesting: .chief(needsYouHint: 0, machineBadge: nil)),
            .agent(F.agent("w", section: .working), nesting: .child(crossProject: false, machineBadge: nil))
        ]
        #expect(AgentListScrollTarget.id(forSelecting: "c", in: rows) == "section-1")
        // Its child isn't the first selectable row (the chief above it is), so it falls to rule 2
        // instead and reveals the chief's own row rather than jumping past it to the header.
        #expect(AgentListScrollTarget.id(forSelecting: "w", in: rows) == "agent-c")
    }

    @Test func firstSelectableRowThatIsLooseStillScrollsToTheHeader() {
        let rows: [AgentListRow] = [
            .header(.working),
            .agent(F.agent("loose", section: .working), nesting: .loose(lostParentLabel: nil, machineBadge: nil))
        ]
        #expect(AgentListScrollTarget.id(forSelecting: "loose", in: rows) == "section-1")
    }

    // MARK: - Rule 2: a later child scrolls to its group's anchor, not its own row

    @Test func aChildAfterOtherRowsScrollsToItsChiefPlaceholderAnchor() {
        let rows: [AgentListRow] = [
            .header(.needsYou),
            .agent(F.agent("loose", section: .needsYou), nesting: .loose(lostParentLabel: nil, machineBadge: nil)),
            .chiefPlaceholder(placeholder("c"), section: .needsYou, needsYouHint: 0),
            .agent(F.agent("w1", section: .needsYou), nesting: .child(crossProject: false, machineBadge: nil)),
            .agent(F.agent("w2", section: .needsYou), nesting: .child(crossProject: false, machineBadge: nil))
        ]
        // w2 is the SECOND child in its group, not the list's first selectable row (that's "loose").
        #expect(AgentListScrollTarget.id(forSelecting: "w2", in: rows) == "chief-placeholder-0-c")
    }

    @Test func aChildAfterOtherRowsScrollsToItsChiefsRealRowAnchor() {
        let rows: [AgentListRow] = [
            .header(.working),
            .agent(F.agent("loose", section: .working), nesting: .loose(lostParentLabel: nil, machineBadge: nil)),
            .agent(F.agent("c", section: .working), nesting: .chief(needsYouHint: 0, machineBadge: nil)),
            .agent(F.agent("w1", section: .working), nesting: .child(crossProject: false, machineBadge: nil)),
            .agent(F.agent("w2", section: .working), nesting: .child(crossProject: false, machineBadge: nil))
        ]
        #expect(AgentListScrollTarget.id(forSelecting: "w2", in: rows) == "agent-c")
    }

    // MARK: - Unaffected rows: chief / loose / non-first still scroll to their own row

    @Test func selectingAChiefsOwnRowScrollsToItself() {
        let rows: [AgentListRow] = [
            .header(.working),
            .agent(F.agent("loose", section: .working), nesting: .loose(lostParentLabel: nil, machineBadge: nil)),
            .agent(F.agent("c", section: .working), nesting: .chief(needsYouHint: 0, machineBadge: nil)),
            .agent(F.agent("w", section: .working), nesting: .child(crossProject: false, machineBadge: nil))
        ]
        #expect(AgentListScrollTarget.id(forSelecting: "c", in: rows) == "agent-c")
    }

    @Test func selectingALooseRowThatIsNotFirstScrollsToItself() {
        let rows: [AgentListRow] = [
            .header(.working),
            .agent(F.agent("first", section: .working), nesting: .loose(lostParentLabel: nil, machineBadge: nil)),
            .agent(F.agent("second", section: .working), nesting: .loose(lostParentLabel: nil, machineBadge: nil))
        ]
        #expect(AgentListScrollTarget.id(forSelecting: "second", in: rows) == "agent-second")
    }

    @Test func unknownAgentIDReturnsNil() {
        let rows: [AgentListRow] = [.header(.working)]
        #expect(AgentListScrollTarget.id(forSelecting: "ghost", in: rows) == nil)
    }
}
