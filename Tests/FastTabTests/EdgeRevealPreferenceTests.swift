import Foundation
import Testing
@testable import FastTab
import CommandBarKit
import IndieEdgeReveal

/// The hover-trigger setting moved to IndieLibKit's `EdgeRevealStyle`; users'
/// stored `FastTab.edgeReveal.style` values must load exactly as before.
@MainActor
struct EdgeRevealPreferenceTests {
    private static let styleKey = "FastTab.edgeReveal.style"

    private func scratchDefaults(_ values: [String: Any]) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "test.fasttab.edgeReveal.\(UUID().uuidString)")!
        values.forEach { defaults.set($1, forKey: $0) }
        return defaults
    }

    @Test(arguments: [
        ("off", EdgeRevealStyle.off), ("notch", .notch), ("leftEdge", .leftEdge), ("rightEdge", .rightEdge),
    ])
    func storedValuesFromBeforeTheMoveLoadUnchanged(raw: String, expected: EdgeRevealStyle) {
        #expect(EdgeRevealStore(defaults: scratchDefaults([Self.styleKey: raw])).style == expected)
    }

    @Test(arguments: EdgeRevealStyle.allCases)
    func everyStyleRoundTripsThroughItsStoredValue(style: EdgeRevealStyle) {
        #expect(EdgeRevealStore(defaults: scratchDefaults([Self.styleKey: style.rawValue])).style == style)
    }

    @Test func unsetDefaultsToNotchForNewUsersAndOffForExistingOnes() {
        #expect(EdgeRevealStore(defaults: scratchDefaults([:])).style == .notch)
        #expect(EdgeRevealStore(defaults: scratchDefaults(["onboarding.v1.completed": true])).style == .off)
    }

    @Test func eachTriggerSpotOpensTheBarOnTheNearestLayout() {
        let expected: [EdgeRevealStyle: CommandBarAnchor] = [
            .off: .notch, .notch: .notch, .bottomEdge: .notch,
            .leftEdge: .leftEdge, .topLeftCorner: .leftEdge, .bottomLeftCorner: .leftEdge,
            .rightEdge: .rightEdge, .topRightCorner: .rightEdge, .bottomRightCorner: .rightEdge,
        ]
        #expect(Set(expected.keys) == Set(EdgeRevealStyle.allCases))
        for (style, anchor) in expected {
            #expect(CommandBarAnchor(revealStyle: style) == anchor)
        }
    }

    @Test func onboardingOffersTheOriginalFourSpots() {
        #expect(EdgeRevealStyle.onboardingChoices == [.off, .notch, .leftEdge, .rightEdge])
    }
}
