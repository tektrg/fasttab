import AppKit

/// Plays an alert sound. The real one talks to macOS; tests use a recording fake.
@MainActor
protocol SoundPlayer {
    func play(_ choice: SoundChoice)
}

/// Plays macOS system sounds. A sound that is missing or cannot be loaded is skipped silently.
@MainActor
struct SystemSoundPlayer: SoundPlayer {
    func play(_ choice: SoundChoice) {
        guard let name = choice.systemSoundName, let sound = NSSound(named: name) else { return }
        sound.stop()   // NSSound ignores play() while it is still playing (the shared instance per name)
        sound.play()
    }
}
