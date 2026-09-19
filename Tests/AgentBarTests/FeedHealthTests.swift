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

    // MARK: - Multi-machine dashboards put non-feed entries in `feeds`

    /// The real payload shape since the dashboard went multi-machine: `feeds` also holds
    /// `"machines": {"air-m1": {...}}` and `"machinesConfigError": null` next to the feeds.
    @Test func nonFeedEntriesInsideFeedsDoNotMakeAHealthyDashboardReadDown() throws {
        let snapshot = try StatusFixtures.snapshot("state-multi-machine")
        #expect(snapshot.health == .ok)
        #expect(!snapshot.agents.isEmpty)
    }

    @Test func aNullOrOddFeedEntryCostsOnlyItself() throws {
        for odd: Any in [NSNull(), "text", 5, [1, 2], ["status": "ok"]] {
            let data = StatusFixtures.data("state-healthy") { object in
                var feeds = object["feeds"] as! [String: Any]
                feeds["machinesConfigError"] = odd
                feeds["surprise"] = odd
                object["feeds"] = feeds
            }
            #expect(try StatusSnapshotBuilder.snapshot(fromJSON: data, fetchedAt: StatusFixtures.serverNow).health == .ok, "\(odd)")
        }
    }

    @Test func anEssentialFeedThatIsGenuinelyAbsentStillReadsAsDownAndSaysSo() throws {
        let data = StatusFixtures.data("state-multi-machine") { object in
            var feeds = object["feeds"] as! [String: Any]
            feeds["hookCache"] = nil
            object["feeds"] = feeds
        }
        let snapshot = try StatusSnapshotBuilder.snapshot(fromJSON: data, fetchedAt: StatusFixtures.serverNow)
        #expect(snapshot.health == .down(reason: "Status feed down: the hookCache feed is not in the dashboard's reply"))
    }

    @Test func anEssentialFeedThatIsThereButUnreadableIsDownAndSaysThat() throws {
        let data = StatusFixtures.data("state-multi-machine") { object in
            var feeds = object["feeds"] as! [String: Any]
            feeds["hookCache"] = NSNull()
            object["feeds"] = feeds
        }
        let snapshot = try StatusSnapshotBuilder.snapshot(fromJSON: data, fetchedAt: StatusFixtures.serverNow)
        #expect(snapshot.health == .down(reason: "Status feed down: the hookCache feed could not be read"))
    }
}
