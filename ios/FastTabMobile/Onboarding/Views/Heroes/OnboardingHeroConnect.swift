import SwiftUI

/// Step 2: a live picture of the Mac search, driven by `ConnectHeroState`.
/// Searching loops radar rings from the iPhone; every other state plays a
/// short one-shot and rests on its final frame.
struct OnboardingHeroConnect: View {
    let state: ConnectHeroState

    private enum Layout {
        static let phoneSize = CGSize(width: 36, height: 72)
        static let macSize = CGSize(width: 54, height: 34)
        static let centerY = 60.0
        static let phoneSearchingX = 90.0
        static let phoneAsideX = 48.0
        static let macRestX = 134.0
        static let macOffstageX = 214.0
        static let linkStartX = 68.0
        static let linkEndX = 106.0
        static let ringPeriod = 2.4
        static let ringCount = 3
    }

    var body: some View {
        OnboardingHeroStage(playback: state.playback, replayKey: state) { time in
            ZStack(alignment: .topLeading) {
                rings(time: time)
                if state != .searching {
                    link(time: time)
                    partner(time: time)
                }
                HeroPhone(width: Layout.phoneSize.width, height: Layout.phoneSize.height)
                    .position(x: phoneX(time: time), y: Layout.centerY)
                if state == .found {
                    HeroSuccessCheck()
                        .scaleEffect(HeroCurve.progress(time, start: 1.3, duration: 0.4, ease: .spring))
                        .position(x: (Layout.linkStartX + Layout.linkEndX) / 2, y: Layout.centerY)
                }
            }
        }
    }

    // MARK: - Beats

    /// When the phone steps aside and the Mac (or iCloud) slides in.
    private var slideStart: Double {
        switch state {
        case .searching: return 0
        case .found: return 0.35
        case .notFound: return 0.5
        case .macOffline, .accountBlocked: return 0.2
        }
    }

    private func slide(_ time: Double) -> Double {
        state == .searching ? 0 : HeroCurve.progress(time, start: slideStart, duration: 0.5, ease: .spring)
    }

    private func phoneX(time: Double) -> Double {
        HeroCurve.lerp(Layout.phoneSearchingX, Layout.phoneAsideX, slide(time))
    }

    /// Searching rings, or what is left of them as another state takes over:
    /// "not found" fades them slowly, the rest collapse them into the phone.
    private func rings(time: Double) -> some View {
        let collapse = HeroCurve.progress(time, start: 0, duration: 0.35, ease: .easeInOut)
        let fade = HeroCurve.progress(time, start: 0, duration: 0.8)
        let searchingTime = state == .searching ? time : 0
        return ZStack {
            ForEach(0..<Layout.ringCount, id: \.self) { index in
                let phase = (searchingTime / Layout.ringPeriod + Double(index) / Double(Layout.ringCount))
                    .truncatingRemainder(dividingBy: 1)
                let diameter = HeroCurve.lerp(40, 118, phase)
                // Strong, 2 pt accent strokes so the pulse reads in dark mode too.
                let strength = (1 - phase) * 0.85
                Circle()
                    .fill(DS.Tint.action.opacity(0.10 * strength))
                    .overlay(Circle().strokeBorder(DS.Tint.action.opacity(strength), lineWidth: 2))
                    .frame(width: diameter, height: diameter)
            }
        }
        .scaleEffect(state == .searching || state == .notFound ? 1 : 1 - collapse)
        .opacity(state == .notFound ? 1 - fade : state == .searching ? 1 : 1 - collapse)
        .position(x: Layout.phoneSearchingX, y: Layout.centerY)
    }

    @ViewBuilder
    private func link(time: Double) -> some View {
        let linkPath = Path { path in
            path.move(to: CGPoint(x: Layout.linkStartX, y: Layout.centerY))
            path.addLine(to: CGPoint(x: Layout.linkEndX, y: Layout.centerY))
        }
        switch state {
        case .found:
            linkPath
                .trim(from: 0, to: HeroCurve.progress(time, start: 0.85, duration: 0.45))
                .stroke(DS.Tint.success, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        case .macOffline:
            linkPath
                .stroke(HeroInk.deviceOutline, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 4]))
                .opacity(HeroCurve.progress(time, start: 0.7, duration: 0.4))
        case .searching, .notFound, .accountBlocked:
            EmptyView()
        }
    }

    /// What slides in beside the phone: a Mac in some look, or the iCloud glyph.
    @ViewBuilder
    private func partner(time: Double) -> some View {
        let partnerX = HeroCurve.lerp(Layout.macOffstageX, Layout.macRestX, slide(time))
        switch state {
        case .accountBlocked:
            blockedCloud(time: time)
                .position(x: partnerX, y: Layout.centerY)
        case .found, .macOffline, .notFound:
            mac(time: time)
                .position(x: partnerX, y: Layout.centerY)
        case .searching:
            EmptyView()
        }
    }

    private func mac(time: Double) -> some View {
        let look: HeroDeviceLook = state == .macOffline ? .dimmed : state == .notFound ? .dashed : .solid
        return HeroMac(width: Layout.macSize.width, height: Layout.macSize.height, look: look) {
            if state == .notFound {
                Text("?")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .scaleEffect(HeroCurve.progress(time, start: 1.0, duration: 0.4, ease: .spring))
            }
        }
        .overlay(alignment: .topTrailing) {
            if state == .macOffline {
                Image(systemName: "moon.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .offset(x: 8, y: -9)
                    .opacity(HeroCurve.progress(time, start: 0.7, duration: 0.4))
            }
        }
    }

    private func blockedCloud(time: Double) -> some View {
        let slash = Path { path in
            path.move(to: CGPoint(x: 8, y: 6))
            path.addLine(to: CGPoint(x: 48, y: 38))
        }
        return Image(systemName: "icloud")
            .font(.system(size: 42, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 56, height: 44)
            .overlay(
                slash
                    .trim(from: 0, to: HeroCurve.progress(time, start: 0.7, duration: 0.5))
                    .stroke(DS.Tint.warning, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            )
    }
}
