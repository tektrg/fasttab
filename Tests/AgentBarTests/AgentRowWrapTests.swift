import CoreGraphics
import Testing
@testable import AgentBar

/// The status line (recap, question asked…) wraps in full; the row and the window grow with it.
struct AgentRowWrapTests {
    typealias F = AgentListFixtures

    private static let recap = "recap: We're making value-focused App Store banners, starting with Parklet's "
        + "\"message about how much time you save every single week\" and then the other apps in the portfolio, "
        + "each one with its own headline, subtitle and a short line under the screenshot so the story reads at a glance."

    @Test func aShortStatusKeepsTheOriginalRowHeight() {
        let agent = F.agent("a", statusText: "waiting")
        #expect(AgentRowMetrics.height(of: agent, nesting: .flat) == AgentPanelMetrics.rowHeight)
    }

    @Test func aLongRecapWrapsAndTheRowGrows() {
        let agent = F.agent("a", statusText: Self.recap)
        #expect(AgentRowMetrics.statusLineCount(Self.recap, nesting: .flat) >= 2)
        #expect(AgentRowMetrics.height(of: agent, nesting: .flat) > AgentPanelMetrics.rowHeight)
    }

    @Test func aNestedRowWrapsNoLaterThanAFlatOne() {
        let flat = AgentRowMetrics.statusLineCount(Self.recap, nesting: .flat)
        let child = AgentRowMetrics.statusLineCount(Self.recap, nesting: .child(crossProject: false, machineBadge: nil))
        #expect(child >= flat)
    }

    @Test func theListHeightCountsTheWrappedRows() {
        let plain = F.presentation(F.snapshot([F.agent("a"), F.agent("b")]))
        let wrapped = F.presentation(F.snapshot([F.agent("a", statusText: Self.recap), F.agent("b")]))
        #expect(AgentPanelMetrics.height(for: wrapped) > AgentPanelMetrics.height(for: plain))
    }

    @Test func aLongStatusIsNotCutWithAnEllipsisAnyMore() {
        let long = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)   // 199 chars
        #expect(StatusTextCleaner.singleLine(long, maxLength: LiveAgentMapper.statusTextMaxLength) == long)
    }
}
