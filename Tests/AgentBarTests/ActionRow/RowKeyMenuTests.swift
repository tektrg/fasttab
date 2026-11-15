import SwiftUI
import Testing
@testable import AgentBar

struct RowKeyMenuTests {
    private let items = [
        RowButtonSpec(button: .peek, disabledReason: nil),
        RowButtonSpec(button: .done, disabledReason: "Not now"),
        RowButtonSpec(button: .park, disabledReason: nil),
    ]

    @Test func emptyMenuDoesNotOpen() { #expect(RowKeyMenu(agentID: "a", items: []) == nil) }

    @Test func arrowsMoveAndClamp() throws {
        var menu = try #require(RowKeyMenu(agentID: "a", items: items))
        #expect(menu.highlighted == 0)
        #expect(menu.handle(.up) == RowKeyMenu.Effect.none)
        #expect(menu.highlighted == 0)
        _ = menu.handle(.down); _ = menu.handle(.down); _ = menu.handle(.down)
        #expect(menu.highlighted == 2)
        #expect(menu.handle(.enter) == .activate(.park))
    }

    @Test func digitsQuickSelectAndDisabledNeverFires() throws {
        var menu = try #require(RowKeyMenu(agentID: "a", items: items))
        #expect(menu.handle(.digit(1)) == .activate(.peek))
        #expect(menu.handle(.digit(2)) == RowKeyMenu.Effect.none)   // disabled Done
        #expect(menu.handle(.digit(7)) == RowKeyMenu.Effect.none)   // no 7th item
        #expect(menu.handle(.escape) == .close)
        #expect(menu.handle(.toggle) == .close)
        #expect(RowKeyMenu.number(at: 0) == "1")
        #expect(RowKeyMenu.number(at: 9) == nil)
    }

    @Test func keyMapping() {
        #expect(RowKeyMenu.key(keyCode: 40, characters: "k", command: true) == .toggle)
        #expect(RowKeyMenu.key(keyCode: 3, characters: "f", command: true) == .other)
        #expect(RowKeyMenu.key(keyCode: 126, characters: "", command: false) == .up)
        #expect(RowKeyMenu.key(keyCode: 125, characters: "", command: false) == .down)
        #expect(RowKeyMenu.key(keyCode: 36, characters: "\r", command: false) == .enter)
        #expect(RowKeyMenu.key(keyCode: 53, characters: "", command: false) == .escape)
        #expect(RowKeyMenu.key(keyCode: 20, characters: "3", command: false) == .digit(3))
        #expect(RowKeyMenu.key(keyCode: 0, characters: "a", command: false) == .other)
    }
}

@MainActor @Suite(.serialized)
struct RowKeyMenuModelTests {
    typealias F = AgentListFixtures

    static func makeModel(_ purpose: String) -> AgentPanelModel {
        let defaults = makeScratchDefaults(purpose)
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: PermissionCardModel(loadSessionContext: { _ in .empty }),
            now: { F.now }
        )
        let source = PermissionFakeSource()
        source.screen = .screen(lines: ["$ ls"], readAt: F.now)
        model.statusSource = source
        return model
    }

    @Test func commandKOpensTheSelectedRowsMoreMenuAndADigitPressesIt() throws {
        let model = Self.makeModel("keymenu")
        let agent = F.agent("idle")
        model.receive(F.snapshot([agent]))
        model.select(agentID: "idle")
        model.toggleKeyMenu()
        let menu = try #require(model.keyMenu)
        #expect(menu.items == AgentActionList.menuItems(for: agent, tree: nil))
        let park = try #require(menu.items.firstIndex { $0.button == .park })
        model.handleKeyMenu(.digit(park + 1))
        #expect(model.keyMenu == nil)
        #expect(model.presentation.agents.first { $0.id == "idle" }?.section == .parked)
    }

    @Test func escapeClosesOnlyTheMenuAndCommandKToggles() {
        let model = Self.makeModel("keymenu-esc")
        model.receive(F.snapshot([F.agent("idle")]))
        model.select(agentID: "idle")
        model.toggleKeyMenu()
        #expect(model.keyMenu != nil)
        #expect(model.handleKeyMenu(.escape))
        #expect(model.keyMenu == nil)
        model.query = "id"
        model.toggleKeyMenu()          // ⌘K while typing in search still opens it
        #expect(model.keyMenu != nil)
        #expect(model.query == "id")
        model.toggleKeyMenu()
        #expect(model.keyMenu == nil)
    }

    @Test func rendersNumberedMenu() async throws {
        let model = Self.makeModel("keymenu-render")
        model.receive(F.snapshot([F.agent("idle", label: "aptus-worker-fe")]))
        model.select(agentID: "idle")
        model.toggleKeyMenu()
        model.handleKeyMenu(.down)
        let menu = try #require(model.keyMenu)
        let view = AgentPanelView(model: model, onClose: {}, onOpenSettings: {})
        await renderLightDark(view, size: CGSize(width: 680, height: 420), name: "keymenu-panel")
        await renderLightDark(RowKeyMenuView(menu: menu, agentLabel: "aptus-worker-fe", onChoose: { _ in }).padding(20),
                              size: CGSize(width: 320, height: 320), name: "keymenu")
    }
}
