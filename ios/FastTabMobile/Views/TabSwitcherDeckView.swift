import SwiftUI
import FastTabSync

/// Full-screen iOS Multitasking App Switcher-style tab deck.
///
/// Faithfully reproduces the iOS App Switcher physics & layout:
/// - Full-screen immersive layout with atmospheric wallpaper backdrop featuring dynamic GPU blur
///   of the active tab's preview image
/// - Overlapping stacked cards matching native iOS multitasking layout (cards on the left
///   tuck underneath with non-linear clamped stacking, dark pill headers, and scale reduction)
/// - Robust local geometric hit-testing for direct tap-to-open and header close buttons on any card
/// - Rubber-band bounded horizontal drag paging that cleanly handles the first and last cards
/// - Vertical swipe-up gesture on cards to dismiss/close with spring physics & haptic feedback
/// - Live `WKWebView` webpage rendering, defaulting to OpenGraph image previews while loading
struct TabSwitcherDeckView: View {
    @ObservedObject var localCache = LocalCache.shared
    let device: SyncedDevice?
    @Binding var pendingCloses: [PendingTabClose]
    let initialTabID: String?
    let onDismiss: () -> Void

    @State private var activeIndex: CGFloat = 0
    @State private var dragTranslationX: CGFloat = 0
    @State private var verticalCardOffsets: [String: CGFloat] = [:]
    @State private var dragMode: DragMode = .none
    @State private var selectedURLForReader: URL?
    @State private var readerItem: ReaderNavigationItem?
    @State private var tabSaveRequest: TabSaveRequest?
    @State private var toast: String?
    @State private var expandingTabID: String?
    @State private var isExpanding: Bool = false
    /// Cached copy of the filtered tabs list. Recomputed only when the
    /// underlying data changes, not on every body evaluation (drag frames).
    @State private var cachedVisibleTabs: [SyncedTab] = []

    private enum DragMode: Equatable {
        case none
        case horizontal
        case vertical(tabID: String)
    }

    init(
        device: SyncedDevice? = nil,
        pendingCloses: Binding<[PendingTabClose]>,
        initialTabID: String? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.device = device
        self._pendingCloses = pendingCloses
        self.initialTabID = initialTabID
        self.onDismiss = onDismiss
    }

    private var activeDevice: SyncedDevice? {
        device ?? localCache.state.connectedMac
    }

    /// Recomputes the filtered visible tabs list. Call this sparingly (on data
    /// change or appear), not on every body evaluation.
    private func recomputeVisibleTabs() {
        let allTabs = localCache.state.tabs
        let filteredByDevice: [SyncedTab]
        if let targetDevice = activeDevice {
            filteredByDevice = allTabs.filter { $0.deviceID == targetDevice.id }
        } else {
            filteredByDevice = allTabs
        }
        cachedVisibleTabs = filteredByDevice.filter { !hiddenTabIDs.contains($0.id) }
    }

    // MARK: - Close Requests Tracking

    private func progress(for pending: PendingTabClose) -> CommandProgress? {
        guard let command = localCache.state.sentCommands.first(where: { $0.id == pending.commandID }) else {
            return nil
        }
        return CommandProgress.of(
            command: command,
            delivery: localCache.delivery(forCommandID: pending.commandID)
        )
    }

    private var trackedCloses: [TrackedTabClose] {
        pendingCloses.compactMap { pending in
            guard let progress = progress(for: pending) else { return nil }
            return TrackedTabClose(close: pending, progress: progress)
        }
    }

    private var hiddenTabIDs: Set<String> {
        Set(trackedCloses.filter { !$0.progress.isFailure }.map(\.close.tabID))
    }

