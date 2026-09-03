import SwiftUI
import FastTabSync

public enum IntelligenceSubTab: String, CaseIterable, Identifiable {
    case emerging = "Emerging"
    case suggestBookmarks = "Suggest Bookmarks"

    public var id: String { rawValue }
}

public struct IntelligenceView: View {
    @ObservedObject var service = IntelligenceService.shared
    @State private var selectedSubTab: IntelligenceSubTab = .emerging

    public init() {}

    public var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            Group {
                switch selectedSubTab {
                case .emerging:
                    EmergingTopicsView()
                case .suggestBookmarks:
                    SuggestBookmarksView()
                }
            }
        }
        .navigationTitle("Intelligence")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if service.isProcessing {
                    ProgressView()
                } else {
                    Button {
                        service.analyze(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            FloatingSubTabBar(
                selection: $selectedSubTab,
                iconProvider: { tab in
                    switch tab {
                    case .emerging: return "sparkles"
                    case .suggestBookmarks: return "folder.badge.gearshape"
                    }
                },
                titleProvider: { $0.rawValue }
            )
            .padding(.bottom, 8)
        }
        .onAppear {
            if service.topicClusters.isEmpty && service.folderSuggestions.isEmpty {
                service.analyze(force: false)
            }
        }
    }
}
