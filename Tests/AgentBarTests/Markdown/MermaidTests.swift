import AppKit
import SwiftUI
import Testing
@testable import AgentBar

/// ```mermaid blocks: parser detection, pele render + fallback, size rule, and renders.
/// Renders: `FOCUS_RENDER_DIR=<dir> swift test --filter MermaidTests`.
@MainActor @Suite(.serialized)
struct MermaidTests {
    typealias F = AgentListFixtures

    static let howItWorks = """
        flowchart LR
          D[Draft] --> L[Phrase checker script<br/>AI patterns, gate words]
          D --> R1[Reviewer 1<br/>scorecard]
          R1 --> R2[Reviewer 2<br/>fresh eyes]
          L --> V{Verdict}
          R2 --> V
          V -->|PASS| O[Owner review in MDLY]
          V -->|REVISE| N[Next draft, never edited in place] --> D
        """

    static var message: String {
        "Below is the plan.\n\n## How it works\n\n```mermaid\n\(howItWorks)\n```\n\nAfter the diagram."
    }

    // MARK: Parser

    @Test func mermaidFenceBecomesMermaidBlock() {
        let blocks = MarkdownParser.parse("```mermaid\nflowchart TD\n  A --> B\n```")
        #expect(blocks == [.mermaid(source: "flowchart TD\n  A --> B")])
        #expect(MarkdownParser.parse("~~~ Mermaid\ngraph LR\nA-->B\n~~~") == [.mermaid(source: "graph LR\nA-->B")])
    }

    @Test func otherFencesStayCode() {
        #expect(MarkdownParser.parse("```swift\nlet a = 1\n```") == [.codeBlock(language: "swift", code: "let a = 1")])
        #expect(MarkdownParser.parse("```mermaidx\nA\n```") == [.codeBlock(language: "mermaidx", code: "A")])
        #expect(MarkdownParser.parse("```mermaid\n\n```") == [.codeBlock(language: "mermaid", code: "")])
    }

    // MARK: Renderer + fallback

    @Test func engineIsBundledAndRenders() throws {
        #expect(MermaidRenderer.scriptURL() != nil)
        let svg = try MermaidRenderer.svg(Self.howItWorks).get()
        #expect(svg.hasPrefix("<svg"))
        guard case .image(_, let size) = MermaidRenderer.render(Self.howItWorks, dark: true) else { Issue.record("no image"); return }
        #expect(size.width > 100 && size.height > 30)
    }

    @Test func badSourceFallsBack() {
        guard case .failure(let message) = MermaidRenderer.render("flowchart TD\n  A -->", dark: false) else {
            Issue.record("expected failure"); return
        }
        #expect(!message.isEmpty)
        if case .image = MermaidRenderer.render("not a diagram at all", dark: false) { Issue.record("expected failure") }
        let huge = "flowchart TD\n" + String(repeating: "A --> B\n", count: 2_000)
        if case .image = MermaidRenderer.render(huge, dark: false) { Issue.record("expected size cap") }
    }

    @Test func themeReplacesEveryVariable() throws {
        let svg = try MermaidRenderer.svg(Self.howItWorks).get()
        for dark in [false, true] {
            let themed = MermaidRenderer.themed(svg, dark: dark)
            #expect(!themed.contains("var("))
            #expect(themed.contains(MermaidRenderer.palette(dark: dark)["_fg"]!))
        }
    }

    @Test func renderIsCached() {
        guard case .image(let a, _) = MermaidRenderer.render(Self.howItWorks, dark: false),
              case .image(let b, _) = MermaidRenderer.render(Self.howItWorks, dark: false) else { Issue.record("no image"); return }
        #expect(a === b)
    }

    // MARK: Size rule

    @Test func fittedScalesDownNeverUp() {
        let natural = CGSize(width: 800, height: 200)
        // At 12pt the preferred size is 600×150.
        #expect(MermaidLayout.fitted(natural: natural, bodySize: 12, availableWidth: 1000) == CGSize(width: 600, height: 150))
        #expect(MermaidLayout.fitted(natural: natural, bodySize: 12, availableWidth: 300) == CGSize(width: 300, height: 75))
        let tall = MermaidLayout.fitted(natural: CGSize(width: 200, height: 1600), bodySize: 12, availableWidth: 500)
        #expect(tall.height == MermaidLayout.maxHeight(bodySize: 12))
        #expect(MermaidLayout.isShrunk(natural: natural, bodySize: 12, fitted: CGSize(width: 300, height: 75)))
    }

    // MARK: Renders

    @Test func rendersFoldAndFocus() async {
        await renderLightDark(
            ScrollView { LastMessageSection(message: .text(Self.message), startsExpanded: true).padding(12) },
            size: CGSize(width: 420, height: 380), name: "mermaid-fold")
        await renderLightDark(
            FocusContextView(agent: F.agent("a"), context: FocusContext(lastMessage: Self.message, hasTranscript: true)),
            size: CGSize(width: 900, height: 700), name: "mermaid-focus")
        await renderLightDark(
            MarkdownBlocksView(blocks: MarkdownParser.parse("```mermaid\nflowchart TD\n  A -->\n```")).padding(12),
            size: CGSize(width: 420, height: 140), name: "mermaid-fallback")
    }
}

extension MermaidTests {
    @Test func multiLineLabelsBecomeSeparateTexts() {
        let svg = #"<g><text class="l" text-anchor="middle"><tspan x="0" y="-6">A</tspan><tspan x="0" y="17">B</tspan></text><text x="1">C</text></g>"#
        #expect(MermaidRenderer.splitTspans(svg)
            == #"<g><text class="l" text-anchor="middle" x="0" y="-6">A</text><text class="l" text-anchor="middle" x="0" y="17">B</text><text x="1">C</text></g>"#)
    }
}
