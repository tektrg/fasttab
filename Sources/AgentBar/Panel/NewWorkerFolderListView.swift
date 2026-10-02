import SwiftUI

/// New worker step 1: the personas (folders) in place of the agent list, filtered by the search box.
/// Hover selects, click picks (same as Return). Sized to `bodyHeight` like a card, since the window
/// frame is computed, not auto-sized (`AgentPanelMetrics`).
struct NewWorkerFolderListView: View {
    @ObservedObject var model: AgentPanelModel
    let bodyHeight: CGFloat

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: bodyHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch model.newWorker?.folders {
        case .loading, nil:
            message("Loading folders…", detail: nil)
        case .failed:
            message("Couldn't load folders", detail: "Is the chief dashboard running at \(model.dashboardAddress)?")
        case .loaded(let personas) where personas.allSatisfy(\.offline):
            message("No folders yet", detail: "Adopt one in Settings > Personas.")
        case .loaded:
            let folders = model.newWorkerFolders
            if folders.isEmpty {
                message("No matching folders", detail: nil)
            } else {
                list(folders)
            }
        }
    }

    private func list(_ folders: [Persona]) -> some View {
        let selectedName = model.newWorkerSelectedFolderName
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(folders, id: \.name) { folder in
                        NewWorkerFolderRow(folder: folder, isSelected: folder.name == selectedName)
                            .id(folder.name)
                            .onHover { inside in
                                if inside { model.selectNewWorkerFolder(named: folder.name) }
                            }
                            .onTapGesture { model.pickNewWorkerFolder(named: folder.name) }
                    }
                }
                .padding(.vertical, AgentPanelMetrics.listVerticalPadding)
            }
            .onChange(of: selectedName) {
                if let selectedName { proxy.scrollTo(selectedName) }
            }
        }
    }

    private func message(_ title: String, detail: String?) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One folder: persona name, then its folder address and description.
private struct NewWorkerFolderRow: View {
    let folder: Persona
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(folder.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .frame(height: AgentPanelMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Starts a new worker in this folder")
    }

    private var subtitle: String {
        folder.description.isEmpty ? folder.address : "\(folder.address) · \(folder.description)"
    }
}
