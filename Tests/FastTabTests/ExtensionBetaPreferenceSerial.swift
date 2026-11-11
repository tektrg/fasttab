import Testing

/// Suites that flip the global `ExtensionBetaPreference` (UserDefaults) nest
/// here so they run one at a time. `.serialized` on a single suite does not
/// stop other suites running in parallel, and a concurrent flip makes the
/// extension-path tests see the wrong mode (and index into empty results).
@Suite(.serialized) enum ExtensionBetaPreferenceSerial {}
