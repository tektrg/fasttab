import FastTabSync
import AppKit

/// What Enter on a FastTab List item does: the reader window, or the browser when Option is
/// held (also the reader's own "Open in Browser").
enum FastTabListOpenRoute: Equatable {
    case reader, browser

    static func forModifiers(_ flags: NSEvent.ModifierFlags) -> FastTabListOpenRoute {
        flags.contains(.option) ? .browser : .reader
    }
}

/// One reader window per article: opening an article that already has a window brings that
/// window forward (keeps its scroll place) instead of opening a second copy. Different
/// articles get their own windows, like browser tabs, so two can sit side by side.
enum MacReaderWindowRoute: Equatable {
    case focusExisting(itemID: String)
    case openNew(itemID: String)

    static func decide(forURL urlString: String, openItemIDs: Set<String>) -> MacReaderWindowRoute {
        let itemID = FastTabListLibrary.itemID(for: urlString)
        return openItemIDs.contains(itemID) ? .focusExisting(itemID: itemID) : .openNew(itemID: itemID)
    }
}



/// Owns the open reader windows.
@MainActor
final class MacReaderWindowRouter {
    static let shared = MacReaderWindowRouter()

    private var controllers: [String: MacReaderWindowController] = [:]

    var openItemIDs: Set<String> { Set(controllers.keys) }

    func open(url urlString: String, title: String?) {
        guard let url = URL(string: urlString) else { return }
        switch MacReaderWindowRoute.decide(forURL: urlString, openItemIDs: openItemIDs) {
        case .focusExisting(let itemID):
            controllers[itemID]?.bringToFront()
        case .openNew(let itemID):
            let controller = MacReaderWindowController(url: url, title: title) { [weak self] in
                self?.controllers[itemID] = nil
            }
            controllers[itemID] = controller
            controller.bringToFront()
        }
    }
}
