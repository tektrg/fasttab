import SwiftUI

// One toast for the whole app: a dark capsule at the bottom that fades out on its own.
//
//   @State private var toast: String?
//   ...
//   .dsToast($toast)                                  // attach once, on the screen root
//   toast = "Sent to Mac"                             // show; a new message restarts the timer
//
// Screens with the floating sub-tab bar pass `bottomInset: DS.Space.floatingBarClearance`.
// Messages that ask the user to do something elsewhere ("confirm on your Mac") pass
// `duration: DS.Motion.toastLongDuration`. On the always-dark Tab Switcher pass `onDark: true`.

public struct DSToastView: View {
    let message: String
    let onDark: Bool
    public init(_ message: String, onDark: Bool = false) {
        self.message = message
        self.onDark = onDark
    }

    public var body: some View {
        Text(message)
            .font(DS.Font.toast)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, 10)
            .background {
                // A black pill vanishes on the dark deck; frosted glass keeps its edge.
                if onDark {
                    Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                } else {
                    Capsule().fill(DS.Palette.toastBackground)
                }
            }
            .dsShadow(.floating)
            .padding(.horizontal, DS.Space.xl)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct DSToastModifier: ViewModifier {
    @Binding var message: String?
    let bottomInset: CGFloat
    let duration: Duration
    let onDark: Bool
    /// Bumped on every new message so it restarts the hide timer.
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                // Animation scoped to the overlay so it doesn't leak into the screen's own
                // changes made in the same update (row removals, etc.).
                ZStack {
                    if let message {
                        DSToastView(message, onDark: onDark)
                            .padding(.bottom, bottomInset)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .id(generation)
                    }
                }
                .animation(DS.Motion.toast, value: message)
            }
            .onChange(of: message) { _, newValue in
                guard newValue != nil else { return }
                generation += 1
                UIAccessibility.post(notification: .announcement, argument: newValue)
            }
            .task(id: generation) {
                guard message != nil else { return }
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                message = nil
            }
    }
}

public extension View {
    func dsToast(
        _ message: Binding<String?>,
        bottomInset: CGFloat = DS.Space.xl,
        duration: Duration = DS.Motion.toastDuration,
        onDark: Bool = false
    ) -> some View {
        modifier(DSToastModifier(message: message, bottomInset: bottomInset, duration: duration, onDark: onDark))
    }
}
