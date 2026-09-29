import Foundation

/// Which picture the "Connect your Mac" hero shows, from the step's live state.
enum ConnectHeroState: Equatable {
    /// Radar rings pulse from the iPhone (loops while searching).
    case searching
    /// Mac slides in, link draws, green check (one-shot).
    case found
    /// Found, but the Mac has been silent a day or more: greyed Mac, moon, dotted link.
    case macOffline
    /// Dashed Mac outline with a "?".
    case notFound
    /// Signed out of iCloud or iCloud restricted: iCloud glyph with an orange slash.
    case accountBlocked

    init(connection: MacConnectionState, macIsOffline: Bool) {
        switch connection {
        case .searching: self = .searching
        case .found: self = macIsOffline ? .macOffline : .found
        case .notFound: self = .notFound
        case .signedOut, .restricted: self = .accountBlocked
        }
    }

    /// Timings follow the approved storyboard (`onboarding-motion.html`, iPhone card 2).
    var playback: HeroPlayback {
        switch self {
        case .searching: return .loop(period: 2.4, restAt: 0)
        case .found: return .once(duration: 2.2)
        case .macOffline: return .once(duration: 1.4)
        case .notFound: return .once(duration: 1.6)
        case .accountBlocked: return .once(duration: 1.5)
        }
    }
}

/// Which picture the "Read without the clutter" hero shows.
enum ReaderHeroState: Equatable {
    /// The article is still being fetched: a soft shimmer over the busy page.
    case preparing
    /// Clutter flies off, text settles into a clean column, a highlight sweeps.
    case ready

    init(isPreparing: Bool) {
        self = isPreparing ? .preparing : .ready
    }

    var playback: HeroPlayback {
        switch self {
        case .preparing: return .loop(period: 1.4, restAt: 0.7)
        case .ready: return .loop(period: 4.0, restAt: 3.0)
        }
    }
}

/// Which picture the "Send links to your Mac" hero shows.
enum SendHeroState: Equatable {
    /// Share sheet, tap FastTab, the plane flies to the Mac (loops).
    case teach
    /// The real "Try it" link reached the Mac: one flight, then the Mac's new tab glows.
    case sent
    /// No Mac yet: Mac drawn dashed, plane parked on the FastTab icon.
    case noMac

    /// A missing Mac outranks everything; only a link the Mac actually opened counts as sent.
    init(hasMac: Bool, tryProgress: CommandProgress?) {
        if !hasMac {
            self = .noMac
        } else if tryProgress?.stage == .succeeded {
            self = .sent
        } else {
            self = .teach
        }
    }

    var playback: HeroPlayback {
        switch self {
        case .teach: return .loop(period: 3.8, restAt: 3.0)
        case .sent: return .once(duration: 3.0)
        case .noMac: return .once(duration: 1.4)
        }
    }
}
