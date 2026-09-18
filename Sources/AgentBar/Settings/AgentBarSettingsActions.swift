/// What the Settings window asks the running app to do; the coordinator
/// provides them. Keeps the views free of any knowledge of hotkeys or feeds.
struct AgentBarSettingsActions {
    /// Registers the shortcut right away. On refusal the previous one stays
    /// active and the outcome carries the plain-English reason.
    var changeHotkey: @MainActor (AgentHotkeyConfig) -> HotkeyChangeOutcome
    /// The recorder is capturing keys: the global shortcut must be off meanwhile.
    var setHotkeyRecording: @MainActor (Bool) -> Void
}
