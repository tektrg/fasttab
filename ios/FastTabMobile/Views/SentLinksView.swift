import SwiftUI
import FastTabSync

public struct SentLinksView: View {
    @ObservedObject var localCache = LocalCache.shared

    @State private var inputURL: String = ""
    @State private var inputTitle: String = ""
    @State private var isSending: Bool = false
    @State private var showSendSuccess: Bool = false

    public init() {}

    private var sentCommands: [SyncCommand] {
        localCache.state.sentCommands
    }

    public var body: some View {
        List {
            Section(header: Text("Send Link to Mac")) {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    TextField("https://...", text: $inputURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    TextField("Optional title", text: $inputTitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button {
                        sendLinkNow()
                    } label: {
                        HStack {
                            Spacer()
                            if isSending {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            } else {
                                Label("Open on Mac", systemImage: "iphone.and.arrow.forward")
                                    .bold()
                            }
                            Spacer()
                        }
                        .padding(.vertical, DS.Space.sm)
                    }
                    .disabled(inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
                .padding(.vertical, DS.Space.xs)
            }
            .dsListRow()

            Section(header: Text("Recent Sent Links")) {
                if sentCommands.isEmpty {
                    Text("No links sent yet. Use the Share sheet from Safari or type a URL above.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, DS.Space.sm)
                } else {
                    ForEach(sentCommands) { cmd in
                        CommandRowView(
                            command: cmd,
                            progress: CommandProgress.of(
                                command: cmd,
                                delivery: localCache.delivery(forCommandID: cmd.id)
                            )
                        )
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
    }

    private func sendLinkNow() {
        let trimmed = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let formattedURL: String
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            formattedURL = "https://" + trimmed
        } else {
            formattedURL = trimmed
        }

        let title = inputTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        SyncConsumer.shared.sendOpenOnMac(
            url: formattedURL,
            title: title.isEmpty ? nil : title
        )

        inputURL = ""
        inputTitle = ""
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

private struct CommandRowView: View {
    let command: SyncCommand
    /// Where the request actually is, upload step included — not just what the
    /// Mac last said about it.
    let progress: CommandProgress

    private var payload: OpenOnMacPayload? {
        guard let data = command.payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OpenOnMacPayload.self, from: data)
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: progress.symbolName)
                .foregroundColor(progress.tint)
                .font(.system(size: 20))

            VStack(alignment: .leading, spacing: 3) {
                if let payload {
                    Text(payload.title ?? payload.url)
                        .font(DS.Font.body)
                        .lineLimit(1)
                    Text(payload.url)
                        .font(DS.Font.meta)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Command: \(command.kind.rawValue)")
                        .font(DS.Font.body)
                }

                HStack(spacing: 6) {
                    Text(command.issuedAt, style: .time)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(progress.label)
                        .font(DS.Font.tag)
                        .foregroundColor(progress.tint)
                        .lineLimit(1)
                }

                if let detail = progress.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.vertical, DS.Space.xs)
    }
}
