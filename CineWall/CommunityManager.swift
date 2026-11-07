import Cocoa

// MARK: - Community & Open Source Manager (v3.0 Tahoe Edition)

enum ProFeature {
    case folderImport
    case playlists
    case timer
    case lockScreenSync
    case smartSettings

    var title: String {
        switch self {
        case .folderImport: return "Folder Library"
        case .playlists: return "Playlists and Library"
        case .timer: return "Timer Controls"
        case .lockScreenSync: return "Lock Screen Sync"
        case .smartSettings: return "Smart Settings"
        }
    }

    var explanation: String {
        switch self {
        case .folderImport:
            return "Import local folders and keep a reusable wallpaper library."
        case .playlists:
            return "Create playlists, add videos in bulk, and filter playback by playlist."
        case .timer:
            return "Auto-rotate wallpapers with timer presets and custom intervals."
        case .lockScreenSync:
            return "Sync the active video wallpaper to your macOS lock screen."
        case .smartSettings:
            return "Smart pause, focus-aware rules, and battery-saving behavior."
        }
    }
}

enum ProAccessTier {
    case free
    case trial
    case pro
}

final class CommunityManager {
    static let shared = CommunityManager()

    // MARK: - Open Source Project Metadata
    let appName = "CineWall"
    let appVersion = "3.0"
    let editionName = "Tahoe Edition"
    let repositoryURL = URL(string: "https://github.com/saivinay1805/CineWall")!
    let issuesURL = URL(string: "https://github.com/saivinay1805/CineWall/issues")!
    let releasesURL = URL(string: "https://github.com/saivinay1805/CineWall/releases")!
    let licenseName = "MIT License"
    let licenseURL = URL(string: "https://github.com/saivinay1805/CineWall/blob/main/LICENSE")!
    let statusLine = "CineWall v3.0 Tahoe Edition • Free & Open Source"

    private init() {}

    // In CineWall v3, all features are permanently unlocked for everyone.
    var hasActivatedLicense: Bool { true }
    var tier: ProAccessTier { .pro }
    var tierName: String { "Open Source" }
    var isTrialActive: Bool { false }
    var hasUsedTrial: Bool { false }
    var remainingTrialDaysText: String { "Open Source" }

    func canUse(_ feature: ProFeature) -> Bool {
        return true
    }

    func openRepository() {
        NSWorkspace.shared.open(repositoryURL)
    }

    func openIssues() {
        NSWorkspace.shared.open(issuesURL)
    }

    func openReleases() {
        NSWorkspace.shared.open(releasesURL)
    }

    func openLicense() {
        NSWorkspace.shared.open(licenseURL)
    }
}

// Backwards-compatibility typealias
typealias ProManager = CommunityManager
