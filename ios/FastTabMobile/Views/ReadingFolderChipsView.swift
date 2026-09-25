import SwiftUI

/// Folder filter chips above the Read feed ("All" + one per bookmark folder).
public struct ReadingFolderChipsView: View {
    public let folders: [BookmarkFolderChip]
    @Binding public var selectedFolder: String?

    public init(folders: [BookmarkFolderChip], selectedFolder: Binding<String?>) {
        self.folders = folders
        self._selectedFolder = selectedFolder
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                DSChip("All", isSelected: selectedFolder == nil) {
                    selectedFolder = nil
                }

                ForEach(folders) { chip in
                    let isSelected = (selectedFolder == chip.fullPath)
                    DSChip(
                        chip.displayName,
                        systemImage: isSelected ? "folder.fill" : "folder",
                        isSelected: isSelected
                    ) {
                        selectedFolder = isSelected ? nil : chip.fullPath
                    }
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.sm)
        }
    }
}
