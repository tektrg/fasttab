import SwiftUI

/// The reader's "Summary" sheet: consent (first time), progress, the summary, or a plain reason.
struct ReaderSummarySheet: View {
    let model: ReaderSummaryModel
    /// Opens the paywall / sign-in when the server says a subscription or account is needed.
    var onNeedsPaywall: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.gutter)
            }
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task { model.open() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .needsConsent:
            consentCard
        case .loading:
            HStack(spacing: DS.Space.sm) {
                ProgressView()
                Text("Reading the article…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .ready(let result):
            summaryBody(result)
        case .failed(let failure):
            failureCard(failure)
        }
    }

    private var consentCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Label(ReaderSummaryConsent.title, systemImage: "sparkles").font(.title3.bold())
            Text(ReaderSummaryConsent.message).font(.body).foregroundStyle(.secondary)
            Button { model.acceptConsent() } label: {
                Text("Summarize").font(.headline).frame(maxWidth: .infinity).padding(.vertical, DS.Space.sm)
            }
            .buttonStyle(.borderedProminent)
            Button("Not Now") { dismiss() }.frame(maxWidth: .infinity)
        }
    }

    private func summaryBody(_ result: ReaderSummaryResult) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if result.madeWithOtherPrompt {
                Label("Written with your previous prompt. Regenerate to use the new one.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let failure = model.regenerateFailure {
                Label("Couldn't refresh. \(failure.message())", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(SummaryMarkdown.blocks(result.text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            Divider()
            HStack {
                Text("Written by AI from this page's text. It can make mistakes.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Button { UIPasteboard.general.string = result.text } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Spacer()
                if model.isRegenerating {
                    HStack(spacing: DS.Space.sm) { ProgressView(); Text("Refreshing…") }
                        .accessibilityElement(children: .combine)
                } else {
                    Button { model.regenerate() } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                }
            }
            .font(.subheadline)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: SummaryMarkdown.Block) -> some View {
        switch block {
        case .heading(let text):
            Text(SummaryMarkdown.attributed(text)).font(.headline).accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(SummaryMarkdown.attributed(text)).font(.body)
        case .bullet(let level, let text):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(SummaryMarkdown.attributed(text)).font(.callout)
            }
            .padding(.leading, CGFloat(level) * DS.Space.lg)
        }
    }

    private func failureCard(_ failure: ReaderSummaryFailure) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Label(failure.message(), systemImage: "exclamationmark.circle").font(.body)
            if failure.needsPaywall {
                Button("See plans") { onNeedsPaywall(); dismiss() }.buttonStyle(.borderedProminent)
            } else if failure.canRetry {
                Button("Try Again") { model.retry() }.buttonStyle(.bordered)
            }
        }
    }
}
