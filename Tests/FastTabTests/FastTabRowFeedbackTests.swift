import Foundation
import IndieCommandBar
import Testing
@testable import FastTab

/// Gap 8: Fast Tab's three row-action failures go to the persistent error notice
/// (they used to flash as a green-tick toast); successes stay toasts.
struct FastTabRowFeedbackTests {
    @Test func sendToListFailureIsAPersistentError() {
        #expect(FastTabRowFeedback.sendToList(saved: true) == .toast("Sent to FastTab List"))
        #expect(FastTabRowFeedback.sendToList(saved: false) == .error("Can't add this link"))
        #expect(FastTabRowFeedback.cannotAddLink == .error("Can't add this link"))
    }

    @Test func moveToBookmarksFailureIsAPersistentError() {
        #expect(FastTabRowFeedback.moveToBookmarks(folderLabel: "Reading") == .toast("Moved to Reading"))
        #expect(FastTabRowFeedback.moveToBookmarks(folderLabel: nil) == .error("Couldn't add the bookmark"))
    }

    @Test func escClosesTheNoticeFirstThenFallsThrough() {
        var slot = CommandBarErrorNoticeSlot<String>()
        slot.show("Can't add this link")
        let first = slot.dismiss()
        let second = slot.dismiss()
        #expect(first)
        #expect(!second)
    }

    @Test func noticeAreaCountsAsInsideTheBar() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let notice = CGRect(x: 300, y: 100, width: 360, height: 40)   // 100pt from the window top
        #expect(FastTabErrorNoticeHit.screenRect(of: notice, windowFrame: window) == CGRect(x: 300, y: 660, width: 360, height: 40))
        #expect(FastTabErrorNoticeHit.contains(CGPoint(x: 320, y: 680), noticeInWindow: notice, windowFrame: window))
        #expect(!FastTabErrorNoticeHit.contains(CGPoint(x: 320, y: 120), noticeInWindow: notice, windowFrame: window))
        #expect(!FastTabErrorNoticeHit.contains(CGPoint(x: 320, y: 680), noticeInWindow: nil, windowFrame: window))
    }
}
