import SwiftUI

/// Play/Pause control in the reader's bottom bar.
struct ReadAloudButton: View {
    @ObservedObject var controller: ReadAloudController
    let article: ReaderArticle

    var body: some View {
        Button {
            controller.togglePlayback(article: article)
        } label: {
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle")
                .font(.body)
                .readerBarTapTarget()
        }
        .accessibilityLabel(isPlaying ? "Pause reading aloud" : "Read aloud")
    }

    private var isPlaying: Bool { controller.state == .playing }
}

/// Shown after the user scrolls away during Read Aloud; resumes following the spoken word.
struct ReadAloudBackToReadingButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Back to reading", systemImage: "arrow.down.to.line")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.sm)
                .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .dsShadow(.floating)
    }
}

/// "Read Aloud" section of the reading settings sheet: speed + voice.
struct ReadAloudSettingsSection: View {
    @ObservedObject var store: ReaderReadingSettingsStore
    let voices: [ReadAloudVoiceOption]

    var body: some View {
        Section {
            Picker("Speed", selection: Binding(
                get: { store.settings.effectiveSpeechRate },
                set: { store.setSpeechRate($0) }
            )) {
                ForEach(ReaderReadingSettings.speechRateOptions, id: \.self) { rate in
                    Text(Self.rateLabel(rate)).tag(rate)
                }
            }
            if !voices.isEmpty {
                Picker("Voice", selection: Binding(
                    get: { selectedVoiceID },
                    set: { store.setSpeechVoice(identifier: $0) }
                )) {
                    Text("Automatic").tag(String?.none)
                    ForEach(voices) { voice in
                        Text(Self.voiceLabel(voice)).tag(Optional(voice.id))
                    }
                }
            }
        } header: {
            Text("Read Aloud")
        } footer: {
            Text("Automatic picks the best voice installed for the article's language. Download Enhanced or Premium voices in Settings › Accessibility › Spoken Content › Voices.")
        }
    }

    /// The saved voice when it is in this language's list; otherwise "Automatic".
    private var selectedVoiceID: String? {
        let saved = store.settings.speechVoiceIdentifier
        return voices.contains { $0.id == saved } ? saved : nil
    }

    static func rateLabel(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private static func voiceLabel(_ voice: ReadAloudVoiceOption) -> String {
        let region = Locale.current.localizedString(forIdentifier: voice.languageCode) ?? voice.languageCode
        let quality = voice.quality.label.map { " · \($0)" } ?? ""
        return "\(voice.name) (\(region))\(quality)"
    }
}
