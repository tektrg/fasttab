import IndieCommandBar

/// Agent Bar's slash commands, on the shared command-row hook (`CommandBarCommandRows`).
/// Return with a command's exact text runs it (`AgentPanelModel.enterNewWorkerIfCommand`,
/// `beginNewViewIfCommand`). Rows for partial text are not drawn: the list filters as before.
enum AgentBarCommands {
    static let newWorker = CommandBarCommand(id: "new", trigger: NewWorkerMode.command, title: "New worker", symbol: "plus")
    static let newView = CommandBarCommand(id: "view", trigger: AgentPagesModel.newViewCommand, title: "New view", symbol: "rectangle.stack.badge.plus")
    static let all = [newWorker, newView]

    static func exact(_ text: String) -> CommandBarCommand? { CommandBarCommandRows.exact(text, in: all) }
}
