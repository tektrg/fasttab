import CoreGraphics

enum CommandBarLayout {
    static let surfaceSize = CGSize(width: 640, height: 460)
    static let defaultCanvasSize = CGSize(width: 1600, height: 1000)
    static let minimumCanvasSize = surfaceSize
    static let shadowOverscan: CGFloat = 900

    /// SwiftUI points. Negative values move the visible surface upward.
    static let surfaceVerticalOffset: CGFloat = -140

    static func canvasFrame(for displayFrame: CGRect) -> CGRect {
        let canvasSize = CGSize(
            width: max(displayFrame.width, minimumCanvasSize.width),
            height: max(displayFrame.height, minimumCanvasSize.height)
        )

        return CGRect(
            x: displayFrame.midX - canvasSize.width / 2,
            y: displayFrame.midY - canvasSize.height / 2,
            width: canvasSize.width,
            height: canvasSize.height
        )
    }

    static func shadowBackdropSize(for canvasSize: CGSize) -> CGSize {
        CGSize(
            width: canvasSize.width + shadowOverscan,
            height: canvasSize.height + shadowOverscan
        )
    }

}
