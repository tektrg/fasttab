import SwiftUI
import UIKit

// FastTab mobile design tokens. Every color, spacing, radius, font and shadow a screen
// uses comes from here, so the app reads as one product. See `README.md` beside this
// file for when to use which token. Rule of thumb: if you are typing a number or an
// RGB value in a view, it belongs here instead.
public enum DS {

    // MARK: - Color

    /// Warm "paper" palette: stone-white canvas, white cards in light mode; a warm
    /// near-black canvas with charcoal cards in dark mode.
    public enum Palette {
        /// Behind everything: the page. Use `.dsCanvas()` rather than reading this.
        public static let canvasTop = dynamic(light: (0.988, 0.985, 0.980), dark: (0.045, 0.042, 0.040))
        public static let canvasBottom = dynamic(light: (0.955, 0.950, 0.942), dark: (0.0, 0.0, 0.0))
        public static let canvas = LinearGradient(
            colors: [canvasTop, canvasBottom], startPoint: .top, endPoint: .bottom
        )

        /// Cards, list rows, sheets resting on the canvas.
        public static let surface = dynamic(light: (1.0, 1.0, 1.0), dark: (0.095, 0.090, 0.086))
        /// Unselected chips, thumbnail placeholders, inset fields — a step darker than the canvas.
        public static let surfaceMuted = dynamic(light: (0.890, 0.880, 0.870), dark: (0.135, 0.128, 0.122))
        /// 1pt card outlines and dividers drawn on a surface.
        public static let hairline = Color.primary.opacity(0.07)

        /// Floating toast pill.
        public static let toastBackground = Color.black.opacity(0.85)
        /// Scrim under text laid over a photo.
        public static let imageScrim = Color.black.opacity(0.55)

        /// The Tab Switcher deck is a deliberate dark, immersive mode in both appearances.
        public static let deckTop = Color(red: 0.08, green: 0.10, blue: 0.15)
        public static let deckBottom = Color(red: 0.02, green: 0.03, blue: 0.06)

        /// Reader page behind the article text (#FAFAF8 / #141414). UIKit form for the web view.
        public static let readerPageUIColor = dynamicUIColor(light: (0.980, 0.980, 0.973), dark: (0.078, 0.078, 0.078))
        public static let readerPage = Color(uiColor: readerPageUIColor)

        static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
            Color(uiColor: dynamicUIColor(light: light, dark: dark))
        }

        static func dynamicUIColor(light: (Double, Double, Double), dark: (Double, Double, Double)) -> UIColor {
            UIColor { trait in
                let c = trait.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1.0)
            }
        }
    }

    /// Semantic tints: one meaning per hue, the same everywhere. Pair with `tintFill`
    /// for the soft background behind tinted text.
    public enum Tint {
        /// Default interactive color: primary buttons, links, "tab" things.
        public static let action = Color.accentColor
        /// AI / Emerging / Intelligence.
        public static let emerging = Color.purple
        /// Things opened or read on this iPhone.
        public static let recent = Color.teal
        /// Saved bookmarks. Gold, darkened in light mode so tag text stays readable on white.
        public static let bookmark = Palette.dynamic(light: (0.78, 0.53, 0.0), dark: (1.0, 0.80, 0.04))
        /// Links sent from the Share Sheet.
        public static let shared = Color.blue
        /// Stale data, pending confirmation, soft warnings.
        public static let warning = Color.orange
        /// Destructive, errors, live/recording.
        public static let destructive = Color.red
        /// Done, synced, confirmed.
        public static let success = Color.green
        /// Brand color of Reddit, used on Reddit post tiles.
        public static let reddit = Color(red: 1.0, green: 0.27, blue: 0.0)
    }

    /// Opacity of a tint when used as a fill behind same-tint text or icons.
    public static let tintFillOpacity: Double = 0.12

    // MARK: - Layout

    /// 4-pt grid. `gutter` is the page's left/right margin on every screen.
    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let gutter: CGFloat = 16
        /// Between the sections of a feed-style screen.
        public static let section: CGFloat = 24
        /// Clears the floating sub-tab bar at the bottom of Tabs / Bookmarks.
        public static let floatingBarClearance: CGFloat = 72
    }

    /// Corner radii, all drawn with `.continuous` curves. Pills and chips use `Capsule`.
    public enum Radius {
        /// Favicons, small inline images.
        public static let xs: CGFloat = 4
        /// Thumbnails nested inside a card, small tiles.
        public static let sm: CGFloat = 8
        /// Banners, strips, inline controls.
        public static let md: CGFloat = 12
        /// Cards.
        public static let lg: CGFloat = 16
        /// Hero cards: Random deck, Tab Switcher.
        public static let xl: CGFloat = 24
    }

    // MARK: - Type

    /// Dynamic Type text styles only, so every string scales with the user's text size.
    public enum Font {
        /// Large page headline inside content (not the nav bar).
        public static let display = SwiftUI.Font.title2.weight(.bold)
        /// "Recent Added", "Emerging" …
        public static let sectionTitle = SwiftUI.Font.title3.weight(.bold)
        /// Card title, prominent row title.
        public static let cardTitle = SwiftUI.Font.subheadline.weight(.semibold)
        public static let body = SwiftUI.Font.body
        /// Secondary line under a title: domain, author, subtitle.
        public static let meta = SwiftUI.Font.caption
        /// Tags, count pills, tiny labels.
        public static let tag = SwiftUI.Font.caption2.weight(.semibold)
        /// Filter chips and tinted capsule buttons.
        public static let control = SwiftUI.Font.footnote.weight(.semibold)
        /// Toast message.
        public static let toast = SwiftUI.Font.subheadline.weight(.medium)
    }

    /// Icon sizes for SF Symbols that are not inline with text.
    public enum IconSize {
        /// Leading icon in a list row or banner.
        public static let row: CGFloat = 16
        /// Icon inside an inline (card) empty state.
        public static let inline: CGFloat = 28
        /// Hero icon of a full-screen empty state.
        public static let hero: CGFloat = 44
    }

    // MARK: - Depth & motion

    public struct Shadow {
        public let color: Color
        public let radius: CGFloat
        public let y: CGFloat
        /// Resting card on the canvas: barely there, mostly for dark-on-light separation.
        public static let card = Shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        /// Floating things: toasts, action bars.
        public static let floating = Shadow(color: .black.opacity(0.18), radius: 10, y: 5)
    }

    public enum Motion {
        /// Selection changes, chip toggles.
        public static let quick = Animation.easeInOut(duration: 0.18)
        /// Toast in / out.
        public static let toast = Animation.easeInOut(duration: 0.2)
        /// How long a toast stays up.
        public static let toastDuration: Duration = .seconds(2.5)
    }
}

public extension View {
    func dsShadow(_ shadow: DS.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
    }
}
