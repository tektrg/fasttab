import SwiftUI

public struct ReadingFolderChipsView: View {
    public let folders: [BookmarkFolderChip]
    @Binding public var selectedFolder: String?

    public init(folders: [BookmarkFolderChip], selectedFolder: Binding<String?>) {
        self.folders = folders
        self._selectedFolder = selectedFolder
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All" chip
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedFolder = nil
                    }
                } label: {
                    Text("All")
                        .font(.system(size: 13, weight: selectedFolder == nil ? .bold : .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            selectedFolder == nil
                                ? Color.primary
                                : ReadingFeedCardView.warmMutedFillColor
                        )
                        .foregroundColor(
                            selectedFolder == nil
                                ? Color(uiColor: .systemBackground)
                                : Color.primary
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                // Folder chips
                ForEach(folders) { chip in
                    let isSelected = (selectedFolder == chip.fullPath)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedFolder = isSelected ? nil : chip.fullPath
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isSelected ? "folder.fill" : "folder")
                                .font(.system(size: 11))
                            Text(chip.displayName)
                                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(
                            isSelected
                                ? Color.primary
                                : ReadingFeedCardView.warmMutedFillColor
                        )
                        .foregroundColor(
                            isSelected
                                ? Color(uiColor: .systemBackground)
                                : Color.primary
                        )
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
