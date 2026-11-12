import IndieCommandBar

/// Agent Bar's slash commands, on the shared command-row hook (`CommandBarCommandRows`).
/// Return with a command's exact text runs it (`AgentPanelModel.enterNewWorkerIfCommand`,
/// `beginNewViewIfCommand`); typing "/" shows matching rows (`AgentPanelModel+Commands`).
enum AgentBarCommands {
    static let newWorker = CommandBarCommand(id: "new", trigger: NewWorkerMode.command, title: "New worker", symbol: "plus")
    static let newView = CommandBarCommand(id: "view", trigger: "/view", title: "New view", symbol: "rectangle.stack.badge.plus")
    static let all = [newWorker, newView]

    static func exact(_ text: String) -> CommandBarCommand? { CommandBarCommandRows.exact(text, in: all) }
}
