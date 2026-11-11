import CoreGraphics
import Foundation
import Testing
import IndieCommandBar
@testable import AgentBar

/// Slice 8b: Agent Bar's row buttons and panel placement on the shared IndieCommandBar pieces.
/// These pin the behaviour Agent Bar had before the move.
struct SharedRowButtonsAndAppearanceTests {
    // MARK: - Row buttons

    @Test func onlyTheButtonTheActionIsAboutLeavesIdle() {
        #expect(RowActionButtonView.phase(of: .done, state: nil) == .idle)
        #expect(RowActionButtonView.phase(of: .done, state: .busy(.done)) == .busy)
        #expect(RowActionButtonView.phase(of: .done, state: .confirming(.done, reason: "x")) == .confirming)
        #expect(RowActionButtonView.phase(of: .done, state: .completed(.done)) == .done)
        // Another button's press never blocks this one.
        #expect(RowActionButtonView.phase(of: .park, state: .busy(.done)) == .idle)
    }

    @Test func pressabilityMatchesTheOldButton() {
        // Old rule: ignored while its own request is in flight or done; a confirming press goes through.
        #expect(!RowActionButtonView.phase(of: .closePane, state: .busy(.closePane)).isPressable)
        #expect(!RowActionButtonView.phase(of: .closePane, state: .completed(.closePane)).isPressable)
        #expect(RowActionButtonView.phase(of: .closePane, state: .confirming(.closePane, reason: "")).isPressable)
    }

    @Test func wordsPerPhaseAreAgentBarsOwn() {
        let done = RowActionButtonView.titles(for: RowButtonSpec(button: .done, disabledReason: nil))
        #expect(done.title(for: .confirming) == "Confirm")
        #expect(done.title(for: .busy) == "Stopping…")
        #expect(done.title(for: .done) == "Stopped")
        let close = RowActionButtonView.titles(for: RowButtonSpec(button: .closePane, disabledReason: nil))
        #expect(close.title(for: .busy) == "Closing…")
        #expect(close.title(for: .done) == "Closed")
    }

    // MARK: - Appearance

    @Test func defaultIsBottomRightSizedToContent() {
        let settings = AgentListSettings.load(from: makeScratchDefaults())
        #expect(settings.placement == .bottomRight)
        #expect(settings.fitsContent)
        #expect(settings.maxVisibleRows == AgentPanelMetrics.defaultMaxVisibleRows)
    }

    @Test func oldRowsBeforeScrollingValueStillLoads() {
        let defaults = makeScratchDefaults()
        defaults.set(13, forKey: "listMaxVisibleRows")
        #expect(AgentListSettings.load(from: defaults).maxVisibleRows == 13)
    }

    @Test func placementAndSizeRoundTrip() {
        let defaults = makeScratchDefaults()
        var chosen = AgentListSettings.standard
        chosen.appearance = CommandBarAppearanceSettings(rowLimit: 10, placement: .topCenter, fitsContent: false)
        chosen.save(to: defaults)
        let loaded = AgentListSettings.load(from: defaults)
        #expect(loaded == chosen)
        #expect(loaded.placement == .topCenter)
        #expect(!loaded.fitsContent)
        #expect(loaded.maxVisibleRows == 10)
    }

    @Test func defaultFrameIsTheOldBottomRightFrame() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: AgentPanelMetrics.width, height: 300)
        let frame = AgentPanelPlacement.frame(size: size, in: screen)
        #expect(frame == CGRect(x: 1440 - 20 - size.width, y: 20, width: size.width, height: 300))
        let top = AgentPanelPlacement.frame(size: size, in: screen, placement: .topCenter)
        #expect(top.maxY == 900 - 20)
    }

    @Test func fixedHeightAlwaysUsesTheFullListHeight() {
        let empty = AgentListPresentation(state: .list, rows: [], showsBoardNote: false)
        let fit = AgentPanelMetrics.height(for: empty, maxListHeight: 400)
        let fixed = AgentPanelMetrics.height(for: empty, maxListHeight: 400, fitsContent: false)
        #expect(fixed > fit)
        #expect(fixed == AgentPanelMetrics.height(for: empty, maxListHeight: 400, isAnswering: true))
    }
}
