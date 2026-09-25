import Foundation
import Testing
@testable import AgentBar

struct RoutingSettingsTests {
    @Test func startsOnDefaults() {
        let settings = RoutingSettings.load(from: makeScratchDefaults("routing"))
        #expect(settings == .standard)
        #expect(settings.modelID == "~typesafe/jev-latest")
        #expect(settings.afterRouting == .confirmFirst)
        #expect(settings.systemPrompt == "")
    }

    @Test func changesPersistAcrossLoads() {
        let defaults = makeScratchDefaults("routing")
        var settings = RoutingSettings.load(from: defaults)
        settings.modelID = "openai/gpt-5"
        settings.afterRouting = .sendImmediately
        settings.systemPrompt = "Prefer fe for UI bugs."
        settings.save(to: defaults)

        let reloaded = RoutingSettings.load(from: defaults)
        #expect(reloaded.modelID == "openai/gpt-5")
        #expect(reloaded.afterRouting == .sendImmediately)
        #expect(reloaded.systemPrompt == "Prefer fe for UI bugs.")
    }

    @Test func anUnknownStoredAfterRoutingValueFallsBackToTheDefault() {
        let defaults = makeScratchDefaults("routing")
        defaults.set("somethingUnexpected", forKey: RoutingSettings.afterRoutingKey)
        #expect(RoutingSettings.load(from: defaults).afterRouting == .confirmFirst)
    }

    @MainActor @Test func agentBarSettingsUpdateRoutingPublishesAndPersists() {
        let defaults = makeScratchDefaults("routing")
        let settings = AgentBarSettings(defaults: defaults)
        #expect(settings.routing == .standard)

        settings.updateRouting {
            $0.modelID = "anthropic/claude-latest"
            $0.afterRouting = .sendImmediately
            $0.systemPrompt = "Route bugs to fe, infra to backend."
        }
        #expect(settings.routing.modelID == "anthropic/claude-latest")
        #expect(settings.routing.afterRouting == .sendImmediately)
        #expect(settings.routing.systemPrompt == "Route bugs to fe, infra to backend.")

        let reloaded = AgentBarSettings(defaults: defaults)
        #expect(reloaded.routing.modelID == "anthropic/claude-latest")
        #expect(reloaded.routing.afterRouting == .sendImmediately)
        #expect(reloaded.routing.systemPrompt == "Route bugs to fe, infra to backend.")
    }

    @MainActor @Test func updateRoutingIsANoOpWhenNothingChanges() {
        let defaults = makeScratchDefaults("routing")
        let settings = AgentBarSettings(defaults: defaults)
        settings.updateRouting { _ in }
        #expect(settings.routing == .standard)
        #expect(defaults.object(forKey: RoutingSettings.modelIDKey) == nil)
    }
}
