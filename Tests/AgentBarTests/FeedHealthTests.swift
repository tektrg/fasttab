import Foundation
import Testing
@testable import AgentBar

struct FeedHealthTests {
    @Test func healthyFixtureIsOk() throws {
        #expect(try StatusFixtures.snapshot("state-healthy").health == .ok)
    }

    @Test func emptyButHealthyIsOkWithNoAgents() throws {
        let snapshot = try StatusFixtures.snapshot("state-empty-healthy")
        #expect(snapshot.health == .ok)
        #expect(snapshot.agents.isEmpty)
    }

    @Test func brokenEssentialFeedIsDownNotAnEmptyList() throws {
        let snapshot = try StatusFixtures.snapshot("state-feed-broken")
        guard case .down(let reason) = snapshot.health else {
            Issue.record("expected .down, got \(snapshot.health)")
            return
        }
        #expect(reason.contains("paneScreen"))
        #expect(reason.contains("herdr pane read failed"))
        #expect(snapshot.agents.isEmpty)
    }

    @Test func staleEssentialFeedIsDownEvenIfDashboardDidNotFlagItBroken() throws {
        // hookCache refreshes every 2s; 40s old is far beyond 3 intervals.
        let snapshot = try StatusFixtures.snapshot("state-feed-stale")
        guard case .down(let reason) = snapshot.health else {
            Issue.record("expected .down, got \(snapshot.health)")
            return
        }
        #expect(reason.contains("hookCache"))
        #expect(reason.contains("stale"))
        #expect(snapshot.agents.isEmpty)
    }

    @Test func feedJustInsideTheStaleBudgetIsStillOk() throws {
        // paneScreen refreshes every 15s; 44s is within 3 intervals (45s).
        let snapshot = try StatusSnapshotBuilder.snapshot(
            fromJSON: StatusFixtures.data("state-healthy") { object in
                var feeds = object["feeds"] as! [String: [String: Any]]
                feeds["paneScreen"]!["ageSec"] = 44.0
                object["feeds"] = feeds
            },
            fetchedAt: StatusFixtures.serverNow
        )
        #expect(snapshot.health == .ok)
    }

    @Test func missingWarmingOrNeverReportedEssentialFeedsAreDown() throws {
        func health(editing edit: @escaping (inout [String: [String: Any]]) -> Void) throws -> StatusFeedHealth {
            try StatusSnapshotBuilder.snapshot(
                fromJSON: StatusFixtures.data("state-healthy") { object in
                    var feeds = object["feeds"] as! [String: [String: Any]]
                    edit(&feeds)
                    object["feeds"] = feeds
                },
                fetchedAt: StatusFixtures.serverNow
            ).health
        }
        #expect(try health { $0["herdr"] = nil }.isDown)
        #expect(try health { $0["herdr"]!["warming"] = true }.isDown)
        #expect(try health { $0["hookCache"]!["ageSec"] = NSNull() }.isDown)
    }

    @Test func nonEssentialFeedsBeingBrokenDoNotTakeTheListDown() throws {
        let snapshot = try StatusSnapshotBuilder.snapshot(
            fromJSON: StatusFixtures.data("state-healthy") { object in
                var feeds = object["feeds"] as! [String: [String: Any]]
                for name in ["paneTick", "gitHealth", "workItems"] {
                    feeds[name]!["broken"] = true
                }
                object["feeds"] = feeds
            },
            fetchedAt: StatusFixtures.serverNow
        )
        #expect(snapshot.health == .ok)
        #expect(snapshot.agents.count > 8)
    }

    @Test func aPayloadWithNoFeedsAtAllIsDown() throws {
        let snapshot = try StatusSnapshotBuilder.snapshot(fromJSON: Data("{}".utf8), fetchedAt: StatusFixtures.serverNow)
        #expect(snapshot.health.isDown)
        #expect(snapshot.agents.isEmpty)
    }

    @Test func nonJSONThrows() {
        #expect(throws: (any Error).self) {
            try StatusSnapshotBuilder.snapshot(fromJSON: Data("<html>".utf8), fetchedAt: StatusFixtures.serverNow)
        }
    }

    @Test func essentialFeedsAreTheOnesStatusDependsOn() {
        #expect(Set(FeedHealthEvaluator.essentialFeedNames) == ["hookCache", "herdr", "paneScreen"])
        #expect(FeedHealthEvaluator.staleAfterRefreshIntervals == 3)
    }
}
