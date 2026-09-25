import Foundation

/// What the plan card shows for the plan file a plan-approval box names.
enum PlanFile: Equatable, Sendable {
    /// Still being read.
    case loading
    /// The box names no file.
    case noPath
    /// The file's text; `truncated` when it was longer than `PlanFileReader.maxBytes`.
    case text(String, truncated: Bool)
    /// The file could not be read: why, in words. Never blocks approval.
    case unreadable(String)
}

/// Reads a plan file for display: read-only, one `.md` file at an absolute or `~` path, at most
/// `maxBytes` of it. Runs off the main thread (see `PlanFileReader.load`).
enum PlanFileReader {
    /// A plan is a page or two; a file past this is cut and the card says so.
    static let maxBytes = 200 * 1024

    /// The default loader for the card: reads on a background thread.
    static let load: @Sendable (String?) async -> PlanFile = { path in
        await Task.detached(priority: .userInitiated) {
            read(path: path, home: FileManager.default.homeDirectoryForCurrentUser)
        }.value
    }

    static func read(path: String?, home: URL) -> PlanFile {
        guard let path = path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return .noPath }
        guard let url = resolvedURL(path, home: home) else {
            return .unreadable("AgentBar only reads a plan file at an absolute or ~ path ending in .md (\(path)).")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .unreadable("\(path) is not on this Mac — the agent may be running on a different machine.")
        }
        // Only a regular file: a folder, or a pipe that would block the read forever, is not a plan.
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            return .unreadable("\(path) is not a plain file.")
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // One byte past the cap tells "exactly the cap" from "longer".
            let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
            return text(from: data)
        } catch {
            return .unreadable("The plan file could not be read: \(path).")
        }
    }

    /// `~` expands against `home`; anything else must already be absolute, and a plan is always Markdown.
    private static func resolvedURL(_ path: String, home: URL) -> URL? {
        guard path.lowercased().hasSuffix(".md") else { return nil }
        if path == "~" || path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(path.hasPrefix("~/") ? 2 : 1)))
        }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }

    private static func text(from data: Data) -> PlanFile {
        let truncated = data.count > maxBytes
        var kept = truncated ? data.prefix(maxBytes) : data
        var decoded = String(decoding: kept, as: UTF8.self)
        if truncated {
            // The cut may split a multi-byte character: drop the broken tail rather than show a replacement mark.
            while decoded.unicodeScalars.last == "\u{FFFD}", !kept.isEmpty {
                kept = kept.dropLast()
                decoded = String(decoding: kept, as: UTF8.self)
            }
        }
        if decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .unreadable("The plan file is empty.")
        }
        return .text(decoded, truncated: truncated)
    }
}
