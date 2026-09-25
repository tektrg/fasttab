import SwiftUI

// One toast for the whole app: a dark capsule at the bottom that fades out on its own.
//
//   @State private var toast: String?
//   ...
//   .dsToast($toast)                                  // attach once, on the screen root
//   toast = "Sent to Mac"                             // show (setting it again restarts the timer)
//
// Screens with the floating sub-tab bar pass `bottomInset: DS.Space.floatingBarClearance`.

public struct DSToastView: View {
    let message: String
    public init(_ message: String) { self.message = message }

    public var body: some View {
        Text(message)
            .font(DS.Font.toast)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, 10)
            .background(DS.Palette.toastBackground, in: Capsule())
            .dsShadow(.floating)
            .padding(.horizontal, DS.Space.xl)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct DSToastModifier: ViewModifier {
    @Binding var message: String?
    let bottomInset: CGFloat
    /// Bumped on every new message so re-showing the same text restarts the timer.
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    DSToastView(message)
                        .padding(.bottom, bottomInset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(generation)
                }
            }
            .animation(DS.Motion.toast, value: message)
            .onChange(of: message) { _, newValue in
                guard newValue != nil else { return }
                generation += 1
                UIAccessibility.post(notification: .announcement, argument: newValue)
            }
            .task(id: generation) {
                guard message != nil else { return }
                try? await Task.sleep(for: DS.Motion.toastDuration)
                guard !Task.isCancelled else { return }
                message = nil
            }
    }
}

public extension View {
    func dsToast(_ message: Binding<String?>, bottomInset: CGFloat = DS.Space.xl) -> some View {
        modifier(DSToastModifier(message: message, bottomInset: bottomInset))
    }
}
