import UIKit
import Social
import UniformTypeIdentifiers
import CloudKit
import FastTabSync

final class ShareViewController: UIViewController {
    private let container = CKContainer(identifier: SyncConstants.containerIdentifier)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        extractAndSendURL()
    }

    private func extractAndSendURL() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            complete()
            return
        }

        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(urlType) {
                provider.loadItem(forTypeIdentifier: urlType, options: nil) { [weak self] (item, error) in
                    if let url = item as? URL {
                        self?.dispatchURL(url.absoluteString, title: nil)
                    } else {
                        self?.complete()
                    }
                }
                return
            } else if provider.hasItemConformingToTypeIdentifier(textType) {
                provider.loadItem(forTypeIdentifier: textType, options: nil) { [weak self] (item, error) in
                    if let text = item as? String, let url = URL(string: text), url.scheme != nil {
                        self?.dispatchURL(url.absoluteString, title: nil)
                    } else {
                        self?.complete()
                    }
                }
                return
            }
        }

        complete()
    }

    private func dispatchURL(_ urlString: String, title: String?) {
        let payload = OpenOnMacPayload(url: urlString, title: title)
        guard let payloadData = try? JSONEncoder().encode(payload),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            complete()
            return
        }

        let command = SyncCommand(
            kind: .openOnMac,
            targetDeviceID: "", // Broadcast to default / front Mac
            sourceDeviceName: "iPhone Share",
            payloadJSON: payloadJSON
        )

        // Write to App Group cache first for instant persistence
        saveToAppGroupFallback(command)

        // Attempt direct CloudKit push with 1.5s deadline
        let record = command.toRecord(zoneID: SyncConstants.commandsZoneID)
        let database = container.privateCloudDatabase

        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .allKeys
        operation.timeoutIntervalForRequest = 1.5

        operation.modifyRecordsResultBlock = { [weak self] _ in
            DispatchQueue.main.async {
                self?.complete()
            }
        }

        database.add(operation)

        // Fallback timer in case CloudKit is slow/offline
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.complete()
        }
    }

    private func saveToAppGroupFallback(_ command: SyncCommand) {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.theindie.FastTab") else {
            return
        }
        let pendingDir = groupURL.appendingPathComponent("pending_shares", isDirectory: true)
        try? FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let fileURL = pendingDir.appendingPathComponent("\(command.id).json")

        if let data = try? JSONEncoder().encode(command) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
