import CoreGraphics

enum CommandBarLayout {
    static let surfaceSize = CGSize(width: 640, height: 460)
    static let canvasSize = CGSize(width: 1600, height: 1000)

    /// SwiftUI points. Negative values move the visible surface upward.
    static let surfaceVerticalOffset: CGFloat = -140
}
