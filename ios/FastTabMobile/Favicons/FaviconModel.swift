import SwiftUI
import UIKit
import FastTabSync

/// Site icons for the tab list, as synced from the Mac (`SyncedFavicons`).
///
/// The bytes live in `SyncedFaviconStore` (its own small files); this adds the decoded
/// `UIImage` cache and a `revision` counter views observe, so a freshly synced icon
/// replaces the globe without any row re-reading the whole sync state.
@MainActor
public final class FaviconModel: ObservableObject {
    public static let shared = FaviconModel(
        store: SyncedFaviconStore(
            directory: URL.applicationSupportDirectory.appending(path: "Favicons", directoryHint: .isDirectory)
        )
    )

    /// Bumped when the icon set changes. Only `FaviconView` observes it.
    @Published public private(set) var revision = 0

    private let store: SyncedFaviconStore
    /// host → decoded image, plus hosts known to have none, so a row without an
    /// icon does not hit the store on every render.
    private var decoded: [String: UIImage] = [:]
    private var misses: Set<String> = []

    public init(store: SyncedFaviconStore) {
        self.store = store
    }

    public func apply(_ favicons: SyncedFavicons) {
        if store.apply(favicons) { invalidate() }
    }

    /// Called for every state-zone deletion (mostly closed tabs): only a real
    /// favicon record bumps `revision`, so closing tabs doesn't re-render rows.
    public func remove(recordName: String) {
        if store.remove(recordName: recordName) { invalidate() }
    }

    /// The icon for a tab's URL, or nil (caller shows the globe).
    public func image(forURL url: String) -> UIImage? {
        guard let host = SyncedFavicons.host(fromURL: url) else { return nil }
        return image(forHost: host)
    }

    public func image(forHost host: String) -> UIImage? {
        if let image = decoded[host] { return image }
        if misses.contains(host) { return nil }
        // Synced data is untrusted for decoding: header-check size before any UIImage decode.
        guard let data = store.iconData(forHost: host),
              FaviconImage.isSafeToDecode(data),
              let image = UIImage(data: data) else {
            misses.insert(host)
            return nil
        }
        decoded[host] = image
        return image
    }

    private func invalidate() {
        decoded.removeAll()
        misses.removeAll()
        revision += 1
    }
}

/// A tab's site icon, falling back to the globe while none has synced (or it can't be decoded).
/// The icon sits on a subtle plate so transparent / black-on-transparent glyphs stay visible on dark rows.
struct FaviconView: View {
    let url: String
    var fallbackSystemName = "globe"
    var fallbackTint: Color = DS.Tint.action

    @ObservedObject private var model = FaviconModel.shared
    @Environment(\.colorScheme) private var colorScheme

    private var plate: Color {
        colorScheme == .dark ? Color.white.opacity(0.9) : Color(.secondarySystemFill)
    }

    var body: some View {
        Group {
            if let image = model.image(forURL: url) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(1.5)
                    .background(plate, in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
            } else {
                Image(systemName: fallbackSystemName)
                    .foregroundStyle(fallbackTint)
                    .font(.system(size: DS.IconSize.row))
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
