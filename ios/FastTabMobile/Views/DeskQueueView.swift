import SwiftUI
import FastTabSync

public struct DeskQueueView: View {
    @ObservedObject var localCache = LocalCache.shared

    @State private var inputURL: String = ""
    @State private var inputTitle: String = ""
    @State private var selectedBrowser: String = "Default"
    @State private var isSending: Bool = false
    @State private var readerItem: ReaderNavigationItem?
    @State private var toast: String?

    private let supportedBrowsers = ["Default", "Google Chrome", "Safari", "Arc", "Microsoft Edge"]

    public init() {}

    private var sentCommands: [SyncCommand] {
        localCache.state.sentCommands.sorted { $0.issuedAt > $1.issuedAt }
    }

    private func progress(for command: SyncCommand) -> CommandProgress {
        CommandProgress.of(
            command: command,
            delivery: localCache.delivery(forCommandID: command.id)
        )
    }

    /// Only a request still sitting on this phone can genuinely be called off.
    /// Once iCloud has it, the Mac will act on it whatever this list shows.
    private func isCancellable(_ command: SyncCommand) -> Bool {
        progress(for: command).stage == .waitingToUpload
    }

    /// Swipe-away, told apart honestly: a real cancellation, versus tidying a
    /// row for something that is already on its way and will still happen.
    private func stopOrRemove(_ command: SyncCommand) {
        if isCancellable(command) {
            SyncConsumer.shared.cancelQueuedCommand(id: command.id)
            showToastHUD(message: "Cancelled — it never left this iPhone")
            return
        }

        let wasUnfinished = !progress(for: command).isSettled
        localCache.removeSentCommand(id: command.id)
        if wasUnfinished {
            showToastHUD(message: "Removed from the list — your Mac will still open it")
        }
    }

    /// Emptying the list must not quietly leave requests in the outbox. Anything
    /// still on the phone is genuinely called off; anything already uploaded is
    /// only removed from view, and the user is told so.
    private func clearList() {
        let cancellableIDs = sentCommands.filter(isCancellable).map(\.id)
        let alreadyOnItsWayCount = sentCommands.filter { !isCancellable($0) && !progress(for: $0).isSettled }.count

        for id in cancellableIDs {
            SyncConsumer.shared.cancelQueuedCommand(id: id)
        }
        localCache.clearAllSentCommands()

        if alreadyOnItsWayCount > 0 {
            let subject = alreadyOnItsWayCount == 1 ? "1 link is" : "\(alreadyOnItsWayCount) links are"
            showToastHUD(message: "List cleared — \(subject) already on the way to your Mac")
        }
    }

    public var body: some View {
        queueList
            .dsToast($toast, bottomInset: DS.Space.xl)
    }

    private var queueList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                            .font(.system(size: DS.IconSize.row))

                        TextField("https://...", text: $inputURL)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    }

                    TextField("Optional title or note", text: $inputTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack {
                        Picker("Target Browser", selection: $selectedBrowser) {
                            ForEach(supportedBrowsers, id: \.self) { b in
                                Text(b).tag(b)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.secondary)

                        Spacer()

                        Button {
                            sendLink()
                        } label: {
                            HStack(spacing: DS.Space.sm) {
                                if isSending {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "paperplane.fill")
                                    Text("Send to Mac")
                                }
                            }
                        }
                        .buttonStyle(.dsPrimary)
                        .disabled(inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                    }
                    .padding(.top, DS.Space.xs)
                }
                .padding(.vertical, DS.Space.xs)
            } header: {
                Text("Staged Link")
            } footer: {
                Text("Links go out to your Mac as soon as this iPhone can reach iCloud. A sleeping Mac opens them when it wakes.")
            }
            .dsListRow()

            Section {
                if sentCommands.isEmpty {
                    Text("No links sent yet. Use the share sheet or enter a URL above.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, DS.Space.sm)
                } else {
                    ForEach(sentCommands) { cmd in
                        DeskQueueRowView(
                            command: cmd,
                            progress: progress(for: cmd),
                            onOpenInReader: { url, title in
                                readerItem = ReaderNavigationItem(url: url, title: title)
                            }
                        )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    stopOrRemove(cmd)
                                } label: {
                                    isCancellable(cmd)
                                        ? Label("Cancel", systemImage: "xmark.circle")
                                        : Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("Sent & Queued")
                    Spacer()
                    if !sentCommands.isEmpty {
                        Button("Clear All") {
                            clearList()
                        }
                        .font(DS.Font.meta)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .dsListRow()
        }
        .listStyle(.insetGrouped)
        .dsListStyle()
        .refreshable {
            await SyncConsumer.shared.refreshNow()
        }
        .fullScreenCover(item: $readerItem) { item in
            ReaderView(url: item.url, title: item.title)
        }
    }

    private func sendLink() {
        let trimmed = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let formattedURL: String
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            formattedURL = "https://" + trimmed
        } else {
            formattedURL = trimmed
        }

        let title = inputTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferBrowser = (selectedBrowser == "Default") ? nil : selectedBrowser

        isSending = true
        SyncConsumer.shared.sendOpenOnMac(
            url: formattedURL,
            title: title.isEmpty ? nil : title,
            preferBrowser: preferBrowser
        )

        inputURL = ""
        inputTitle = ""
        isSending = false

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        // Nothing has reached the Mac yet — the row below now says where it is.
        showToastHUD(
            message: SyncConsumer.shared.syncHealth.isBlocked
                ? "Saved on this iPhone — sync is off, so your Mac hasn't been told"
                : "Queued for your Mac"
        )
    }

    private func showToastHUD(message: String) {
        toast = message
    }
}

private struct DeskQueueRowView: View {
    let command: SyncCommand
    /// Where the request actually is, upload step included — not just what the
    /// Mac last said about it.
    let progress: CommandProgress
    let onOpenInReader: (URL, String) -> Void

    private var payload: OpenOnMacPayload? {
        guard let data = command.payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OpenOnMacPayload.self, from: data)
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: progress.symbolName)
                .foregroundStyle(progress.tint)
                .font(.system(size: DS.IconSize.row))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                if let payload {
                    Text(payload.title ?? payload.url)
                        .font(.body)
                        .lineLimit(1)
                    Text(payload.url)
                        .font(DS.Font.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Command: \(command.kind.rawValue)")
                        .font(.body)
                }

                HStack(spacing: DS.Space.xs) {
                    Text(command.issuedAt, style: .time)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(progress.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(progress.tint)
                        .lineLimit(1)

                    if let browser = payload?.preferBrowser {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(browser)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // The Mac's own words for why, when it sent any.
                if let detail = progress.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.vertical, DS.Space.xxs)
        .contextMenu {
            if let payload, let url = URL(string: payload.url) {
                Button {
                    onOpenInReader(url, payload.title ?? payload.url)
                } label: {
                    Label("Open in Reader", systemImage: "doc.plaintext")
                }

                Link(destination: url) {
                    Label("Open in Safari", systemImage: "safari")
                }

                ShareLink(item: url) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }

                Button {
                    UIPasteboard.general.string = payload.url
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
            }
        }
    }
}