    private func pruneFinishedCloses() {
        let liveTabIDs = Set(localCache.state.tabs.map(\.id))
        pendingCloses.removeAll { pending in
            guard let progress = progress(for: pending) else { return true }
            return progress.stage == .succeeded && !liveTabIDs.contains(pending.tabID)
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Immersive Wallpaper Backdrop
                switcherBackdrop

                VStack(spacing: 0) {
                    // Top Bar Header
                    topHeaderBar
                        .opacity(isExpanding ? 0 : 1)
                        .padding(.top, geometry.safeAreaInsets.top > 0 ? geometry.safeAreaInsets.top : DS.Space.xl)
                        .padding(.horizontal, DS.Space.gutter)
                        .padding(.bottom, DS.Space.sm)

                    PendingTabCloseStrip(tracked: trackedCloses) { close in
                        pendingCloses.removeAll { $0.tabID == close.tabID }
                    }
                    .opacity(isExpanding ? 0 : 1)
                    .animation(.easeInOut(duration: 0.2), value: trackedCloses)

                    if cachedVisibleTabs.isEmpty {
                        emptyStateView
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Stacked Overlapping Cards Deck
                        cardsDeckView
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .ignoresSafeArea()
            .onAppear {
                recomputeVisibleTabs()
                if let initialTabID, let index = cachedVisibleTabs.firstIndex(where: { $0.id == initialTabID }) {
                    activeIndex = CGFloat(index)
                }
            }
        }
        .onChange(of: localCache.state.tabs) {
            recomputeVisibleTabs()
            pruneFinishedCloses()
            let maxIndex = max(0, CGFloat(cachedVisibleTabs.count - 1))
            if activeIndex > maxIndex {
                activeIndex = maxIndex
            }
        }
        .onChange(of: pendingCloses) {
            recomputeVisibleTabs()
            let maxIndex = max(0, CGFloat(cachedVisibleTabs.count - 1))
            if activeIndex > maxIndex {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    activeIndex = maxIndex
                }
            }
        }
        .onChange(of: localCache.state.sentCommands) {
            // A close command that fails or expires on the Mac changes
            // hiddenTabIDs, so the previously-hidden tab must reappear.
            recomputeVisibleTabs()
        }
        .onChange(of: localCache.state.commandDeliveries) {
            recomputeVisibleTabs()
        }
        .fullScreenCover(item: $selectedURLForReader) { url in
            InAppBrowserView(url: url)
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $readerItem) { item in
            ReaderView(url: item.url, title: item.title, focusHighlightID: item.focusHighlightID)
        }
        .sheet(item: $tabSaveRequest) { request in
            BookmarkMovePicker(sourceDeviceID: request.tab.deviceID, title: "Save to…") { destination in
                saveTabAsBookmark(request.tab, to: destination)
            }
        }
        .dsToast($toast, bottomInset: DS.Space.xxl, onDark: true)
    }

    // MARK: - Backdrop

    private var switcherBackdrop: some View {
        LinearGradient(
            colors: [DS.Palette.deckTop, DS.Palette.deckBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onDismiss()
        }
    }

    // MARK: - Top Header Bar

    private var topHeaderBar: some View {
        HStack {
            // Device pill & Tab Count
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(DS.Font.cardTitle)
                    .foregroundStyle(.white.opacity(0.9))

                Text("\(cachedVisibleTabs.count) Open Tab\(cachedVisibleTabs.count == 1 ? "" : "s")")
                    .font(DS.Font.cardTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let deviceName = activeDevice?.name {
                    Text("•")
                        .foregroundStyle(.white.opacity(0.5))
                    Text(deviceName)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )

            Spacer()

            // Dismiss / Done Button
            Button {
                onDismiss()
            } label: {
                Text("Done")
                    .font(DS.Font.cardTitle)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.vertical, DS.Space.sm)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Cards Deck (Exact iOS App Switcher Stacking)

    private var cardsDeckView: some View {
        GeometryReader { deckGeo in
            let deckWidth = deckGeo.size.width
            let deckHeight = deckGeo.size.height
            let cardWidth = min(deckWidth * 0.74, 320)
            let cardHeight = min(deckHeight * 0.70, cardWidth * 1.95)
            let cardSize = CGSize(width: cardWidth, height: cardHeight)

            let effectiveActiveIndex = activeIndex - (dragTranslationX / (cardWidth * 0.85))

            // ── Virtualisation window ──────────────────────────────────
            // Only create SwiftUI view identities for cards within ±4 of the
            // effective index. This matches the existing isHidden thresholds
            // (d < -4.5 / d > 2.5) while giving a small margin for spring
            // overshoot. For a 50-tab deck this reduces ForEach from 50 → ~9.
            let windowLo = max(0, Int(floor(effectiveActiveIndex)) - 4)
            let windowHi = min(cachedVisibleTabs.count - 1, Int(ceil(effectiveActiveIndex)) + 4)
            let windowedTabs: [(index: Int, tab: SyncedTab)] = windowLo <= windowHi
                ? (windowLo...windowHi).map { i in (i, cachedVisibleTabs[i]) }
                : []

            ZStack {
                ForEach(windowedTabs, id: \.tab.id) { index, tab in
                    let isTarget = expandingTabID == tab.id
                    let d = CGFloat(index) - effectiveActiveIndex
                    let isNearActive = abs(CGFloat(index) - round(activeIndex)) <= 1
                    let transform = cardTransform(distance: d, cardWidth: cardWidth)
                    let verticalOffset = verticalCardOffsets[tab.id] ?? 0

                    let scaleTarget = (isTarget && isExpanding)
                        ? max(deckWidth / cardWidth, deckHeight / cardHeight)
                        : transform.scale

                    let xTarget = (isTarget && isExpanding) ? 0 : transform.xOffset
                    let yTarget = (isTarget && isExpanding) ? 0 : verticalOffset
                    let opacityTarget = isExpanding
                        ? (isTarget ? 1.0 : 0.0)
                        : transform.opacity

                    if !transform.isHidden || isTarget {
                        TabSwitcherViewCard(
                            tab: tab,
                            cardSize: cardSize,
                            isNearActive: isNearActive,
                            shouldLoadPreview: true,
                            isExpanding: isTarget && isExpanding,
                            dragOffsetY: isExpanding ? 0 : verticalOffset,
                            onSelect: {
                                animateCardOpen(tab)
                            },
                            onOpenInReader: {
                                var urlString = tab.url.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !urlString.lowercased().hasPrefix("http://") && !urlString.lowercased().hasPrefix("https://") {
                                    urlString = "https://" + urlString
                                }
                                if let url = URL(string: urlString) {
                                    readerItem = ReaderNavigationItem(url: url, title: tab.title)
                                }
                            },
                            onClose: {
                                dismissCard(tab, cardHeight: cardHeight)
                            },
                            onOpenOnMac: {
                                SyncConsumer.shared.sendOpenOnMac(
                                    url: tab.url,
                                    title: tab.title.isEmpty ? nil : tab.title
                                )
                                showToastHUD(message: "Sent to Mac")
                            },
                            onSaveBookmark: {
                                tabSaveRequest = TabSaveRequest(tab: tab)
                            },
                            onCopyURL: {
                                UIPasteboard.general.string = tab.url
                                showToastHUD(message: "URL Copied")
                            }
                        )
                        .scaleEffect(scaleTarget)
                        .opacity(opacityTarget)
                        .offset(x: xTarget, y: yTarget)
                        .zIndex(isTarget ? 999 : Double(index))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(unifiedDeckGesture(deckGeo: deckGeo, cardWidth: cardWidth, cardHeight: cardHeight))
        }
    }

    private func animateCardOpen(_ tab: SyncedTab) {
        guard !isExpanding else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        expandingTabID = tab.id
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            isExpanding = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            openTab(tab)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isExpanding = false
                expandingTabID = nil
            }
        }
    }

    private func openTab(_ tab: SyncedTab) {
        var urlString = tab.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.lowercased().hasPrefix("http://") && !urlString.lowercased().hasPrefix("https://") {
            urlString = "https://" + urlString
        }
        if let url = URL(string: urlString) {
            selectedURLForReader = url
        }
    }

    /// Computes the exact iOS Multitasking App Switcher overlapping transform with stack clamping:
    /// - Distance < 0: Cards to the left tuck underneath with non-linear progressive spacing,
    ///   clamped so they never fly off infinitely when scrolling to the right end
    /// - Distance > 0: Cards to the right slide in with standard gap and fade beyond viewport
    private func cardTransform(distance d: CGFloat, cardWidth: CGFloat) -> (xOffset: CGFloat, scale: CGFloat, opacity: Double, isHidden: Bool) {
        if d < 0 {
            // Left side stack (tucked underneath)
            let clampedD = max(-3.5, d)
            let x: CGFloat
            if d >= -1 {
                x = d * 75
            } else if d >= -2 {
                x = -75 + (d + 1) * 60
            } else if d >= -3 {
                x = -135 + (d + 2) * 45
            } else {
                x = -180 + (clampedD + 3) * 15
            }

            let s = max(0.80, 1.0 + d * 0.035)
            let o = max(0.0, min(1.0, 1.0 + Double(d) * 0.22))
            let isHidden = o <= 0.01 || d < -4.5
            return (x, s, o, isHidden)
        } else if d > 0 {
            // Right side sliding in
            let x = d * (cardWidth + 24)
            let s = max(0.85, 1.0 - d * 0.05)
            let o = max(0.0, min(1.0, 1.0 - Double(d) * 0.25))
            let isHidden = o <= 0.01 || d > 2.5
            return (x, s, o, isHidden)
        } else {
            return (0, 1.0, 1.0, false)
        }
    }

    // MARK: - Unified Gesture System

    private func unifiedDeckGesture(deckGeo: GeometryProxy, cardWidth: CGFloat, cardHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isExpanding else { return }
                switch dragMode {
                case .none:
                    if abs(value.translation.height) > abs(value.translation.width) && value.translation.height < -10 {
                        let currentIntIndex = Int(round(activeIndex))
                        if currentIntIndex >= 0 && currentIntIndex < cachedVisibleTabs.count {
                            let tab = cachedVisibleTabs[currentIntIndex]
                            dragMode = .vertical(tabID: tab.id)
                            verticalCardOffsets[tab.id] = value.translation.height
                        }
                    } else if abs(value.translation.width) > 6 && abs(value.translation.width) > abs(value.translation.height) {
                        dragMode = .horizontal
                        updateHorizontalDrag(translationX: value.translation.width, cardWidth: cardWidth)
                    }
                case .horizontal:
                    updateHorizontalDrag(translationX: value.translation.width, cardWidth: cardWidth)
                case .vertical(let tabID):
                    if value.translation.height < 0 {
                        verticalCardOffsets[tabID] = value.translation.height
                    } else {
                        verticalCardOffsets[tabID] = value.translation.height * 0.15
                    }
                }
            }
            .onEnded { value in
                guard !isExpanding else { return }
                let totalTranslation = hypot(value.translation.width, value.translation.height)

                // If movement was small (< 16pt) or no drag mode active, resolve as a tap
                if dragMode == .none || totalTranslation < 16 {
                    handleTap(at: value.startLocation, altLocation: value.location, deckGeo: deckGeo, cardWidth: cardWidth, cardHeight: cardHeight)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        dragTranslationX = 0
                    }
                    dragMode = .none
                    return
                }

                switch dragMode {
                case .horizontal:
                    // Controlled bounded paging: 1-2 cards per swipe
                    let directStep = -value.translation.width / (cardWidth * 0.6)
                    let velocityDelta = -(value.predictedEndTranslation.width - value.translation.width) / (cardWidth * 1.5)
                    let totalStep = directStep + velocityDelta
                    let deltaIndex = max(-2.0, min(2.0, round(totalStep)))
                    let targetIndex = max(0, min(CGFloat(cachedVisibleTabs.count - 1), round(activeIndex + deltaIndex)))
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        activeIndex = targetIndex
                        dragTranslationX = 0
                    }
                case .vertical(let tabID):
                    if let tab = cachedVisibleTabs.first(where: { $0.id == tabID }) {
                        let shouldClose = value.translation.height < -110 || value.predictedEndTranslation.height < -300
                        if shouldClose {
                            dismissCard(tab, cardHeight: cardHeight)
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                verticalCardOffsets[tabID] = 0
                            }
                        }
                    }
                case .none:
                    break
                }
                dragMode = .none
            }
    }

    private func updateHorizontalDrag(translationX: CGFloat, cardWidth: CGFloat) {
        var translation = translationX
        let currentEffective = activeIndex - (translation / (cardWidth * 0.85))

        // Rubber-band resistance at deck bounds
        if currentEffective < 0 {
            let over = -currentEffective
            translation = -( -activeIndex - (over * 0.3) ) * (cardWidth * 0.85)
        } else if currentEffective > CGFloat(cachedVisibleTabs.count - 1) {
            let over = currentEffective - CGFloat(cachedVisibleTabs.count - 1)
            translation = -( (CGFloat(cachedVisibleTabs.count - 1) + over * 0.3) - activeIndex ) * (cardWidth * 0.85)
        }
        dragTranslationX = translation
    }

    // MARK: - Robust Geometric Hit-Testing for Tap

    private func handleTap(at location: CGPoint, altLocation: CGPoint? = nil, deckGeo: GeometryProxy, cardWidth: CGFloat, cardHeight: CGFloat) {
        let deckCenterX = deckGeo.size.width / 2
        let deckCenterY = deckGeo.size.height / 2
        let effectiveActiveIndex = activeIndex - (dragTranslationX / (cardWidth * 0.85))

        // Check cards in reverse z-index order (from top of stack to bottom)
        for index in stride(from: cachedVisibleTabs.count - 1, through: 0, by: -1) {
            let tab = cachedVisibleTabs[index]
            let d = CGFloat(index) - effectiveActiveIndex
            let transform = cardTransform(distance: d, cardWidth: cardWidth)

            if transform.isHidden { continue }

            let cardCenterX = deckCenterX + transform.xOffset
            let cardCenterY = deckCenterY + (verticalCardOffsets[tab.id] ?? 0)
            let scaledW = cardWidth * transform.scale
            let totalHeight = (cardHeight + 52) * transform.scale

            let cardRect = CGRect(
                x: cardCenterX - scaledW / 2,
                y: cardCenterY - totalHeight / 2,
                width: scaledW,
                height: totalHeight
            )

            let hit = cardRect.contains(location) || (altLocation.map { cardRect.contains($0) } ?? false)
            if hit {
                // Check if tap hit the top-trailing close button region (50x50pt)
                let closeButtonRect = CGRect(
                    x: cardCenterX + scaledW / 2 - 50 * transform.scale,
                    y: cardCenterY - totalHeight / 2,
                    width: 50 * transform.scale,
                    height: 50 * transform.scale
                )

                let hitClose = closeButtonRect.contains(location) || (altLocation.map { closeButtonRect.contains($0) } ?? false)
                if hitClose {
                    dismissCard(tab, cardHeight: cardHeight)
                } else {
                    animateCardOpen(tab)
                }
                return
            }
        }

        // Tap was outside all cards (on empty backdrop) -> dismiss switcher
        onDismiss()
    }

    private func dismissCard(_ tab: SyncedTab, cardHeight: CGFloat) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) {
            verticalCardOffsets[tab.id] = -cardHeight - 450
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            requestClose(of: tab)
            verticalCardOffsets.removeValue(forKey: tab.id)
            let maxIndex = max(0, CGFloat(cachedVisibleTabs.count - 2))
            if activeIndex > maxIndex {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    activeIndex = maxIndex
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        DSEmptyState(
            "No Open Tabs",
            systemImage: "macwindow.on.rectangle",
            message: "All synced tabs have been closed.",
            tint: .white.opacity(0.5)
        ) {
            Button {
                onDismiss()
            } label: {
                Text("Return to Tabs")
            }
            .buttonStyle(.dsPrimary)
        }
        // The deck is dark in both appearances, so the empty state's text must be too.
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Close Logic

    private func requestClose(of tab: SyncedTab) {
        let knownCommandIDs = Set(localCache.state.sentCommands.map(\.id))
        SyncConsumer.shared.sendCloseTab(tab)

        guard let issued = localCache.state.sentCommands.first(where: { !knownCommandIDs.contains($0.id) }) else {
            showToastHUD(message: "Couldn't queue close — tab is still open")
            return
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
            pendingCloses.removeAll { $0.tabID == tab.id }
            pendingCloses.append(PendingTabClose(
                tabID: tab.id,
                commandID: issued.id,
                tabTitle: tab.title.isEmpty ? tab.url : tab.title
            ))
        }
        showToastHUD(message: closeAcknowledgement)
    }

    private var closeAcknowledgement: String {
        if SyncConsumer.shared.syncHealth.isBlocked {
            return "Saved on iPhone — sync is off, so Mac hasn't been told"
        }
        return "Close queued for \(activeDevice?.name ?? "your Mac")"
    }

    private func saveTabAsBookmark(_ tab: SyncedTab, to destination: BookmarkMoveDestination) {
        let title = tab.title.isEmpty ? (URL(string: tab.url)?.host() ?? tab.url) : tab.title
        SyncConsumer.shared.sendAddBookmark(
            title: title,
            url: tab.url,
            destinationBrowserName: destination.browserName,
            destinationProfileName: destination.profileName,
            destinationFolderPath: destination.folderPath,
            targetDeviceID: tab.deviceID
        )
        let deviceName = localCache.state.devices.first { $0.id == tab.deviceID }?.name ?? "your Mac"
        showToastHUD(message: "Save queued for \(deviceName)")
    }

    private func showToastHUD(message: String) {
        toast = message
    }

    private struct TabSaveRequest: Identifiable {
        let tab: SyncedTab
        var id: String { tab.id }
    }
}
