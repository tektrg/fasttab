import Foundation
import Testing
@testable import AgentBar

/// Settings › Accounts reordering: a drop onto a row and the ↑/↓ buttons each send the whole new order.
@MainActor
struct AccountReorderTests {
    private func model() -> (AccountsSettingsModel, ScriptedDashboardTransport) {
        let accounts = #"{"ok":true,"accounts":[{"id":"a"},{"id":"b"},{"id":"c"}]}"#
        let transport = ScriptedDashboardTransport { request in
            request.url?.path == "/api/accounts" ? .body(Data(accounts.utf8)) : .body(Data(#"{"ok":true}"#.utf8))
        }
        let model = AccountsSettingsModel(endpoint: { DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4799")!) },
                                          transport: transport)
        return (model, transport)
    }

    private func sentOrders(_ transport: ScriptedDashboardTransport) -> [[String]] {
        transport.requests.filter { $0.url?.path == "/api/accounts/reorder" }.compactMap { request in
            guard let body = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: [String]] else { return nil }
            return json["ids"]
        }
    }

    @Test func droppingARowOntoAnotherTakesItsPlace() async {
        let (model, transport) = model()
        await model.reload()
        await model.move("c", onto: "a")
        await model.move("a", onto: "c")
        #expect(sentOrders(transport) == [["c", "a", "b"], ["b", "c", "a"]])
    }

    @Test func arrowsMoveOneStepAndStopAtTheEnds() async {
        let (model, transport) = model()
        await model.reload()
        await model.step("a", by: 1)
        await model.step("c", by: -1)
        await model.step("a", by: -1)
        await model.step("c", by: 1)
        #expect(sentOrders(transport) == [["b", "a", "c"], ["a", "c", "b"]])
    }
}
