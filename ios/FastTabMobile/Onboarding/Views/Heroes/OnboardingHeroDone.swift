import SwiftUI

/// Step 5: a seal and its checkmark draw, then a mini tab bar rises and lights
/// Read, Tabs, Shuffle and More in turn, matching the tour rows below. Loops.
struct OnboardingHeroDone: View {
    static let playback = HeroPlayback.loop(period: 4.0, restAt: 3.0)

    /// Same symbols and tints as the tour rows, in the same order.
    private static let tabs: [(symbol: String, tint: Color)] = [
        ("newspaper", DS.Tint.emerging),
        ("macwindow.on.rectangle", DS.Tint.action),
        ("shuffle", DS.Tint.action),
        ("ellipsis.circle", DS.Tint.action),
    ]
    private static let sealCenter = CGPoint(x: 90, y: 38)
    private static let sealRadius = 26.0
    private static let firstTabLitAt = 1.3
    private static let tabLitSpacing = 0.4
    /// Built once: 145 trig samples are too many to redo every frame.
    private static let sealShape = sealPath(center: sealCenter, radius: sealRadius)
    private static let checkShape = checkPath(center: sealCenter)

    var body: some View {
        OnboardingHeroStage(playback: Self.playback) { time in
            ZStack(alignment: .topLeading) {
                seal(time: time)
                tabBar(time: time)
                    .heroPlaced(x: 14, y: 78, width: 152, height: 34)
            }
            .opacity(HeroCurve.loopFade(time, playback: Self.playback))
        }
    }

    private func seal(time: Double) -> some View {
        let ring = HeroCurve.progress(time, start: 0, duration: 0.5)
        let check = HeroCurve.progress(time, start: 0.5, duration: 0.4, ease: .easeOut)
        return ZStack {
            Self.sealShape.fill(DS.Tint.success.opacity(0.14 * ring))
            Self.sealShape
                .trim(from: 0, to: ring)
                .stroke(DS.Tint.success, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            Self.checkShape
                .trim(from: 0, to: check)
                .stroke(DS.Tint.success, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        }
    }

    private func tabBar(time: Double) -> some View {
        let rise = HeroCurve.progress(time, start: 0.9, duration: 0.4, ease: .spring)
        let bar = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 0) {
            ForEach(Self.tabs.indices, id: \.self) { index in
                tabItem(index, time: time)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .background(bar.fill(DS.Palette.surface))
        .overlay(bar.strokeBorder(HeroInk.deviceOutline.opacity(0.6), lineWidth: 1))
        .offset(y: (1 - rise) * 14)
        .opacity(min(rise, 1))
    }

    /// Each tab lifts and takes its tint for 0.4 s, one after another.
    private func tabItem(_ index: Int, time: Double) -> some View {
        let start = Self.firstTabLitAt + Self.tabLitSpacing * Double(index)
        let glow = sin(.pi * HeroCurve.progress(time, start: start, duration: Self.tabLitSpacing, ease: .linear))
        let spec = Self.tabs[index]
        let symbol = Image(systemName: spec.symbol).font(.system(size: 14, weight: .semibold))
        return VStack(spacing: 3) {
            symbol
                .foregroundStyle(.secondary)
                .overlay(symbol.foregroundStyle(spec.tint).opacity(glow))
            Circle().fill(spec.tint).frame(width: 4, height: 4).opacity(glow)
        }
        .offset(y: 3 - 3 * glow)
    }

    /// A scalloped badge outline, drawable with `trim`.
    private static func sealPath(center: CGPoint, radius: Double) -> Path {
        Path { path in
            let samples = 144
            let bumps = 12.0
            for step in 0...samples {
                let angle = Double(step) / Double(samples) * 2 * .pi - .pi / 2
                let wobble = radius + 2.2 * cos(bumps * angle)
                let point = CGPoint(x: center.x + wobble * cos(angle), y: center.y + wobble * sin(angle))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }

    private static func checkPath(center: CGPoint) -> Path {
        Path { path in
            path.move(to: CGPoint(x: center.x - 10, y: center.y + 1))
            path.addLine(to: CGPoint(x: center.x - 3, y: center.y + 8))
            path.addLine(to: CGPoint(x: center.x + 11, y: center.y - 8))
        }
    }
}
