import AppKit
import Foundation
import JavaScriptCore

/// Mermaid source → themed image, with no web view.
///
/// Same engine as the portfolio's web apps (SpeechToDo / mdly via `@tektrg/diagram-kit`): **pele 1.6.0**
/// (MIT, obsidianmd/pele), a sync, DOM-free Mermaid renderer. Its ESM build is bundled once into an IIFE
/// (`Markdown/Resources/pele.min.js`, global `Pele`, ~650 KB) and run in one JavaScriptCore context;
/// the SVG it returns is drawn by AppKit's own SVG support (`NSImage(data:)`). Offline: nothing is fetched.
///
/// pele colours through `--pele-*` CSS variables, which CoreSVG does not resolve, so `themed(_:dark:)`
/// substitutes concrete colours per theme. Results are cached (SVG per source, image per source+theme),
/// so a diagram is laid out once per message no matter how often SwiftUI redraws.
enum MermaidRenderer {
    enum Outcome: Equatable {
        case image(NSImage, size: CGSize)
        /// pele rejected the source (or the engine is missing) → caller draws the code tile.
        case failure(String)

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            switch (lhs, rhs) {
            case let (.image(a, s1), .image(b, s2)): a === b && s1 == s2
            case let (.failure(a), .failure(b)): a == b
            default: false
            }
        }
    }

    /// Larger sources are not rendered (shown as code) — keeps a pathological message cheap.
    static let maxSourceCharacters = 8_000

    /// Draw `source` for the given theme. Synchronous (first call also boots the JS engine, ~tens of ms;
    /// later renders take a few ms), so the final height is known on the first layout pass.
    static func render(_ source: String, dark: Bool) -> Outcome {
        let key = "\(dark ? "d" : "l")|\(source)" as NSString
        lock.lock(); defer { lock.unlock() }
        if let hit = imageCache.object(forKey: key) { return hit.outcome }
        let outcome: Outcome
        switch svgLocked(source) {
        case .failure(let error): outcome = .failure(error.message)
        case .success(let svg):
            if let data = themed(svg, dark: dark).data(using: .utf8), let image = NSImage(data: data),
               image.size.width > 0, image.size.height > 0 {
                outcome = .image(image, size: image.size)
            } else {
                outcome = .failure("Diagram could not be drawn.")
            }
        }
        imageCache.setObject(Box(outcome), forKey: key)
        return outcome
    }

    /// Raw pele SVG (or its error). Exposed for tests.
    static func svg(_ source: String) -> Result<String, RenderError> {
        lock.lock(); defer { lock.unlock() }
        return svgLocked(source)
    }

    struct RenderError: Error, Equatable { let message: String }

    // MARK: - Theme

    /// Concrete colours for pele's private `--_x` variables. Picked to sit on the diagram tile
    /// (`tileColor`) in both the panel cards and the Focus overlay.
    static func palette(dark: Bool) -> [String: String] {
        dark
            ? ["_bg": "#2B2B2B", "_fg": "#ECECEC", "_m": "#9A9A9A", "_l": "#B8B8B8", "_s": "#383838",
               "_a": "#424242", "_b": "#7A7A7A", "_c": "#7F9CF0"]
            : ["_bg": "#F2F2F0", "_fg": "#1F1F1F", "_m": "#6E6E6E", "_l": "#4A4A4A", "_s": "#FFFFFF",
               "_a": "#E6E6E6", "_b": "#9A9A9A", "_c": "#5B7BD5"]
    }

    static func tileColor(dark: Bool) -> NSColor {
        NSColor(hex: palette(dark: dark)["_bg"]!) ?? .windowBackgroundColor
    }

    /// pele SVG → SVG CoreSVG can draw: CSS variables replaced by colours, root style simplified.
    static func themed(_ svg: String, dark: Bool) -> String {
        var out = svg
        // Root element: drop the variable definitions + `max-width:100%` (sizing is SwiftUI's job).
        if let range = out.range(of: #"style="max-width[^"]*""#, options: .regularExpression) {
            out.replaceSubrange(range, with: #"style="font-family:Arial,Helvetica,sans-serif""#)
        }
        out = splitTspans(out)
        out = out.replacingOccurrences(of: #"style="rx:var(--_r)""#, with: #"rx="4""#)
        out = out.replacingOccurrences(of: "var(--_fm)", with: "Menlo")
        out = out.replacingOccurrences(of: "var(--_r)", with: "4px")
        for (name, color) in palette(dark: dark) {
            out = out.replacingOccurrences(of: "var(--\(name))", with: color)
        }
        // Anything else (`var(--pele-series-3,#abc)` in charts) → its own fallback value.
        out = out.replacingOccurrences(of: #"var\(--[A-Za-z0-9_-]+,\s*([^()]+)\)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"var\(--[A-Za-z0-9_-]+\)"#, with: palette(dark: dark)["_fg"]!, options: .regularExpression)
        return out
    }

    /// CoreSVG ignores `x`/`y` on `<tspan>`, so pele's multi-line labels (`<br/>`) collapse onto one
    /// line. Each positioned tspan becomes its own `<text>` with the parent's attributes.
    static func splitTspans(_ svg: String) -> String {
        guard svg.contains("<tspan"),
              let textRegex = try? NSRegularExpression(pattern: #"<text([^>]*)>((?:<tspan[^>]*>[^<]*</tspan>)+)</text>"#),
              let spanRegex = try? NSRegularExpression(pattern: #"<tspan([^>]*)>([^<]*)</tspan>"#) else { return svg }
        let ns = svg as NSString
        var out = ""
        var last = 0
        for match in textRegex.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let attrs = ns.substring(with: match.range(at: 1))
            let inner = ns.substring(with: match.range(at: 2)) as NSString
            for span in spanRegex.matches(in: inner as String, range: NSRange(location: 0, length: inner.length)) {
                out += "<text\(attrs)\(inner.substring(with: span.range(at: 1)))>\(inner.substring(with: span.range(at: 2)))</text>"
            }
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: - Engine

    private final class Box { let outcome: Outcome; init(_ o: Outcome) { outcome = o } }
    private static let lock = NSLock()
    nonisolated(unsafe) private static let imageCache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64   // images are small (a few hundred KB decoded at most)
        return cache
    }()
    nonisolated(unsafe) private static var context: JSContext?
    nonisolated(unsafe) private static var engineMissing = false
    nonisolated(unsafe) private static var counter = 0

    /// Where `pele.min.js` sits: SwiftPM's resource bundle (`FastTabPackage_AgentBar.bundle`) next to the binary (tests, `swift run`) or,
    /// in the shipped app, in `Contents/Resources` (copied by `scripts/build-agentbar-app.sh`). Never
    /// `Bundle.module`: its accessor traps when the bundle is missing.
    /// SwiftPM names it `<package>_<target>.bundle`; the package is `FastTabPackage`.
    static let resourceBundleNames = ["FastTabPackage_AgentBar.bundle", "AgentBar_AgentBar.bundle"]

    static func scriptURL() -> URL? {
        var roots: [URL] = []
        if let res = Bundle.main.resourceURL { roots.append(res) }
        roots.append(Bundle.main.bundleURL)
        roots.append(Bundle.main.bundleURL.deletingLastPathComponent())
        roots.append(Bundle(for: Box.self).bundleURL.deletingLastPathComponent())   // tests: next to the .xctest
        for bundle in Bundle.allBundles { roots.append(bundle.bundleURL.deletingLastPathComponent()) }
        for root in roots {
            for name in resourceBundleNames {
                for sub in ["Contents/Resources/pele.min.js", "pele.min.js"] {
                    let url = root.appendingPathComponent(name).appendingPathComponent(sub)
                    if FileManager.default.fileExists(atPath: url.path) { return url }
                }
            }
        }
        return nil
    }

    private static func engineLocked() -> JSContext? {
        if let context { return context }
        if engineMissing { return nil }
        guard let url = scriptURL(), let script = try? String(contentsOf: url, encoding: .utf8),
              let made = JSContext() else { engineMissing = true; return nil }
        made.evaluateScript(script)
        guard made.objectForKeyedSubscript("Pele")?.isUndefined == false else { engineMissing = true; return nil }
        context = made
        return made
    }

    nonisolated(unsafe) private static var svgCache: [String: Result<String, RenderError>] = [:]

    private static func svgLocked(_ source: String) -> Result<String, RenderError> {
        if let hit = svgCache[source] { return hit }
        let result = computeSVG(source)
        if svgCache.count > 64 { svgCache.removeAll() }
        svgCache[source] = result
        return result
    }

    private static func computeSVG(_ source: String) -> Result<String, RenderError> {
        guard source.count <= maxSourceCharacters else { return .failure(RenderError(message: "Diagram too large to draw.")) }
        guard let js = engineLocked() else { return .failure(RenderError(message: "Diagram engine unavailable.")) }
        counter += 1
        js.exception = nil
        js.setObject(source, forKeyedSubscript: "__agentbarSource" as NSString)
        js.setObject("ab\(counter)-", forKeyedSubscript: "__agentbarPrefix" as NSString)
        let value = js.evaluateScript("""
            (function(){ try { return { svg: Pele.render(__agentbarSource, { idPrefix: __agentbarPrefix }).svg }; }
                         catch (e) { return { error: String(e && e.message || e) }; } })()
            """)
        if let svg = value?.objectForKeyedSubscript("svg"), svg.isString, let text = svg.toString(), text.hasPrefix("<svg") {
            return .success(text)
        }
        let message = value?.objectForKeyedSubscript("error")?.toString() ?? js.exception?.toString() ?? "Unknown diagram error."
        return .failure(RenderError(message: message))
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
