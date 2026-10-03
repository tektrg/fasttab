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

/// Centred play/pause glyph that fades in and out after a tap on the article.
struct ReadAloudTapFeedbackView: View {
    let feedback: ReadAloudController.TapFeedback?
    @State private var isVisible = false

    var body: some View {
        Image(systemName: feedback?.kind == .paused ? "pause.fill" : "play.fill")
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 72, height: 72)
            .background(.regularMaterial, in: Circle())
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible ? 1 : 0.85)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: feedback) { _, newValue in
                guard newValue != nil else { return }
                withAnimation(.easeOut(duration: 0.15)) { isVisible = true }
                withAnimation(.easeIn(duration: 0.35).delay(0.5)) { isVisible = false }
            }
    }
}

/// Small capsule (e.g. "Natural voice unavailable, using device voice") shown for a few
/// seconds whenever the controller posts a new engine notice.
struct ReadAloudNoticeView: View {
    let notice: ReadAloudController.EngineNotice?
    @State private var visibleMessage: String?

    var body: some View {
        Group {
            if let visibleMessage {
                Text(visibleMessage)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.vertical, DS.Space.sm)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .task(id: notice) {
            guard let notice else { return }
            withAnimation { visibleMessage = notice.message }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { visibleMessage = nil }
        }
    }
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
            if AppDistribution.isDebugOrTestFlight {
                Toggle("Natural voice (beta)", isOn: Binding(
                    get: { store.settings.naturalVoiceEnabled ?? false },
                    set: { store.setNaturalVoiceEnabled($0) }
                ))
            }
        } header: {
            Text("Read Aloud")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        let voices = "Automatic picks the best voice installed for the article's language. Download Enhanced or Premium voices in Settings › Accessibility › Spoken Content › Voices."
        guard AppDistribution.isDebugOrTestFlight else { return voices }
        return voices + " Natural voice streams a more human voice from the internet and falls back to the device voice when it isn't available."
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
