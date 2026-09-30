import AppKit
import IndieMotion
import SwiftUI
import Testing
@testable import FastTab

/// Renders every Mac onboarding hero at chosen times, light and dark, into
/// PNGs plus one contact sheet. A tool, not a check: it only runs when
/// `HERO_RENDER_OUT` is set (use `scripts/render-heroes.sh`).
/// `HERO_RENDER_TIMES` is a comma list of seconds or `settled` (the rest time).
@MainActor
struct HeroRenderSheet {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["HERO_RENDER_OUT"]

    @Test(.enabled(if: HeroRenderSheet.outDir != nil))
    func renderSheet() throws {
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let times = Self.requestedTimes()
        var sheetRows: [AnyView] = []

        for hero in Self.heroes {
            for scheme in [ColorScheme.light, .dark] {
                var cells: [AnyView] = []
                for time in times {
                    let seconds = time ?? hero.playback.restTime
                    let cell = Self.cell(hero.frame(seconds), scheme: scheme)
                    let label = time.map { String(format: "%.2f", $0) } ?? "settled"
                    try Self.writePNG(cell, scheme: scheme, to: out.appendingPathComponent("\(hero.name)-\(scheme == .dark ? "dark" : "light")-\(label).png"))
                    cells.append(AnyView(VStack(spacing: 2) {
                        cell
                        Text(label).font(.caption2).foregroundStyle(.secondary)
                    }))
                }
                sheetRows.append(AnyView(HStack(spacing: 8) {
                    Text("\(hero.name)\n\(scheme == .dark ? "dark" : "light")")
                        .font(.caption).frame(width: 110, alignment: .leading)
                    ForEach(cells.indices, id: \.self) { cells[$0] }
                }
                .padding(6)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)))
            }
        }

        let sheet = VStack(alignment: .leading, spacing: 4) {
            ForEach(sheetRows.indices, id: \.self) { sheetRows[$0] }
        }
        .padding(8)
        .background(Color.gray.opacity(0.3))
        try Self.writePNG(sheet, scheme: .light, to: out.appendingPathComponent("sheet.png"))
    }

    // MARK: - Heroes

    struct Hero {
        let name: String
        let playback: MotionPlayback
        let frame: (Double) -> AnyView
    }

    static let heroes: [Hero] = {
        let keys = ["⌥", "Space"]
        let trigger = TriggerHeroState.hover(.notch)
        let keyboard = TriggerHeroState.keyboard(keycaps: keys)
        let sources = SourcesHeroState(enabled: Set(SearchSource.allCases))
        return [
            Hero(name: "welcome", playback: WelcomeHero.playback) { AnyView(OnboardingHeroWelcome.frame($0)) },
            Hero(name: "trigger-hover", playback: trigger.playback) { AnyView(OnboardingHeroTrigger.frame(state: trigger, time: $0)) },
            Hero(name: "trigger-keyboard", playback: keyboard.playback) { AnyView(OnboardingHeroTrigger.frame(state: keyboard, time: $0)) },
            Hero(name: "sources", playback: sources.playback) { AnyView(OnboardingHeroSources.frame(state: sources, time: $0)) },
            Hero(name: "extension-teaching", playback: ExtensionHeroState.teaching.playback) { AnyView(OnboardingHeroExtension.frame(state: .teaching, time: $0)) },
            Hero(name: "extension-connected", playback: ExtensionHeroState.connected.playback) { AnyView(OnboardingHeroExtension.frame(state: .connected, time: $0)) },
            Hero(name: "safari-teaching", playback: SafariHeroState.teaching.playback) { AnyView(OnboardingHeroSafari.frame(state: .teaching, time: $0)) },
            Hero(name: "safari-granted", playback: SafariHeroState.granted.playback) { AnyView(OnboardingHeroSafari.frame(state: .granted, time: $0)) },
            Hero(name: "iphone-teaching", playback: IPhoneHeroState.teaching.playback) { AnyView(OnboardingHeroIPhone.frame(state: .teaching, time: $0)) },
            Hero(name: "iphone-connected", playback: IPhoneHeroState.connected.playback) { AnyView(OnboardingHeroIPhone.frame(state: .connected, time: $0)) },
            Hero(name: "shortcut", playback: ShortcutHeroKeycaps.playback) { AnyView(OnboardingHeroShortcut.frame(keycaps: keys, time: $0)) },
        ]
    }()

    // MARK: - Rendering

    /// `nil` means "settled" (the hero's rest time).
    static func requestedTimes() -> [Double?] {
        let raw = ProcessInfo.processInfo.environment["HERO_RENDER_TIMES"] ?? "0,0.5,1,1.5,settled"
        return raw.split(separator: ",").map { token in
            let text = token.trimmingCharacters(in: .whitespaces)
            return text == "settled" ? nil : Double(text)
        }
    }

    static func cell(_ frame: AnyView, scheme: ColorScheme) -> some View {
        frame
            .frame(width: HeroCanvas.size.width, height: HeroCanvas.size.height)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
            .environment(\.colorScheme, scheme)
    }

    static func writePNG(_ view: some View, scheme: ColorScheme, to url: URL) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        var data: Data?
        // AppKit dynamic colours resolve against the drawing appearance.
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation {
                data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            }
        }
        try #require(data).write(to: url)
    }
}
