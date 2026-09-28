import SwiftUI

/// Where people get the FastTab iPhone companion (`ios/FastTabMobile`).
/// `nil` until it has a public App Store or TestFlight link — the onboarding
/// iPhone step then shows "Coming soon" instead of a download action.
enum FastTabIPhoneApp {
    static let downloadURL: URL? = nil
}

/// Reasons to get the iPhone app. Revisit and Reader mode lead — they're what
/// the phone does that the Mac bar doesn't. Keep each claim true to
/// `ios/FastTabMobile`:
/// - `revisit`: Read tab's "Emerging" feed, `EmergingLane.forgotten` (bookmarks
///   30+ days old, tabs idle 3+ days — `EmergingContentProvider`), plus the
///   Shuffle tab (`RandomLinksView`, swipe through open tabs and bookmarks).
/// - `reader`: "Open in Reader" (`ReaderView`, Readability extraction),
///   long-press highlights, scroll position restored via `LastOpenedStore`.
/// - `tabs`: Tabs tab + More → Bookmarks/History, with remote tab close.
/// - `send`: share sheet "Send to Mac" (`DeskQueueView`); a sleeping Mac opens
///   the link when it wakes.
extension OnboardingBenefit {
    static let iPhoneBenefits: [OnboardingBenefit] = [
        .init(
            id: "revisit",
            symbolName: "arrow.uturn.backward.circle.fill",
            title: "Revisit forgotten tabs",
            detail: "Resurfaces old bookmarks and tabs left open for days, or shuffle through them."
        ),
        .init(
            id: "reader",
            symbolName: "doc.plaintext.fill",
            title: "Reader mode",
            detail: "Read any tab as clean text. Highlight passages, pick up where you left off."
        ),
        .init(
            id: "tabs",
            symbolName: "macwindow.on.rectangle",
            title: "Your Mac's tabs in your pocket",
            detail: "Search open tabs, bookmarks and history, and close tabs from your phone."
        ),
        .init(
            id: "send",
            symbolName: "paperplane.fill",
            title: "Send links to your Mac",
            detail: "Share a link on iPhone and your Mac opens it, right away or when it wakes."
        ),
    ]
}

/// Onboarding step introducing the iPhone app, laid out like the extension
/// step. With a download link it offers the link plus a QR code to scan;
/// without one (today) it says "Coming soon" and just continues.
struct OnboardingIPhoneStep: View {
    var downloadURL: URL? = FastTabIPhoneApp.downloadURL
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            Image(systemName: "iphone")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 10)
                .accessibilityHidden(true)

            Text("Take your tabs with you")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 6)

            Text("FastTab for iPhone syncs with this Mac over iCloud. Just use the same Apple Account on both.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 36)
                .padding(.bottom, 18)

            OnboardingBenefitsView(benefits: OnboardingBenefit.iPhoneBenefits)
                .padding(.horizontal, 44)
                .padding(.bottom, 20)

            if let downloadURL {
                downloadActions(for: downloadURL)
            } else {
                comingSoonActions
            }

            Spacer(minLength: 12)
        }
    }

    private var comingSoonActions: some View {
        VStack(spacing: 12) {
            Label("iPhone app coming soon", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.08)))

            continueButton
        }
    }

    private func downloadActions(for url: URL) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                OnboardingQRCodeView(url: url)
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Scan with your iPhone camera, or")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link(destination: url) {
                        Label("Get FastTab for iPhone", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }

            Button("Continue", action: onContinue)
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var continueButton: some View {
        Button(action: onContinue) {
            Text("Continue")
                .font(.headline)
                .frame(width: 160)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
