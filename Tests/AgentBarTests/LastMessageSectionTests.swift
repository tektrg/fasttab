import AppKit
import SwiftUI
import Testing
@testable import AgentBar

/// The "Last message" fold: collapsed by default, and a collapsed fold is exactly one fixed row
/// whatever the message is doing. Heights are measured on the real hosted view, not assumed.
@MainActor @Suite(.serialized)
struct LastMessageSectionTests {
    private let longText = (1...30).map { "Line \($0) of a long, finished message from the agent." }.joined(separator: "\n\n")

    private func height(_ message: AnswerCard.Message, startsExpanded: Bool = false, dark: Bool = false) -> CGFloat {
        let host = NSHostingView(rootView:
            LastMessageSection(message: message, startsExpanded: startsExpanded)
                .frame(width: AgentPanelMetrics.width)
                .environment(\.colorScheme, dark ? .dark : .light)
        )
        host.frame = CGRect(x: 0, y: 0, width: AgentPanelMetrics.width, height: 2000)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test func startsCollapsedAsOneFixedRow() {
        #expect(height(.text(longText)) == LastMessageSection.collapsedHeight)
    }

    @Test func collapsedHeightIsTheSameWhileLoadingLoadedOrEmpty() {
        let loading = height(.loading)
        let loaded = height(.text(longText))
        let short = height(.text("ok"))
        let empty = height(.none)
        #expect(loading == LastMessageSection.collapsedHeight)
        #expect(loaded == loading)
        #expect(short == loading)
        #expect(empty == loading)
    }

    @Test func collapsedHeightIsTheSameInLightAndDark() {
        #expect(height(.text(longText), dark: true) == height(.text(longText), dark: false))
    }

    @Test func openingShowsTheContentBelowTheRow() {
        let collapsed = LastMessageSection.collapsedHeight
        #expect(height(.loading, startsExpanded: true) > collapsed)
        #expect(height(.text(longText), startsExpanded: true) > collapsed + LastMessageView.collapsedHeight / 2)
        #expect(height(.none, startsExpanded: true) > collapsed)
    }

    @Test func theMessageArrivingDoesNotMoveTheRowOrCloseAnOpenFold() {
        // Same view, message switched underneath (what a card does when the transcript is read):
        // the title row stays the first `titleRowHeight` points and an open fold stays open.
        final class Box: ObservableObject { @Published var message: AnswerCard.Message = .loading }
        struct Wrapper: View {
            @ObservedObject var box: Box
            var body: some View { LastMessageSection(message: box.message, startsExpanded: true).frame(width: AgentPanelMetrics.width) }
        }
        let box = Box()
        let host = NSHostingView(rootView: Wrapper(box: box))
        host.frame = CGRect(x: 0, y: 0, width: AgentPanelMetrics.width, height: 2000)
        host.layoutSubtreeIfNeeded()
        let loading = host.fittingSize.height
        box.message = .text(longText)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let loaded = host.fittingSize.height
        #expect(loading > LastMessageSection.collapsedHeight)   // open before…
        #expect(loaded > loading)                               // …and still open once the text lands
    }
}
