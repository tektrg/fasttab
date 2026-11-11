import Foundation
import Testing
@testable import FastTab

/// Custom views accept the shared `TextPattern` entry forms (plain / `*wildcard*` / `/regex/`)
/// in keywords (title or URL) and domains (host); views saved before keep their meaning.
struct CustomViewPatternTests {
    typealias T = CustomViewFilterTests

    private let candidates = [
        T.item(.tab, "https://github.com/tektrg/indielibkit/issues/3", title: "Issue 3"),
        T.item(.tab, "https://gist.github.com/x", title: "A Gist"),
        T.item(.tab, "https://news.ycombinator.com/item?id=1", title: "HN thread"),
    ]

    private func titles(_ view: CustomView) -> Set<String> {
        Set(CustomViewFilter.apply(view, to: candidates, now: T.now).map(\.title))
    }

    @Test func plainKeywordsStillNeedEveryWord() {
        #expect(titles(CustomView(name: "v", keywords: "issue github")) == ["Issue 3"])
    }

    @Test func wildcardKeywordMatchesTitleOrURL() {
        #expect(titles(CustomView(name: "v", keywords: "github.com/*/issues")) == ["Issue 3"])
        #expect(titles(CustomView(name: "v", keywords: "*THREAD")) == ["HN thread"])
    }

    @Test func regexKeywordMatchesTitleOrURL() {
        #expect(titles(CustomView(name: "v", keywords: "/^(issue|a gist)/")) == ["Issue 3", "A Gist"])
        #expect(titles(CustomView(name: "v", keywords: "/[/")).isEmpty)
    }

    @Test func plainAndStarDotDomainsKeepSubdomainMeaning() {
        #expect(titles(CustomView(name: "v", domains: ["github.com"])) == ["Issue 3", "A Gist"])
        #expect(titles(CustomView(name: "v", domains: ["*.github.com"])) == ["Issue 3", "A Gist"])
    }

    @Test func patternDomainsMatchTheHost() {
        #expect(titles(CustomView(name: "v", domains: ["gist.*"])) == ["A Gist"])
        #expect(titles(CustomView(name: "v", domains: ["/ycombinator\\.com$/"])) == ["HN thread"])
        #expect(titles(CustomView(name: "v", domains: ["*combinator*", "github.com"])).count == 3)
    }

    @Test func injectionLookingKeywordIsJustText() {
        #expect(titles(CustomView(name: "v", keywords: "*$(echo INJECTED)*")).isEmpty)
    }
}

struct CustomViewDraftPatternTests {
    @Test func editorKeepsPatternDomainsAndRejectsBrokenRegex() {
        var draft = CustomViewDraft(view: CustomView(name: "v"))
        draft.domainsText = "*.GitHub.com, gist.*, /news\\./, /[/"
        #expect(draft.normalizedDomains == ["github.com", "gist.*", "/news\\./"])
        #expect(draft.invalidDomains == ["/[/"])
    }
}
