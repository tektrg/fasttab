import SwiftUI
import HeroMotion

/// Step 1: the app icon drops in, a command bar unfolds, four tab rows
/// cascade in, "git" is typed, the list filters to two matches and the top
/// one is selected. Loops while the step is on screen.
struct OnboardingHeroWelcome: View {
    var body: some View {
        OnboardingHeroStage(playback: WelcomeHero.playback) { time in
            Self.frame(time)
        }
    }

    private enum Layout {
        static let iconOrigin = CGPoint(x: 6, y: 8)
        static let iconSize = 30.0
        static let barOrigin = CGPoint(x: 44, y: 4)
        static let barSize = CGSize(width: 152, height: 88)
        static let rowTop = 20.0
        static let rowPitch = 16.0
        static let query = "git"
        static let firstKeystroke = 1.3
        static let keystrokeGap = 0.12
        static let filterStart = 1.7
        static let selectStart = 2.2
    }

    /// Four tabs; two match "git".
    private struct SampleTab {
        let favicon: Color
        let titleWidth: Double
        let matchesQuery: Bool
    }

    private static let tabs = [
        SampleTab(favicon: HeroInk.favicons[0], titleWidth: 70, matchesQuery: true),
        SampleTab(favicon: HeroInk.favicons[1], titleWidth: 54, matchesQuery: false),
        SampleTab(favicon: HeroInk.favicons[2], titleWidth: 62, matchesQuery: true),
        SampleTab(favicon: HeroInk.favicons[3], titleWidth: 46, matchesQuery: false),
    ]

    static func frame(_ time: Double) -> some View {
        let fade = HeroCurve.loopFade(time, playback: WelcomeHero.playback)
        let drop = HeroCurve.progress(time, start: 0, duration: 0.45, ease: .spring)
        let unfold = HeroCurve.progress(time, start: 0.4, duration: 0.4, ease: .spring)
        return ZStack(alignment: .topLeading) {
            HeroAppIcon(size: Layout.iconSize)
                .offset(y: (drop - 1) * 18)
                .opacity(min(drop * 2, 1) * fade)
                .heroPlaced(x: Layout.iconOrigin.x, y: Layout.iconOrigin.y, width: Layout.iconSize, height: Layout.iconSize)
            bar(time: time)
                .scaleEffect(x: 1, y: HeroCurve.lerp(0.15, 1, unfold), anchor: .top)
                .opacity(min(unfold * 3, 1) * fade)
                .heroPlaced(x: Layout.barOrigin.x, y: Layout.barOrigin.y, width: Layout.barSize.width, height: Layout.barSize.height)
        }
    }

    private static func typedQuery(at time: Double) -> String {
        let typed = Int(((time - Layout.firstKeystroke) / Layout.keystrokeGap).rounded(.down)) + 1
        return String(Layout.query.prefix(max(0, min(typed, Layout.query.count))))
    }

    private static func bar(time: Double) -> some View {
        let filter = HeroCurve.progress(time, start: Layout.filterStart, duration: 0.4)
        let select = HeroCurve.progress(time, start: Layout.selectStart, duration: 0.2)
        // A quick brighter pulse right after selecting: "switched".
        let flash = HeroCurve.progress(time, start: 2.4, duration: 0.12) - HeroCurve.progress(time, start: 2.52, duration: 0.25)
        return ZStack(alignment: .topLeading) {
            HeroSearchField(query: typedQuery(at: time), showsCaret: time >= 0.8)
                .padding(.horizontal, 3)
                .offset(y: 3)
            ForEach(tabs.indices, id: \.self) { index in
                let tab = tabs[index]
                let cascade = HeroCurve.progress(time, start: 0.7 + 0.06 * Double(index), duration: 0.3, ease: .easeOut)
                let matchIndex = tabs[..<index].filter(\.matchesQuery).count
                let filteredY = Layout.rowTop + Double(matchIndex) * Layout.rowPitch
                let startY = Layout.rowTop + Double(index) * Layout.rowPitch
                let isTopMatch = index == 0
                HeroTabRow(
                    favicon: tab.favicon,
                    titleWidth: tab.titleWidth,
                    highlight: isTopMatch ? min(select + max(flash, 0) * 0.8, 1.6) : 0
                )
                .padding(.horizontal, 3)
                .offset(x: (1 - cascade) * -8, y: tab.matchesQuery ? HeroCurve.lerp(startY, filteredY, filter) : startY)
                .opacity(cascade * (tab.matchesQuery ? 1 : 1 - filter))
            }
        }
        .frame(width: Layout.barSize.width, height: Layout.barSize.height, alignment: .topLeading)
        .heroPanel()
    }
}
