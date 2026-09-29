import SwiftUI
import FastTabSync

/// Screen 4: put FastTab in the share sheet, then send a test link.
///
/// "Try it" goes through the normal send path (`SyncConsumer.sendOpenOnMac`), so
/// the link shows up in the Desk Queue here and under "Sent to Mac" on the Mac,
/// and its progress line uses the same `CommandProgress` wording as the queue.
struct OnboardingSendToMacStep: View {
    let isStandalone: Bool
    let onContinue: () -> Void

    /// The test link: FastTab's own site, harmless to open on any Mac.
    static let sampleLinkURL = FastTabMacApp.downloadPageURL
    static let sampleLinkTitle = "FastTab — sent from your iPhone"

    @ObservedObject private var localCache = LocalCache.shared
    @State private var toast: String?
    /// When "Try it" was tapped; finds that command in the sent list.
    @State private var trySentAt: Date?

    private var hasMac: Bool {
        localCache.state.connectedMac != nil
    }

    var body: some View {
        OnboardingStepLayout(
            title: "Send links to your Mac",
            message: "Add FastTab to your share sheet once. Then any link is one tap from your Mac."
        ) {
            OnboardingHeroSend(state: SendHeroState(hasMac: hasMac, tryProgress: tryProgress))
        } content: {
            VStack(spacing: DS.Space.lg) {
                VStack(spacing: DS.Space.md) {
                    OnboardingNumberedInstruction(number: 1, text: "In Safari or any app, tap Share", systemImage: "square.and.arrow.up")
                    OnboardingNumberedInstruction(number: 2, text: "Scroll the row of apps to the end and tap More", systemImage: "ellipsis")
                    OnboardingNumberedInstruction(number: 3, text: "Tap Edit, then add FastTab", systemImage: "plus.circle.fill")
                }
                .dsCard()

                Text("Then pick FastTab and choose Send to Mac or Save to iPhone.")
                    .font(DS.Font.meta)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                tryItSection
            }
        } actions: {
            OnboardingPrimaryButton(title: isStandalone ? "Done" : "Continue", action: onContinue)
        }
        .dsToast($toast)
    }

    @ViewBuilder
    private var tryItSection: some View {
        if let progress = tryProgress {
            Label(progress.label, systemImage: progress.symbolName)
                .font(DS.Font.cardTitle)
                .foregroundStyle(progress.tint)
                .animation(DS.Motion.quick, value: progress)
        } else if hasMac {
            Button(action: sendSampleLink) {
                Label("Try it: send a link to your Mac", systemImage: "paperplane")
            }
            .buttonStyle(.dsTinted(DS.Tint.shared))
        } else {
            Text("Connect a Mac to try sending a link.")
                .font(DS.Font.meta)
                .foregroundStyle(.secondary)
        }
    }

    /// Live status of the test link, once sent.
    private var tryProgress: CommandProgress? {
        guard let trySentAt else { return nil }
        let command = localCache.state.sentCommands
            .filter { $0.issuedAt >= trySentAt.addingTimeInterval(-1) && Self.isSampleLinkCommand($0) }
            .max { $0.issuedAt < $1.issuedAt }
        guard let command else { return nil }
        return CommandProgress.of(command: command, delivery: localCache.delivery(forCommandID: command.id))
    }

    /// Only the test link, so a real share sent meanwhile can't take over this line.
    static func isSampleLinkCommand(_ command: SyncCommand) -> Bool {
        guard command.kind == .openOnMac,
              let data = command.payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(OpenOnMacPayload.self, from: data) else { return false }
        return payload.url == sampleLinkURL.absoluteString
    }

    private func sendSampleLink() {
        trySentAt = Date()
        SyncConsumer.shared.sendOpenOnMac(url: Self.sampleLinkURL.absoluteString, title: Self.sampleLinkTitle)
        toast = "Sent to Mac"
    }
}
