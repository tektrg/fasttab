import Testing
import IndieEdgeReveal
@testable import AgentBar

struct ShortcutsSettingsTests {
    @Test func footnoteNamesTheSpotAndSaysWhenHoverNeedsTheCornerTab() {
        let on = ShortcutsSettingsView.hoverFootnote(spot: .topLeftCorner, cornerTabOn: true)
        #expect(on.contains("top-left corner"))
        let tabOff = ShortcutsSettingsView.hoverFootnote(spot: .bottomRightCorner, cornerTabOn: false)
        #expect(tabOff.contains("needs the corner tab"))
        let hoverOff = ShortcutsSettingsView.hoverFootnote(spot: .off, cornerTabOn: true)
        #expect(hoverOff.contains("bottom-right"))
    }
}
