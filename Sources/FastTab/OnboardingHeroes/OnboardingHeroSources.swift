import SwiftUI
import HeroMotion

/// Step 3: one tile per source app. Enabled apps stream tab chips down into
/// a single search field; disabled apps stay dimmed and send nothing.
/// Toggling a source replays it; loops while on screen.
struct OnboardingHeroSources: View {
    let state: SourcesHeroState

    var body: some View {
        OnboardingHeroStage(playback: state.playback, replayKey: state) { time in
            Self.frame(state: state, time: time)
        }
    }

    private enum Layout {
        static let tileSize = 24.0
        static let tileTop = 2.0
        static let chipSize = CGSize(width: 18, height: 8)
        static let chipsPerSource = 3
        static let field = CGRect(x: 30, y: 70, width: 140, height: 20)
        static let streamStart = 0.2
        static let chipStagger = 0.3
        static let sourceStagger = 0.08
        static let chipFlight = 0.6
        static let fieldLightsUp = 1.9
    }

    private static var sources: [SearchSource] { SearchSource.allCases }

    private static func tileCenterX(_ index: Int) -> Double {
        let pitch = HeroCanvas.size.width / Double(sources.count)
        return pitch * (Double(index) + 0.5)
    }

    static func frame(state: SourcesHeroState, time: Double) -> some View {
        let fade = HeroCurve.loopFade(time, playback: state.playback)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(sources.enumerated()), id: \.element) { index, source in
                tile(source, isEnabled: state.isEnabled(source))
                    .position(x: tileCenterX(index), y: Layout.tileTop + Layout.tileSize / 2)
                if state.isEnabled(source) {
                    ForEach(0..<Layout.chipsPerSource, id: \.self) { chipIndex in
                        chip(source, sourceIndex: index, chipIndex: chipIndex, time: time)
                            .opacity(fade)
                    }
                }
            }
            field(state: state, time: time)
                .heroPlaced(in: Layout.field)
        }
    }

    @ViewBuilder
    private static func appIcon(_ source: SearchSource, size: Double) -> some View {
        if let image = source.appIconImage {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: source.symbolName)
                .font(.system(size: size * 0.7))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    private static func tile(_ source: SearchSource, isEnabled: Bool) -> some View {
        appIcon(source, size: Layout.tileSize)
            .saturation(isEnabled ? 1 : 0)
            .opacity(isEnabled ? 1 : 0.3)
    }

    /// A tab chip falling from its app's tile into the field.
    private static func chip(_ source: SearchSource, sourceIndex: Int, chipIndex: Int, time: Double) -> some View {
        let start = Layout.streamStart + Double(chipIndex) * Layout.chipStagger + Double(sourceIndex) * Layout.sourceStagger
        let flight = HeroCurve.progress(time, start: start, duration: Layout.chipFlight, ease: .easeInOut)
        let from = CGPoint(x: tileCenterX(sourceIndex), y: Layout.tileTop + Layout.tileSize + 4)
        let to = CGPoint(x: Layout.field.midX, y: Layout.field.midY)
        let isFlying = flight > 0 && flight < 1
        return HStack(spacing: 2) {
            appIcon(source, size: 6)
            HeroTextLine(width: 7, height: 2)
        }
        .frame(width: Layout.chipSize.width, height: Layout.chipSize.height)
        .heroPanel(cornerRadius: 2.5)
        .scaleEffect(HeroCurve.lerp(1, 0.6, flight))
        .opacity(isFlying ? min(flight * 5, (1 - flight) * 5, 1) : 0)
        .position(x: HeroCurve.lerp(from.x, to.x, flight), y: HeroCurve.lerp(from.y, to.y, flight))
    }

    private static func field(state: SourcesHeroState, time: Double) -> some View {
        let lit = HeroCurve.progress(time, start: Layout.fieldLightsUp, duration: 0.3)
        let count = state.enabledSources.count
        return HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(state.enabledSources.enumerated()), id: \.element) { index, source in
                let pop = HeroCurve.progress(time, start: Layout.fieldLightsUp + 0.06 * Double(index), duration: 0.3, ease: .spring)
                appIcon(source, size: 10)
                    .scaleEffect(pop)
                    .opacity(min(pop * 2, 1))
            }
            Spacer(minLength: 0)
            Text(count == 1 ? "1 source" : "\(count) sources")
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(lit)
        }
        .padding(.horizontal, 6)
        .heroPanel(cornerRadius: 6)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.6 * lit), lineWidth: 1)
        )
    }
}
