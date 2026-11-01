import SwiftUI

/// Every Claude login account is at its limit and the router is holding requests until the user
/// allows the paid fallback (e.g. DeepSeek). Red, over the top of the body (an overlay, so the
/// fixed window height does not change); ⌘Y or a click approves. Nothing switches without it.
struct FallbackApprovalBanner: View {
    let pending: PendingFallbackApproval
    let isSending: Bool
    let onApprove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(Color.red)
            Text("All Claude accounts are at their limit. Continue on \(pending.displayLabel)?")
                .font(.avenir(size: 12, weight: .semibold))
                .foregroundStyle(Color.red)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isSending {
                ProgressView().controlSize(.small)
            } else {
                Button("Continue (⌘Y)", action: onApprove)
                    .keyboardShortcut("y", modifiers: .command)
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Let the router use \(pending.displayLabel) until a Claude account frees up")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
    }
}
