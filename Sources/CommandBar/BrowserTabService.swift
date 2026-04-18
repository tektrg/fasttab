import Foundation
import AppKit
import OSLog

// ASCII control characters guaranteed not to appear in URLs or page titles.
private let kFieldSep = "\u{1F}" // unit separator
private let kRowSep   = "\u{1C}" // file separator

// Key for lastActiveTimes: URL-based (no tab index) so it survives tab reordering.
private func activeKey(appName: String, url: String) -> String {
    "\(appName)|\(url)"
}

private func appleScriptQuoted(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

@MainActor
class BrowserTabService: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var isLoading: Bool = false
    private let logger = Logger(subsystem: "com.trungluong.CommandBar", category: "BrowserTabService")
    private var lastActiveTimes: [String: Date] = [:]
    private var fetchTask: Task<Void, Never>?

    func fetchTabs() {
        // Cancel any in-flight fetch and always start a fresh one so the sort
        // reflects the current browser state on every open.
        fetchTask?.cancel()
        logger.info("Starting tab fetch.")
        isLoading = true
        let cachedTimes = self.lastActiveTimes
        fetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var newTabs: [BrowserTab] = []
            var updatedTimes = cachedTimes
            let browsers = ["Google Chrome", "Microsoft Edge"]
            let fetchStart = Date()

            for browser in browsers {
                if Task.isCancelled { break }
                let script = """
                tell application "\(browser)"
                    if it is not running then return ""
                    set fieldSep to (ASCII character 31)
                    set rowSep to (ASCII character 28)
                    set tabData to ""
                    try
                        set winCount to count of windows
                        repeat with w from 1 to winCount
                            set activeTabIndex to active tab index of window w
                            set tabTitles to title of every tab of window w
                            set tabURLs to URL of every tab of window w
                            repeat with t from 1 to count of tabTitles
                                set isActive to (t is equal to activeTabIndex and w is equal to 1) as string
                                set rowData to "\(browser)" & fieldSep & w & fieldSep & t & fieldSep & (item t of tabTitles) & fieldSep & (item t of tabURLs) & fieldSep & isActive
                                if tabData is "" then
                                    set tabData to rowData
                                else
                                    set tabData to tabData & rowSep & rowData
                                end if
                            end repeat
                        end repeat
                    on error
                        return ""
                    end try
                    return tabData
                end tell
                """

                let task = Process()
                task.launchPath = "/usr/bin/osascript"
                task.arguments = ["-e", script]

                let pipe = Pipe()
                task.standardOutput = pipe

                do {
                    try task.run()
                    task.waitUntilExit()

                    if Task.isCancelled { task.terminate(); break }

                    if task.terminationStatus != 0 {
                        Logger(subsystem: "com.trungluong.CommandBar", category: "BrowserTabService")
                            .error("fetchTabs: osascript exited with status \(task.terminationStatus) for \(browser, privacy: .public)")
                        continue
                    }

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                        let rows = output.components(separatedBy: kRowSep)
                        for row in rows {
                            let parts = row.components(separatedBy: kFieldSep)
                            if parts.count >= 6 {
                                let appName = parts[0]
                                let winIdx = Int(parts[1]) ?? 1
                                let tabIdx = Int(parts[2]) ?? 1
                                let title = parts[3]
                                let url = parts[4]
                                let isActive = parts[5] == "true"
                                let key = activeKey(appName: appName, url: url)
                                let tab = BrowserTab(
                                    title: title,
                                    url: url,
                                    windowIndex: winIdx,
                                    tabIndex: tabIdx,
                                    appName: appName,
                                    lastActive: isActive ? fetchStart : (updatedTimes[key] ?? Date(timeIntervalSince1970: 0))
                                )
                                if isActive {
                                    updatedTimes[key] = fetchStart
                                }
                                newTabs.append(tab)
                            }
                        }
                    }
                } catch {
                    Logger(subsystem: "com.trungluong.CommandBar", category: "BrowserTabService")
                        .error("fetchTabs: failed to run osascript for \(browser, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }

            guard !Task.isCancelled else {
                await MainActor.run { self?.isLoading = false }
                return
            }

            let sortedTabs = newTabs.sorted {
                if $0.lastActive != $1.lastActive {
                    return $0.lastActive > $1.lastActive
                }
                return $0.title.localizedCompare($1.title) == .orderedAscending
            }

            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.logger.info("Tab fetch complete. tabCount=\(sortedTabs.count)")
                self.lastActiveTimes = updatedTimes
                self.tabs = sortedTabs
                self.isLoading = false
            }
        }
    }

    func activateTab(_ tab: BrowserTab) {
        lastActiveTimes[activeKey(appName: tab.appName, url: tab.url)] = Date()

        let safeURL = appleScriptQuoted(tab.url)
        let script = """
        tell application "\(tab.appName)"
            activate
            set targetURL to "\(safeURL)"
            set foundMatch to false
            try
                repeat with w in windows
                    set tabURLs to URL of every tab of w
                    repeat with i from 1 to count of tabURLs
                        if (item i of tabURLs) is equal to targetURL then
                            set index of w to 1
                            set active tab index of window 1 to i
                            set foundMatch to true
                            exit repeat
                        end if
                    end repeat
                    if foundMatch then exit repeat
                end repeat
            end try
            if foundMatch is false then
                try
                    set index of window \(tab.windowIndex) to 1
                    set active tab index of window 1 to \(tab.tabIndex)
                end try
            end if
        end tell
        """

        logger.info("activateTab: app=\(tab.appName, privacy: .public) title='\(tab.title, privacy: .public)' url='\(tab.url, privacy: .public)' window=\(tab.windowIndex) tab=\(tab.tabIndex)")

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                logger.error("activateTab: osascript exited with status \(task.terminationStatus) for tab '\(tab.title, privacy: .public)'")
            }
        } catch {
            logger.error("activateTab: failed to run osascript: \(String(describing: error), privacy: .public)")
        }
    }
}
