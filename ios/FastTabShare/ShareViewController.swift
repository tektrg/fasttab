import UIKit
import UniformTypeIdentifiers
import CloudKit
import FastTabSync

/// Share sheet offering two choices: send the link to the Mac (existing
/// `openOnMac` command path) or keep it on this iPhone only (local reading
/// list, never uploaded). Both choices dismiss silently once done.
final class ShareViewController: UIViewController {
    private let container = CKContainer(identifier: SyncConstants.containerIdentifier)

    private var sharedURLString: String?
    private var sharedTitle: String?
    private var didFinish = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        extractSharedURL()
    }

    // MARK: - Extraction

    private func extractSharedURL() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem else {
            complete()
            return
        }
        // Safari often fills the share title with the page title — reuse it so
        // both destinations show something better than the bare host.
        sharedTitle = item.attributedTitle?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let attachments = item.attachments, !attachments.isEmpty else {
            complete()
            return
        }

        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(urlType) {
                provider.loadItem(forTypeIdentifier: urlType, options: nil) { [weak self] (loaded, _) in
                    guard let self else { return }
                    if let url = loaded as? URL {
                        self.presentOptions(urlString: url.absoluteString)
                    } else if let str = loaded as? String, let url = URL(string: str), url.scheme != nil {
                        self.presentOptions(urlString: url.absoluteString)
                    } else {
                        self.complete()
                    }
                }
                return
            } else if provider.hasItemConformingToTypeIdentifier(textType) {
                provider.loadItem(forTypeIdentifier: textType, options: nil) { [weak self] (loaded, _) in
                    guard let self else { return }
                    if let text = loaded as? String, let url = URL(string: text), url.scheme != nil {
                        self.presentOptions(urlString: url.absoluteString)
                    } else {
                        self.complete()
                    }
                }
                return
            }
        }

        complete()
    }

    // MARK: - Options UI

    private func presentOptions(urlString: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didFinish else { return }
            self.sharedURLString = urlString
            self.showOptionsCard(urlString: urlString)
        }
    }

    private func showOptionsCard(urlString: String) {
        let dimView = UIView(frame: view.bounds)
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cancelTapped)))
        view.addSubview(dimView)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 20
        card.layer.masksToBounds = true
        view.addSubview(card)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        if let title = sharedTitle, !title.isEmpty {
            titleLabel.text = title
        } else {
            titleLabel.text = URL(string: urlString)?.host ?? urlString
        }

        let urlLabel = UILabel()
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.font = .preferredFont(forTextStyle: .footnote)
        urlLabel.textColor = .secondaryLabel
        urlLabel.textAlignment = .center
        urlLabel.numberOfLines = 2
        urlLabel.text = urlString

        let sendButton = makeActionButton(
            title: "Send to Mac",
            systemImage: "macbook.and.iphone",
            tint: .systemBlue,
            action: #selector(sendToMacTapped)
        )
        let saveButton = makeActionButton(
            title: "Save to iPhone",
            systemImage: "bookmark",
            tint: .systemGreen,
            action: #selector(saveToIPhoneTapped)
        )

        let cancelButton = UIButton(type: .system)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        cancelButton.setTitleColor(.secondaryLabel, for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, urlLabel, sendButton, saveButton, cancelButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),

            sendButton.heightAnchor.constraint(equalToConstant: 52),
            saveButton.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    private func makeActionButton(title: String, systemImage: String, tint: UIColor, action: Selector) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.image = UIImage(systemName: systemImage)
        config.imagePadding = 10
        config.baseBackgroundColor = tint
        config.baseForegroundColor = .white
        config.cornerStyle = .large
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .headline)
            return outgoing
        }
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    // MARK: - Actions

    @objc private func sendToMacTapped() {
        guard let urlString = sharedURLString else { complete(); return }
        dispatchToMac(urlString, title: sharedTitle)
    }

    @objc private func saveToIPhoneTapped() {
        guard let urlString = sharedURLString else { complete(); return }
        let host = URL(string: urlString)?.host
        let link = SavedOnIPhoneLink(
            url: urlString,
            title: (sharedTitle?.isEmpty == false) ? sharedTitle : host
        )
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SyncConstants.appGroupIdentifier
        ) {
            try? SavedOnIPhoneFiles.write(link, containerURL: groupURL)
        }
        complete()
    }

    @objc private func cancelTapped() {
        complete()
    }

    // MARK: - Send to Mac (unchanged path)

    private func dispatchToMac(_ urlString: String, title: String?) {
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
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SyncConstants.appGroupIdentifier) else {
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
        guard !didFinish else { return }
        didFinish = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
