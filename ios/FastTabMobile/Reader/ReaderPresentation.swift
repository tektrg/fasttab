import SwiftUI
import UIKit

// MARK: - Reader presentation (slide in from the right, out to the right)
//
// Every screen that opens the reader uses `.readerPresentation(item:onDismiss:content:)`
// instead of `.fullScreenCover`. It is still a full-screen cover (so it works from any
// context: tabs, sheets, other covers), but presented without the system slide-up and
// with a clear background; the reader itself slides in from the right over the screen
// underneath, and slides back out to the right on Back, edge swipe, Delete, or when the
// caller sets `item` to nil. Reduce Motion: cross-fade instead of slide.
//
// The reader reaches its slide through `@Environment(\.readerSlide)`; without one (not
// presented this way) it falls back to `dismiss()`.

extension View {
    /// Presents the reader for `item`, sliding in from the right. Use for `ReaderView` only.
    func readerPresentation<Item: Identifiable, Reader: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Reader
    ) -> some View {
        modifier(ReaderPresentationModifier(item: item, onDismiss: onDismiss, reader: content))
    }
}

private struct ReaderPresentationModifier<Item: Identifiable, Reader: View>: ViewModifier {
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let reader: (Item) -> Reader

    /// What the cover actually shows. Lags `item` on the way out, so the reader can
    /// finish sliding before the cover goes away.
    @State private var presented: Item?
    @State private var slide = ReaderSlideController()

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: coverBinding, onDismiss: onDismiss) { shown in
                ReaderSlideContainer(controller: slide) { reader(shown) }
            }
            .onChange(of: item?.id, initial: true) { _, _ in sync() }
    }

    /// Something outside the slide closed the cover (Safari Reader fallback's Close):
    /// keep the caller's `item` in step.
    private var coverBinding: Binding<Item?> {
        Binding(
            get: { presented },
            set: { newValue in
                presented = newValue
                if newValue == nil { item = nil }
            }
        )
    }

    private func sync() {
        guard let item else {
            // The caller cleared it: slide out, then remove the cover.
            if presented != nil { slide.dismiss() }
            return
        }
        guard presented?.id != item.id else { return }
        slide.prepareForEntry { [self] in finishDismissal() }
        withoutAnimation { presented = item }
    }

    private func finishDismissal() {
        withoutAnimation { presented = nil }
        if item != nil { item = nil }
    }

    private func withoutAnimation(_ change: () -> Void) {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant, change)
    }
}

/// The cover's content: a dim over the screen underneath, then the reader offset by the slide.
private struct ReaderSlideContainer<Reader: View>: View {
    let controller: ReaderSlideController
    @ViewBuilder let reader: Reader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
            ZStack {
                Color.black
                    .opacity(ReaderSlideStyle.dimOpacity * (1 - controller.progress))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                reader
                    .environment(\.readerSlide, controller)
                    .offset(x: reduceMotion ? 0 : controller.progress * width)
                    .opacity(reduceMotion ? 1 - controller.progress : 1)
                    .allowsHitTesting(!controller.isLeaving)
            }
            .onAppear {
                controller.width = width
                controller.reduceMotion = reduceMotion
                controller.enter()
            }
            .onChange(of: width) { _, newWidth in controller.width = newWidth }
            .onChange(of: reduceMotion) { _, newValue in controller.reduceMotion = newValue }
        }
        .presentationBackground(.clear)
    }
}

enum ReaderSlideStyle {
    /// How dark the screen underneath gets while the reader covers it.
    static let dimOpacity: Double = 0.15

    static func enterAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.35, bounce: 0)
    }

    static func exitAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.3, bounce: 0)
    }

    static let snapBackAnimation: Animation = .spring(duration: 0.3, bounce: 0)
}

// MARK: - Slide state

/// Drives one presented reader's slide. `progress` 0 = fully shown, 1 = fully off to the
/// right (fully faded with Reduce Motion).
@MainActor @Observable
final class ReaderSlideController {
    private(set) var progress: CGFloat = 1
    /// Sliding out: further dismisses and drags are ignored, touches are off.
    private(set) var isLeaving = false

    @ObservationIgnored var width: CGFloat = 0
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored private var onFinished: (() -> Void)?

    /// Before the cover appears: start off-screen, and say what to do once slid out.
    func prepareForEntry(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        isLeaving = false
        progress = 1
    }

    func enter() {
        withAnimation(ReaderSlideStyle.enterAnimation(reduceMotion: reduceMotion)) { progress = 0 }
    }

    /// Slides out to the right, then removes the cover. Safe to call more than once.
    func dismiss() {
        guard !isLeaving else { return }
        isLeaving = true
        withAnimation(ReaderSlideStyle.exitAnimation(reduceMotion: reduceMotion)) {
            progress = 1
        } completion: { [weak self] in
            guard let self else { return }
            let finished = onFinished
            onFinished = nil
            finished?()
        }
    }

    /// Left-edge swipe: the reader follows the finger, then finishes or snaps back.
    func handle(_ swipe: ReaderEdgeSwipe) {
        guard !isLeaving, width > 0 else { return }
        switch swipe {
        case .changed(let translation):
            progress = ReaderSlideDismissal.progress(translation: translation, width: width)
        case .ended(let translation, let velocity):
            if ReaderSlideDismissal.shouldDismiss(translation: translation, velocity: velocity, width: width) {
                dismiss()
            } else {
                snapBack()
            }
        case .cancelled:
            snapBack()
        }
    }

    private func snapBack() {
        guard progress != 0 else { return }
        withAnimation(ReaderSlideStyle.snapBackAnimation) { progress = 0 }
    }
}

private struct ReaderSlideKey: EnvironmentKey {
    static let defaultValue: ReaderSlideController? = nil
}

extension EnvironmentValues {
    /// The slide of the reader presentation this view is in, if any.
    var readerSlide: ReaderSlideController? {
        get { self[ReaderSlideKey.self] }
        set { self[ReaderSlideKey.self] = newValue }
    }
}

// MARK: - Edge swipe

/// A left-edge pan, in window points (the reader moves under the finger, so its own
/// coordinates would chase the touch).
public enum ReaderEdgeSwipe: Equatable {
    case changed(translation: CGFloat)
    case ended(translation: CGFloat, velocity: CGFloat)
    case cancelled

    init?(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: nil).x
        switch recognizer.state {
        case .began, .changed: self = .changed(translation: translation)
        case .ended: self = .ended(translation: translation, velocity: recognizer.velocity(in: nil).x)
        case .cancelled, .failed: self = .cancelled
        default: return nil
        }
    }
}

/// When a released edge swipe closes the reader.
enum ReaderSlideDismissal {
    /// Dragged at least this share of the width.
    static let distanceFraction: CGFloat = 1.0 / 3.0
    /// Or flicked right at least this fast (points per second).
    static let flingVelocity: CGFloat = 600
    /// Moving back left at least this fast keeps the reader, however far it was dragged.
    static let returnVelocity: CGFloat = -300

    static func progress(translation: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(max(translation / width, 0), 1)
    }

    static func shouldDismiss(translation: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        guard width > 0, translation > 0 else { return false }
        if velocity >= flingVelocity { return true }
        if velocity <= returnVelocity { return false }
        return translation >= width * distanceFraction
    }
}
