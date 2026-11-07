import Cocoa
import AVFoundation
import CryptoKit
import ServiceManagement
import QuartzCore
import IOKit.ps
import Security
import VideoToolbox

let liquidMenuWidth: CGFloat = 370
let liquidMenuHeight: CGFloat = 610
let cineWallAerialCategoryID = "91F55C9A-8E4B-4C1D-9A8C-2B759F17A001"
let cineWallAerialSubcategoryID = "91F55C9A-8E4B-4C1D-9A8C-2B759F17A002"
let cineWallWallpaperStoreBackupFileName = "Index.pre-cinewall.plist"

enum IdleWallpaperSyncMode: String {
    case fast
    case compatible
}

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
            return "Import a local folder and keep a reusable wallpaper library."
        case .playlists:
            return "Create playlists, add videos in bulk, and filter playback by playlist."
        case .timer:
            return "Auto-rotate wallpapers with timer presets and custom intervals."
        case .lockScreenSync:
            return "Sync the current wallpaper to the macOS lock screen."
        case .smartSettings:
            return "Unlock smart pause, focus-aware rules, and battery behavior."
        }
    }
}

enum ProAccessTier {
    case free
    case trial
    case pro
}

final class ProManager {
    static let shared = ProManager()

    private let defaultActivationEndpoint = "https://cinewall-site.vercel.app/api/activate-license"
    private let defaultDeactivationEndpoint = "https://cinewall-site.vercel.app/api/deactivate-license"
    private let defaultTrialEndpoint = "https://cinewall-site.vercel.app/api/trial-status"
    private let trialStartKey = "cinewall.pro.trialStartDate"
    private let trialConsumedKey = "cinewall.pro.trialConsumed"
    private let activationURLKey = "cinewall.pro.activationURL"
    #if DEBUG
    private let developerUnlockKey = "cinewall.pro.developerUnlock"
    #endif
    #if DEBUG
    private let keychainService = "com.cinewall.pro.debug"
    #else
    private let keychainService = "com.cinewall.pro.release"
    #endif
    private let keychainAccount = "licenseKey"
    private let activationInstanceAccount = "activationInstanceID"
    private let trialStateAccount = "trialState"
    private let installIDAccount = "installID"
    private let trialLength: TimeInterval = 7 * 24 * 60 * 60

    private init() {}

    private struct TrialState: Codable {
        var startDate: Date?
        var expiresAt: Date?
        var hasConsumed: Bool
    }

    var activationURL: URL? {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: activationURLKey) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let url = URL(string: trimmed) {
                return url
            }
        }
        #endif
        return URL(string: defaultActivationEndpoint)
    }

    var trialStatusURL: URL? {
        URL(string: defaultTrialEndpoint)
    }

    var deactivationURL: URL? {
        URL(string: defaultDeactivationEndpoint)
    }

    func configureActivationURL(_ rawValue: String) {
        #if DEBUG
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: activationURLKey)
        #endif
    }

    var hasActivatedLicense: Bool {
        return true
    }

    var tier: ProAccessTier {
        return .pro
    }

    var tierName: String {
        return "Open Source"
    }

    var isTrialActive: Bool {
        guard let expiryDate = trialExpiryDate else { return false }
        return Date() < expiryDate
    }

    var hasUsedTrial: Bool {
        trialState.hasConsumed
    }

    var trialStartDate: Date? {
        trialState.startDate
    }

    var trialExpiryDate: Date? {
        if let expiresAt = trialState.expiresAt {
            return expiresAt
        }
        guard let startDate = trialState.startDate else { return nil }
        return startDate.addingTimeInterval(trialLength)
    }

    var remainingTrialDaysText: String {
        guard let expiryDate = trialExpiryDate else { return "0 days left" }
        let remaining = max(0, expiryDate.timeIntervalSinceNow)
        let days = Int(ceil(remaining / (24 * 60 * 60)))
        return "\(days) day" + (days == 1 ? "" : "s") + " left"
    }

    func canUse(_ feature: ProFeature) -> Bool {
        return true
    }

    var installID: String {
        if let data = keychainCopy(account: installIDAccount),
           let existing = String(data: data, encoding: .utf8),
           !existing.isEmpty {
            return existing
        }

        let newID = UUID().uuidString.lowercased()
        if let data = newID.data(using: .utf8) {
            keychainSave(data: data, account: installIDAccount)
        }
        return newID
    }

    func updateServerTrial(startDate: Date?, expiresAt: Date?, hasConsumed: Bool) {
        saveTrialState(TrialState(startDate: startDate, expiresAt: expiresAt, hasConsumed: hasConsumed))
    }

    @discardableResult
    func startLegacyTrialFallback() -> Bool {
        guard !hasActivatedLicense else { return true }
        guard !isTrialActive, !hasUsedTrial else { return false }
        let startDate = Date()
        saveTrialState(TrialState(startDate: startDate, expiresAt: startDate.addingTimeInterval(trialLength), hasConsumed: true))
        return true
    }

    var statusLine: String {
        return "CineWall Open Source — All features unlocked."
    }

    var licenseKey: String? {
        guard let data = keychainCopy(account: keychainAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func storeLicenseKey(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }
        keychainSave(data: data, account: keychainAccount)
    }

    var activationInstanceID: String? {
        guard let data = keychainCopy(account: activationInstanceAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func storeActivationInstanceID(_ id: String) {
        guard let data = id.data(using: .utf8) else { return }
        keychainSave(data: data, account: activationInstanceAccount)
    }

    #if DEBUG
    var isDeveloperUnlocked: Bool {
        UserDefaults.standard.bool(forKey: developerUnlockKey)
    }

    func setDeveloperUnlocked(_ unlocked: Bool) {
        UserDefaults.standard.set(unlocked, forKey: developerUnlockKey)
    }

    func resetDebugProState() {
        keychainDelete(account: keychainAccount)
        keychainDelete(account: activationInstanceAccount)
        keychainDelete(account: trialStateAccount)
        UserDefaults.standard.removeObject(forKey: developerUnlockKey)
        UserDefaults.standard.removeObject(forKey: trialStartKey)
        UserDefaults.standard.removeObject(forKey: trialConsumedKey)
        saveTrialState(TrialState(startDate: nil, expiresAt: nil, hasConsumed: false))
        let freshInstallID = UUID().uuidString.lowercased()
        if let data = freshInstallID.data(using: .utf8) {
            keychainSave(data: data, account: installIDAccount)
        }
    }
    #else
    var isDeveloperUnlocked: Bool { false }
    #endif

    private var trialState: TrialState {
        if let data = keychainCopy(account: trialStateAccount),
           let decoded = try? JSONDecoder().decode(TrialState.self, from: data) {
            return decoded
        }

        let defaults = UserDefaults.standard
        let migratedState = TrialState(
            startDate: defaults.object(forKey: trialStartKey) as? Date,
            expiresAt: nil,
            hasConsumed: defaults.bool(forKey: trialConsumedKey)
        )

        if migratedState.startDate != nil || migratedState.hasConsumed {
            saveTrialState(migratedState)
            defaults.removeObject(forKey: trialStartKey)
            defaults.removeObject(forKey: trialConsumedKey)
        }

        return migratedState
    }

    private func saveTrialState(_ state: TrialState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        keychainSave(data: data, account: trialStateAccount)
    }

    private func keychainSave(data: Data, account: String) {
        #if DEBUG
        UserDefaults.standard.set(data, forKey: debugStorageKey(for: account))
        return
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var saveQuery = query
        saveQuery[kSecValueData as String] = data
        SecItemAdd(saveQuery as CFDictionary, nil)
    }

    private func keychainCopy(account: String) -> Data? {
        #if DEBUG
        return UserDefaults.standard.data(forKey: debugStorageKey(for: account))
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func keychainDelete(account: String) {
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: debugStorageKey(for: account))
        return
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    #if DEBUG
    private func debugStorageKey(for account: String) -> String {
        "debug.\(keychainService).\(account)"
    }
    #endif
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    static let favoritesPlaylistName = "Favorites"
    static let appWebsiteURL = URL(string: "https://cinewall-site.vercel.app")!
    static let proCheckoutURL = URL(string: "https://cinewall.lemonsqueezy.com/checkout/buy/d2f284a4-a146-4c63-a50e-a71e99e5fbb2")!
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // --- UI ENGINE ---
    var statusItem: NSStatusItem!
    var liquidWindow: LiquidPanel?
    var liquidController: LiquidMenuController?
    var popoverTransiency: Any?
    var isPinned: Bool = false
    let proManager = ProManager.shared
    let sparkleUpdater = SparkleUpdater.shared

    // --- WALLPAPER ENGINE ---
    var wallpaperWindow: ClickableWindow?
    var ghostWindow: NSWindow?
    var playerA: AVPlayer?
    var playerB: AVPlayer?
    var layerA: AVPlayerLayer?
    var layerB: AVPlayerLayer?
    var activePlayerIndex: Int = 0
    var gifView: NSImageView?
    var pendingVideoReadyObservation: NSKeyValueObservation?
    var pendingHiddenLayerCleanupWorkItem: DispatchWorkItem?
    
    // --- STATE ---
    var allFiles: [URL] = []
    var currentQueue: [URL] = []
    var playlists: [String: [String]] = [AppDelegate.favoritesPlaylistName: []]
    var queueIndex: Int = 0
    var videoEndObserver: Any?
    var timeObserver: Any?
    weak var timeObserverOwner: AVPlayer?
    var isSeeking = false
    
    // Timers
    var playlistTimer: Timer?
    var pauseWorkItem: DispatchWorkItem?
    var statsTimer: Timer?
    var gifTimer: Timer? // NEW: To handle GIF duration
    
    // --- SETTINGS ---
    var isMuted: Bool = false
    var volumeLevel: Float = 0.5
    var isShuffle: Bool = false
    var isManualPaused: Bool = false
    var isLoopingCurrent: Bool = false
    var isPlaylistFilterEnabled: Bool = false
    var selectedPlaylistName: String = AppDelegate.favoritesPlaylistName
    var scalingTag: Int = 1
    var autoChangeInterval: Double = 0
    var showOnAllSpaces: Bool = false
    var syncedAerialAssetID: String?
    var lockScreenSyncEnabled: Bool = false
    var autoSyncIdleWallpaper: Bool = false
    var lastAutoSyncedMediaPath: String?
    var idleSyncWorkItem: DispatchWorkItem?
    var idleWallpaperSyncMode: IdleWallpaperSyncMode = .compatible
    var idleWallpaperSyncInProgress: Bool = false
    var lastCompatibleSyncDebugSummary: String?
    var menuDarkTintStrength: Double = 0.0
    let idleWallpaperSyncQueue = DispatchQueue(label: "CineWall.IdleWallpaperSyncQueue", qos: .userInitiated)
    let idleWallpaperSyncStateQueue = DispatchQueue(label: "CineWall.IdleWallpaperSyncStateQueue")
    var idleWallpaperSyncRequestCounter: Int = 0
    var latestIdleWallpaperSyncRequestID: Int = 0
    var activeIdleWallpaperProcess: Process?
    let thumbnailCache = NSCache<NSString, NSImage>()

    var analyticsDeviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    var analyticsOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    var analyticsArchitecture: String {
        Self.isRunningOnAppleSilicon ? "Apple Silicon" : "Intel"
    }

    var analyticsAppVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }

    static var isRunningOnAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }
    
    // Smart Rules
    var smartPauseEnabled: Bool = true
    var batterySaverEnabled: Bool = false
    var focusPauseEnabled: Bool = false
    var focusMuteEnabled: Bool = false
    var hideDesktopIcons: Bool = false
    
    var lastFolderPath: String?
    var lastPlayedFile: String? // NEW: Remembers exact file
    var targetScreen: NSScreen?

    var favorites: [String] {
        get { playlists[Self.favoritesPlaylistName] ?? [] }
        set { playlists[Self.favoritesPlaylistName] = deduplicatedPaths(newValue) }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadSettings()
        syncAccessControlledState()
        ensurePlaylists()
        restoreFinder()
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(named: "menubar_icon") {
                img.isTemplate = true
                img.size = NSSize(width: 35, height: 35)
                let newImg = NSImage(size: NSSize(width: 35, height: 35))
                newImg.lockFocus()
                img.draw(in: NSRect(x: 0, y: -3, width: 35, height: 35), from: .zero, operation: .sourceOver, fraction: 1.0)
                newImg.unlockFocus()
                newImg.isTemplate = true
                button.image = newImg
            } else {
                button.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: "CineWall")
            }
            button.action = #selector(toggleLiquidPopover)
            button.target = self
        }
        
        targetScreen = NSScreen.main
        createWindow()
        createGhostWindow()
        createLiquidPopover()
        applyWindowLevel()
        refreshServerTrialStatus(silent: true)
        setupObservers()
        startStatsMonitor()
        
        // AUTO-LOAD LOGIC
        if let savedPath = lastFolderPath {
            let url = URL(fileURLWithPath: savedPath)
            checkAndLoad(url: url)
        }
        scheduleFastModeLaunchRefreshIfNeeded()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        if idleWallpaperSyncMode == .fast {
            try? setDesktopWallpaperSnapshotForCurrentMedia()
            try? clearIdleWallpaperStateForFastModeQuit()
        }
        saveSettings()
    }

    func deduplicatedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for path in paths where !path.isEmpty && !seen.contains(path) {
            seen.insert(path)
            ordered.append(path)
        }
        return ordered
    }

    func thumbnailCacheKey(for url: URL) -> NSString {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(url.path)|\(Int64(modified * 1000))|\(size)" as NSString
    }

    func ensurePlaylists() {
        if playlists[Self.favoritesPlaylistName] == nil {
            playlists[Self.favoritesPlaylistName] = []
        }
        playlists = playlists.reduce(into: [:]) { partial, entry in
            partial[entry.key] = deduplicatedPaths(entry.value)
        }
        if playlists[selectedPlaylistName] == nil {
            selectedPlaylistName = Self.favoritesPlaylistName
        }
    }

    func orderedPlaylistNames() -> [String] {
        let customNames = playlists.keys
            .filter { $0 != Self.favoritesPlaylistName }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return [Self.favoritesPlaylistName] + customNames
    }

    func playlistEntries(named playlistName: String) -> [String] {
        playlists[playlistName] ?? []
    }

    func containsVideo(path: String, inPlaylist playlistName: String) -> Bool {
        playlistEntries(named: playlistName).contains(path)
    }

    func addVideo(path: String, toPlaylist playlistName: String) {
        ensurePlaylists()
        var items = playlistEntries(named: playlistName)
        guard !items.contains(path) else { return }
        items.append(path)
        playlists[playlistName] = items
    }

    func removeVideo(path: String, fromPlaylist playlistName: String) {
        guard var items = playlists[playlistName] else { return }
        items.removeAll { $0 == path }
        playlists[playlistName] = items
    }

    func toggleVideo(path: String, inPlaylist playlistName: String) {
        if containsVideo(path: path, inPlaylist: playlistName) {
            removeVideo(path: path, fromPlaylist: playlistName)
        } else {
            addVideo(path: path, toPlaylist: playlistName)
        }
        saveSettings()
        liquidController?.refreshUI()
        if isPlaylistFilterEnabled && selectedPlaylistName == playlistName {
            refreshQueue()
            startPlayback()
        } else if !currentQueue.isEmpty && currentQueue[queueIndex].path == path {
            liquidController?.updateFavIcon(containsVideo(path: path, inPlaylist: Self.favoritesPlaylistName))
        }
    }

    func createPlaylist(named rawName: String) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard playlists[trimmed] == nil else { return false }
        playlists[trimmed] = []
        selectedPlaylistName = trimmed
        saveSettings()
        liquidController?.refreshUI()
        return true
    }

    func deletePlaylist(named playlistName: String) {
        guard playlistName != Self.favoritesPlaylistName else { return }
        let wasActiveFilter = isPlaylistFilterEnabled && selectedPlaylistName == playlistName
        playlists.removeValue(forKey: playlistName)
        if selectedPlaylistName == playlistName {
            selectedPlaylistName = Self.favoritesPlaylistName
        }
        if wasActiveFilter { isPlaylistFilterEnabled = false }
        saveSettings()
        liquidController?.refreshUI()
        if wasActiveFilter {
            refreshQueue()
            startPlayback()
        }
    }

    func clearPlaylist(named playlistName: String) {
        playlists[playlistName] = []
        saveSettings()
        liquidController?.refreshUI()
        if isPlaylistFilterEnabled && selectedPlaylistName == playlistName {
            refreshQueue()
            startPlayback()
        }
    }

    func setSelectedPlaylist(_ playlistName: String) {
        guard playlists[playlistName] != nil else { return }
        selectedPlaylistName = playlistName
        saveSettings()
        if isPlaylistFilterEnabled {
            refreshQueue()
            startPlayback()
        } else {
            liquidController?.refreshUI()
        }
    }

    func toggleSelectedPlaylistFilter() {
        guard requireProAccess(for: .playlists) else { return }
        ensurePlaylists()
        isPlaylistFilterEnabled.toggle()
        saveSettings()
        refreshQueue()
        startPlayback()
    }

    func importVideosToSelectedPlaylist() {
        guard requireProAccess(for: .playlists) else { return }
        ensurePlaylists()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .gif]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Add Videos"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addVideo(path: url.path, toPlaylist: selectedPlaylistName)
            if !allFiles.contains(url) {
                allFiles.append(url)
            }
        }
        allFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
        saveSettings()
        liquidController?.refreshUI()
        if isPlaylistFilterEnabled {
            refreshQueue()
            startPlayback()
        }
    }

    func promptForNewPlaylist() {
        guard requireProAccess(for: .playlists) else { return }
        let alert = NSAlert()
        alert.messageText = "Create Playlist"
        alert.informativeText = "Enter a name for the new playlist."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Playlist name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if !createPlaylist(named: field.stringValue) {
            let failure = NSAlert()
            failure.messageText = "Playlist not created"
            failure.informativeText = "Choose a unique playlist name."
            failure.runModal()
        }
    }
    
    // MARK: - SSD AUTO-CONNECT & LOAD
    func checkAndLoad(url: URL) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue {
            // Path exists (SSD is ready)
            loadFolder(folderUrl: url, autoStart: true)
        } else {
            // Path missing (SSD not ready). Wait for mount.
            print("CineWall: Path not found. Waiting for SSD mount...")
        }
    }
    
    @objc func storageMounted(_ notification: Notification) {
        // If we have a saved path but no files loaded, try loading again
        if allFiles.isEmpty, let savedPath = lastFolderPath {
            let url = URL(fileURLWithPath: savedPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue {
                print("CineWall: Drive mounted! Loading wallpaper.")
                loadFolder(folderUrl: url, autoStart: true)
            }
        }
    }

    // MARK: - PLAYBACK ENGINE
    func startPlayback() {
        cancelActiveIdleWallpaperSync()
        stopAllPlayers()
        gifView?.isHidden = true; layerA?.isHidden = true; layerB?.isHidden = true
        
        if currentQueue.isEmpty {
            liquidController?.updateTrackInfo(title: "No Media", image: nil, isFav: false)
            return
        }
        
        if queueIndex >= currentQueue.count { queueIndex = 0 }
        let currentFile = currentQueue[queueIndex]
        let isFav = containsVideo(path: currentFile.path, inPlaylist: Self.favoritesPlaylistName)
        
        // Save current file for restart
        lastPlayedFile = currentFile.path
        saveSettings()
        
        generateThumbnail(for: currentFile) { [weak self] img in
            self?.liquidController?.updateTrackInfo(title: currentFile.lastPathComponent, image: img, isFav: isFav)
        }
        
        if currentFile.pathExtension.lowercased() == "gif" {
            playGIF(url: currentFile)
        } else {
            playVideo(at: queueIndex)
        }
        
        resetPlaylistTimer(); updatePlaybackState(); liquidController?.refreshUI(); scheduleIdleWallpaperSyncIfNeeded()
    }
    
    // MARK: - GIF ENGINE (FIXED)
    func playGIF(url: URL) {
        stopAllPlayers() // Clears video players and old GIF timers
        
        guard let image = NSImage(contentsOf: url) else { nextFile(); return }
        
        gifView?.isHidden = false
        gifView?.image = image
        gifView?.animates = true
        updateScalingMode()
        
        // If Loop is OFF and Timer is OFF, we need to manually change when GIF ends
        if !isLoopingCurrent && autoChangeInterval == 0 {
            let duration = getGIFDuration(url: url)
            // Schedule next track
            gifTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.videoFinished()
            }
        }
    }
    
    // Helper to calculate GIF length
    func getGIFDuration(url: URL) -> Double {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 5.0 }
        let count = CGImageSourceGetCount(source)
        var totalDuration: Double = 0
        
        for i in 0..<count {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
               let gifInfo = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                
                var delay = gifInfo[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                            ?? gifInfo[kCGImagePropertyGIFDelayTime as String] as? Double
                            ?? 0.1
                
                if delay <= 0.01 { delay = 0.1 } // Fix for 0 delay gifs
                totalDuration += delay
            }
        }
        // Minimal fallback
        return totalDuration > 0 ? totalDuration : 5.0
    }

    // MARK: - VIDEO ENGINE
    func playVideo(at index: Int) {
        let url = currentQueue[index]; let item = AVPlayerItem(url: url)
        let activePlayer = (activePlayerIndex == 0) ? playerA : playerB
        let activeLayer = (activePlayerIndex == 0) ? layerA : layerB
        let hiddenLayer = (activePlayerIndex == 0) ? layerB : layerA

        pendingVideoReadyObservation?.invalidate()
        pendingVideoReadyObservation = nil
        pendingHiddenLayerCleanupWorkItem?.cancel()
        pendingHiddenLayerCleanupWorkItem = nil

        activePlayer?.replaceCurrentItem(with: item)
        activePlayer?.volume = isMuted ? 0 : volumeLevel
        activePlayer?.actionAtItemEnd = .none

        setupTimeObserver(for: activePlayer!)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        activeLayer?.isHidden = false
        activeLayer?.opacity = 1.0
        hiddenLayer?.opacity = 0.0
        CATransaction.commit()

        let cleanupWorkItem = DispatchWorkItem { [weak hiddenLayer] in
            hiddenLayer?.isHidden = true
            hiddenLayer?.player?.replaceCurrentItem(with: nil)
        }
        pendingHiddenLayerCleanupWorkItem = cleanupWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: cleanupWorkItem)

        if !isManualPaused { activePlayer?.play() }

        if let observer = videoEndObserver { NotificationCenter.default.removeObserver(observer) }
        videoEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in self?.videoFinished() }
    }
    
    func videoFinished() {
        if isLoopingCurrent {
            // Replay Video
            let p = (activePlayerIndex == 0) ? playerA : playerB
            p?.seek(to: .zero); p?.play()
            // Replay GIF
            if !(gifView?.isHidden ?? true) {
                // For GIFs, we just reset the timer if loop is on (though logic above handles !loop)
                // Actually, if loop is ON, we do nothing, NSImageView loops automatically.
            }
        } else {
            nextFile()
        }
    }
    
    func stopAllPlayers() {
        playerA?.pause(); playerB?.pause()
        pendingVideoReadyObservation?.invalidate(); pendingVideoReadyObservation = nil
        pendingHiddenLayerCleanupWorkItem?.cancel(); pendingHiddenLayerCleanupWorkItem = nil
        gifTimer?.invalidate(); gifTimer = nil // STOP GIF TIMER
        if let ob = timeObserver, let owner = timeObserverOwner { owner.removeTimeObserver(ob); timeObserver = nil; timeObserverOwner = nil }
    }

    // MARK: - SINGLE FILE & PERSISTENCE FIX
    func selectSingleVideo() {
        let d = NSOpenPanel(); d.allowedContentTypes = [.movie, .video, .gif]
        if d.runModal() == .OK, let url = d.url {
            // FIX: Save the parent folder so it reloads on restart
            lastFolderPath = url.deletingLastPathComponent().path
            saveSettings()
            
            if let index = currentQueue.firstIndex(of: url) {
                queueIndex = index
            } else {
                // If not in queue, reload folder then jump to file
                // Or just insert it
                if !allFiles.contains(url) {
                    allFiles.append(url)
                    allFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
                    refreshQueue()
                }
                if let idx = currentQueue.firstIndex(of: url) { queueIndex = idx }
            }
            startPlayback()
        }
    }

    func loadFolder(folderUrl: URL, autoStart: Bool) {
        do {
            let u = try FileManager.default.contentsOfDirectory(at: folderUrl, includingPropertiesForKeys: nil)
            allFiles = u.filter { ["mp4", "mov", "m4v", "gif"].contains($0.pathExtension.lowercased()) }
            if allFiles.isEmpty { return }
            
            lastFolderPath = folderUrl.path
            allFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
            refreshQueue()
            
            // Restore specific file if possible
            if let savedFile = lastPlayedFile, let idx = currentQueue.firstIndex(where: { $0.path == savedFile }) {
                queueIndex = idx
            } else {
                queueIndex = 0
            }
            
            saveSettings()
            if autoStart { startPlayback() }
        } catch {}
    }

    // MARK: - OBSERVERS & UTILS
    func setupObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(stateChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(stateChanged), name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(spaceDidChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // SSD MOUNT OBSERVER
        nc.addObserver(self, selector: #selector(storageMounted), name: NSWorkspace.didMountNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(screenDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(sessionUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }
    
    // (Standard Helpers - Minimized for brevity as they haven't changed)
    @objc func nextFile() { if !currentQueue.isEmpty { queueIndex += 1; if queueIndex >= currentQueue.count { queueIndex = 0 }; startPlayback() } }
    @objc func prevFile() { if !currentQueue.isEmpty { queueIndex -= 1; if queueIndex < 0 { queueIndex = currentQueue.count - 1 }; startPlayback() } }
    func setupTimeObserver(for player: AVPlayer) {
        if let ob = timeObserver, let owner = timeObserverOwner { owner.removeTimeObserver(ob); timeObserver = nil; timeObserverOwner = nil }
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isSeeking, let duration = player.currentItem?.duration.seconds, duration > 0 else { return }
            guard self.liquidWindow?.isVisible == true else { return }
            self.liquidController?.progressSlider.doubleValue = time.seconds / duration
            self.liquidController?.updateTimeLabels(elapsed: time.seconds, duration: duration)
        }
        timeObserverOwner = player
    }
    func seekTo(percentage: Double) { let activePlayer = (activePlayerIndex == 0) ? playerA : playerB; guard let duration = activePlayer?.currentItem?.duration.seconds else { return }; isSeeking = true; activePlayer?.seek(to: CMTime(seconds: duration * percentage, preferredTimescale: 1000)) { [weak self] _ in self?.isSeeking = false } }
    func toggleMuteState() { isMuted.toggle(); saveSettings(); updateVolumeState(); liquidController?.refreshUI() }
    func toggleFavorite() {
        guard !currentQueue.isEmpty else { return }
        let path = currentQueue[queueIndex].path
        toggleVideo(path: path, inPlaylist: Self.favoritesPlaylistName)
    }
    func removeFavorite(path: String) {
        removeVideo(path: path, fromPlaylist: Self.favoritesPlaylistName)
        saveSettings()
        liquidController?.refreshUI()
        if !currentQueue.isEmpty && currentQueue[queueIndex].path == path {
            liquidController?.updateFavIcon(false)
        }
        if isPlaylistFilterEnabled && selectedPlaylistName == Self.favoritesPlaylistName {
            refreshQueue()
            startPlayback()
        }
    }
    func refreshQueue() {
        let currentPath = (queueIndex >= 0 && queueIndex < currentQueue.count) ? currentQueue[queueIndex].path : lastPlayedFile
        let sourceFiles: [URL]
        if isPlaylistFilterEnabled {
            let selectedSet = Set(playlistEntries(named: selectedPlaylistName))
            sourceFiles = allFiles.filter { selectedSet.contains($0.path) }
        } else {
            sourceFiles = allFiles
        }
        currentQueue = isShuffle ? sourceFiles.shuffled() : sourceFiles
        if let currentPath, let idx = currentQueue.firstIndex(where: { $0.path == currentPath }) {
            queueIndex = idx
        } else {
            queueIndex = 0
        }
    }
    func generateThumbnail(for url: URL, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = thumbnailCacheKey(for: url)

        if let cached = thumbnailCache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        if url.pathExtension.lowercased() == "gif" {
            let image = NSImage(contentsOf: url)
            if let image {
                thumbnailCache.setObject(image, forKey: cacheKey)
            }
            completion(image)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            do {
                let cg = try gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 60), actualTime: nil)
                let image = NSImage(cgImage: cg, size: .zero)
                DispatchQueue.main.async {
                    self.thumbnailCache.setObject(image, forKey: cacheKey)
                    completion(image)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }
    func updatePlaybackState() { _ = syncAccessControlledState(); if isManualPaused || (focusPauseEnabled && !isDesktopFocused()) || (smartPauseEnabled && !showOnAllSpaces && isOccluded()) || (batterySaverEnabled && isOnBattery()) { performPause(); return }; performPlay(); updateVolumeState() }
    func isOccluded() -> Bool { guard let w = wallpaperWindow else { return false }; return !w.occlusionState.contains(.visible) || (NSScreen.main?.visibleFrame.height ?? 0) >= (NSScreen.main?.frame.height ?? 0) }
    func isOnBattery() -> Bool { return IOPSGetTimeRemainingEstimate() != kIOPSTimeRemainingUnlimited }
    func isDesktopFocused() -> Bool { guard let app = NSWorkspace.shared.frontmostApplication else { return true }; return app.bundleIdentifier == Bundle.main.bundleIdentifier || app.bundleIdentifier == "com.apple.finder" }
    func performPlay() { let p = (activePlayerIndex == 0) ? playerA : playerB; if p?.rate == 0 { p?.play() }; if !(gifView?.isHidden ?? true) { gifView?.animates = true; if !isLoopingCurrent && autoChangeInterval == 0 && gifTimer == nil { /* Restart GIF timer if needed logic here */ } } }
    func performPause() { let p = (activePlayerIndex == 0) ? playerA : playerB; if p?.rate != 0 { p?.pause() }; if !(gifView?.isHidden ?? true) { gifView?.animates = false; gifTimer?.invalidate(); gifTimer = nil } }
    func updateVolumeState() { let v = (isMuted || (focusMuteEnabled && !isDesktopFocused())) ? 0 : volumeLevel; playerA?.volume = v; playerB?.volume = v }
    @objc func stateChanged() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.updatePlaybackState() } }
    @objc func spaceDidChange() { ghostWindow?.orderFront(nil); stateChanged() }
    @objc func screenDidChange() { guard let w = wallpaperWindow, let s = NSScreen.main else { return }; targetScreen = s; w.setFrame(s.frame, display: true); layerA?.frame = w.contentView!.bounds; layerB?.frame = w.contentView!.bounds; gifView?.frame = w.contentView!.bounds }
    @objc func sessionUnlocked() {
        guard proManager.canUse(.lockScreenSync), lockScreenSyncEnabled else { return }
        guard idleWallpaperSyncMode == .fast else { return }

        let refreshURL: URL?
        if autoSyncIdleWallpaper, currentQueue.indices.contains(queueIndex) {
            refreshURL = currentQueue[queueIndex]
        } else if let lastPath = lastAutoSyncedMediaPath {
            refreshURL = URL(fileURLWithPath: lastPath)
        } else {
            refreshURL = nil
        }

        guard let sourceURL = refreshURL else { return }
        syncCurrentVideoToIdleWallpaper(showAlerts: false, sourceURL: sourceURL)
    }

    func scheduleFastModeLaunchRefreshIfNeeded() {
        guard proManager.canUse(.lockScreenSync), lockScreenSyncEnabled else { return }
        guard idleWallpaperSyncMode == .fast else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            guard self.proManager.canUse(.lockScreenSync), self.lockScreenSyncEnabled else { return }

            let refreshURL: URL?
            if self.currentQueue.indices.contains(self.queueIndex) {
                refreshURL = self.currentQueue[self.queueIndex]
            } else if let lastPath = self.lastAutoSyncedMediaPath {
                refreshURL = URL(fileURLWithPath: lastPath)
            } else {
                refreshURL = nil
            }

            guard let sourceURL = refreshURL else { return }
            self.syncCurrentVideoToIdleWallpaper(showAlerts: false, sourceURL: sourceURL)
        }
    }
    func resetPlaylistTimer() { playlistTimer?.invalidate(); guard autoChangeInterval > 0, !currentQueue.isEmpty else { return }; playlistTimer = Timer.scheduledTimer(withTimeInterval: autoChangeInterval, repeats: true) { [weak self] _ in self?.nextFile() } }
    @objc func bringToCurrentDesktop() { guard let w = wallpaperWindow else { return }; if let s = NSScreen.main { w.setFrame(s.frame, display: true); layerA?.frame = w.contentView!.bounds; layerB?.frame = w.contentView!.bounds; gifView?.frame = w.contentView!.bounds }; w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]; w.orderFront(nil); if !showOnAllSpaces { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { w.collectionBehavior = [.stationary, .ignoresCycle]; self.updatePlaybackState() } } }
    func applyWindowLevel() { wallpaperWindow?.level = hideDesktopIcons ? NSWindow.Level(Int(CGWindowLevelForKey(.normalWindow)) - 1) : NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow))); wallpaperWindow?.ignoresMouseEvents = !hideDesktopIcons }
    func restoreFinder() { let t = Process(); t.launchPath = "/usr/bin/defaults"; t.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", "true"]; t.launch(); t.waitUntilExit() }
    func selectFolder() {
        let d = NSOpenPanel(); d.canChooseDirectories = true; d.canChooseFiles = false; if d.runModal() == .OK, let url = d.url { loadFolder(folderUrl: url, autoStart: true) }
    }
    func terminateApp() {
        saveSettings()
        NSApplication.shared.terminate(self)
    }
    func syncCurrentVideoToIdleWallpaper(showAlerts: Bool = true, sourceURL: URL? = nil) {
        guard requireProAccess(for: .lockScreenSync) else { return }
        guard lockScreenSyncEnabled else {
            if showAlerts {
                showAlert(title: "Lock Screen Sync Off", message: "Turn on Lock Screen Sync in Settings first.")
            }
            return
        }
        let selectedURL = sourceURL ?? ((currentQueue.indices.contains(queueIndex)) ? currentQueue[queueIndex] : nil)
        guard let sourceURL = selectedURL else {
            if showAlerts {
                showAlert(title: "No Media Selected", message: "Play a video first, then sync it to the idle wallpaper system.")
            }
            return
        }

        let ext = sourceURL.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else {
            if showAlerts {
                showAlert(title: "Video Required", message: "The modern wallpaper system only accepts video assets. GIF sync is not implemented.")
            }
            return
        }

        let sourceTitle = sourceURL.deletingPathExtension().lastPathComponent
        let syncRequestID = beginIdleWallpaperSyncRequest()
        setIdleWallpaperSyncInProgress(true)
        idleWallpaperSyncQueue.async {
            do {
                try self.throwIfIdleWallpaperSyncCancelled(syncRequestID)
                self.lastCompatibleSyncDebugSummary = nil
                let assetID = try self.stableAerialAssetID(for: sourceURL)
                try self.registerVideoWithWallpaperSystem(sourceURL: sourceURL, assetID: assetID, displayName: sourceTitle, syncRequestID: syncRequestID)
                try self.throwIfIdleWallpaperSyncCancelled(syncRequestID)
                self.syncedAerialAssetID = assetID
                self.lastAutoSyncedMediaPath = sourceURL.path
                self.saveSettings()
                self.restartWallpaperAgent()
                self.setIdleWallpaperSyncInProgress(false, requestID: syncRequestID)
                guard showAlerts else { return }
                DispatchQueue.main.async {
                    let debugSummary = self.lastCompatibleSyncDebugSummary.map { "\n\n\($0)" } ?? ""
                    self.showAlert(title: "Idle Wallpaper Updated", message: "\"\(sourceTitle)\" was registered with the macOS wallpaper system.\(debugSummary)")
                }
            } catch {
                self.setIdleWallpaperSyncInProgress(false, requestID: syncRequestID)
                guard !self.isIdleWallpaperSyncCancellation(error), self.isIdleWallpaperSyncRequestCurrent(syncRequestID) else { return }
                guard showAlerts else { return }
                DispatchQueue.main.async {
                    let debugSummary = self.lastCompatibleSyncDebugSummary.map { "\n\n\($0)" } ?? ""
                    self.showAlert(title: "Sync Failed", message: "\(error.localizedDescription)\(debugSummary)")
                }
            }
        }
    }
    func scheduleIdleWallpaperSyncIfNeeded() {
        idleSyncWorkItem?.cancel()
        guard proManager.canUse(.lockScreenSync) else { return }
        guard lockScreenSyncEnabled else { return }
        guard autoSyncIdleWallpaper, currentQueue.indices.contains(queueIndex) else { return }
        let sourceURL = currentQueue[queueIndex]
        let ext = sourceURL.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext), lastAutoSyncedMediaPath != sourceURL.path else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.syncCurrentVideoToIdleWallpaper(showAlerts: false, sourceURL: sourceURL)
        }
        idleSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: workItem)
    }
    func updateScalingMode() { let g: AVLayerVideoGravity = (scalingTag == 1) ? .resizeAspectFill : (scalingTag == 2 ? .resizeAspect : .resize); layerA?.videoGravity = g; layerB?.videoGravity = g; gifView?.layer?.contentsGravity = (scalingTag == 1) ? .resizeAspectFill : (scalingTag == 2 ? .resizeAspect : .resize) }
    func startStatsMonitor() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.liquidWindow?.isVisible == true else { return }
            self.liquidController?.updateStats()
        }
    }
    func getAppRAM() -> String { var i = task_vm_info_data_t(); var c = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size); if withUnsafeMutablePointer(to: &i, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &c) } }) == KERN_SUCCESS { return ByteCountFormatter.string(fromByteCount: Int64(i.phys_footprint), countStyle: .memory) }; return "0 MB" }
    func getAppCPU() -> Double { var t = 0.0; var l: thread_act_array_t?; var c = mach_msg_type_number_t(0); if task_threads(mach_task_self_, &l, &c) == KERN_SUCCESS, let l = l { for i in 0..<Int(c) { var info = thread_basic_info(); var ic = mach_msg_type_number_t(THREAD_INFO_MAX); let _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(ic)) { thread_info(l[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &ic) } }; if (info.flags & TH_FLAGS_IDLE == 0) { t += (Double(info.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0 } }; vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: l)), vm_size_t(Int(c) * MemoryLayout<thread_t>.stride)) }; return t }
    func saveSettings() {
        let d = UserDefaults.standard
        d.set(isMuted, forKey: "isMuted")
        d.set(volumeLevel, forKey: "volumeLevel")
        d.set(isShuffle, forKey: "isShuffle")
        d.set(showOnAllSpaces, forKey: "showOnAllSpaces")
        d.set(smartPauseEnabled, forKey: "smartPause")
        d.set(focusPauseEnabled, forKey: "focusPause")
        d.set(focusMuteEnabled, forKey: "focusMute")
        d.set(batterySaverEnabled, forKey: "batterySaver")
        d.set(hideDesktopIcons, forKey: "hideDesktopIcons")
        d.set(isLoopingCurrent, forKey: "isLoopingCurrent")
        d.set(isPlaylistFilterEnabled, forKey: "isPlaylistFilterEnabled")
        d.set(selectedPlaylistName, forKey: "selectedPlaylistName")
        d.set(scalingTag, forKey: "scalingTag")
        d.set(autoChangeInterval, forKey: "autoChangeInterval")
        d.set(lockScreenSyncEnabled, forKey: "lockScreenSyncEnabled")
        d.set(autoSyncIdleWallpaper, forKey: "autoSyncIdleWallpaper")
        d.set(idleWallpaperSyncMode.rawValue, forKey: "idleWallpaperSyncMode")
        d.set(menuDarkTintStrength, forKey: "menuDarkTintStrength")
        d.set(playlists, forKey: "playlists")
        d.set(favorites, forKey: "favorites")
        if let path = lastFolderPath { d.set(path, forKey: "lastFolderPath") }
        if let file = lastPlayedFile { d.set(file, forKey: "lastPlayedFile") }
        if let assetID = syncedAerialAssetID { d.set(assetID, forKey: "syncedAerialAssetID") }
        if let path = lastAutoSyncedMediaPath { d.set(path, forKey: "lastAutoSyncedMediaPath") }
    }
    func loadSettings() {
        let d = UserDefaults.standard
        isMuted = d.bool(forKey: "isMuted")
        volumeLevel = d.float(forKey: "volumeLevel")
        isShuffle = d.bool(forKey: "isShuffle")
        showOnAllSpaces = d.bool(forKey: "showOnAllSpaces")
        smartPauseEnabled = d.bool(forKey: "smartPause")
        focusPauseEnabled = d.bool(forKey: "focusPause")
        focusMuteEnabled = d.bool(forKey: "focusMute")
        batterySaverEnabled = d.bool(forKey: "batterySaver")
        hideDesktopIcons = d.bool(forKey: "hideDesktopIcons")
        lastFolderPath = d.string(forKey: "lastFolderPath")
        lastPlayedFile = d.string(forKey: "lastPlayedFile")
        syncedAerialAssetID = d.string(forKey: "syncedAerialAssetID")
        lastAutoSyncedMediaPath = d.string(forKey: "lastAutoSyncedMediaPath")
        lockScreenSyncEnabled = d.bool(forKey: "lockScreenSyncEnabled")
        autoSyncIdleWallpaper = d.bool(forKey: "autoSyncIdleWallpaper")
        if let raw = d.string(forKey: "idleWallpaperSyncMode"), let mode = IdleWallpaperSyncMode(rawValue: raw) { idleWallpaperSyncMode = mode }
        menuDarkTintStrength = d.object(forKey: "menuDarkTintStrength") == nil ? 0.0 : d.double(forKey: "menuDarkTintStrength")
        isLoopingCurrent = d.bool(forKey: "isLoopingCurrent")
        isPlaylistFilterEnabled = d.bool(forKey: "isPlaylistFilterEnabled")
        selectedPlaylistName = d.string(forKey: "selectedPlaylistName") ?? Self.favoritesPlaylistName
        autoChangeInterval = d.double(forKey: "autoChangeInterval")
        scalingTag = d.integer(forKey: "scalingTag")
        if scalingTag == 0 { scalingTag = 1 }
        if let savedPlaylists = d.dictionary(forKey: "playlists") as? [String: [String]] {
            playlists = savedPlaylists
        }
        let legacyFavorites = d.stringArray(forKey: "favorites") ?? []
        if !legacyFavorites.isEmpty {
            var mergedFavorites = playlists[Self.favoritesPlaylistName] ?? []
            mergedFavorites.append(contentsOf: legacyFavorites)
            playlists[Self.favoritesPlaylistName] = deduplicatedPaths(mergedFavorites)
        }
        ensurePlaylists()
        if volumeLevel == 0.0 { volumeLevel = 0.5 }
        syncAccessControlledState()
    }
    
    // ... UI Handling (same as before) ...
    func createLiquidPopover() { let win = LiquidPanel(contentRect: NSRect(x: 0, y: 0, width: liquidMenuWidth, height: liquidMenuHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false); win.level = .floating; win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; win.backgroundColor = .clear; win.isOpaque = false; win.hasShadow = false; win.titlebarAppearsTransparent = true; win.titleVisibility = .hidden; win.registerForDraggedTypes([.fileURL]); win.minSize = NSSize(width: liquidMenuWidth, height: liquidMenuHeight); win.maxSize = NSSize(width: liquidMenuWidth, height: liquidMenuHeight); let vc = LiquidMenuController(); vc.appDelegate = self; win.contentView = vc.view; self.liquidWindow = win; self.liquidController = vc }
    @objc func toggleLiquidPopover() {
        guard let window = liquidWindow, let button = statusItem.button else { return }
        if window.isVisible {
            closePopover()
        } else {
            syncAccessControlledState()
            liquidController?.refreshUI()
            liquidController?.updateStats()
            liquidController?.resetToMainMenu()
            liquidController?.setMenuVisible(true)
            window.isMovableByWindowBackground = isPinned
            
            let buttonRect = button.window?.convertToScreen(button.frame) ?? .zero
            let x = buttonRect.origin.x - (liquidMenuWidth / 2) + (buttonRect.width / 2)
            let y = buttonRect.origin.y - liquidMenuHeight - 8
            window.setFrameOrigin(NSPoint(x: x, y: y))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if !isPinned { setupTransiencyMonitor() }
        }
    }
    func setupTransiencyMonitor() { if popoverTransiency != nil { return }; popoverTransiency = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.closePopover() } }
    func removeTransiencyMonitor() { if let m = popoverTransiency { NSEvent.removeMonitor(m); popoverTransiency = nil } }
    func togglePin() {
        isPinned.toggle()
        liquidWindow?.isMovableByWindowBackground = isPinned
        if isPinned {
            removeTransiencyMonitor()
        } else {
            setupTransiencyMonitor()
        }
    }
    func closePopover() {
        if isPinned { return }
        liquidController?.setMenuVisible(false)
        liquidWindow?.orderOut(nil)
        removeTransiencyMonitor()
    }
    func currentAccessDescription() -> String {
        proManager.statusLine
    }
    @discardableResult
    func syncAccessControlledState() -> Bool {
        var didChange = false

        if !proManager.canUse(.timer), autoChangeInterval > 0 {
            autoChangeInterval = 0
            playlistTimer?.invalidate()
            playlistTimer = nil
            didChange = true
        }

        if !proManager.canUse(.playlists), isPlaylistFilterEnabled {
            isPlaylistFilterEnabled = false
            refreshQueue()
            didChange = true
        }

        if !proManager.canUse(.smartSettings) {
            if smartPauseEnabled {
                smartPauseEnabled = false
                didChange = true
            }
            if batterySaverEnabled {
                batterySaverEnabled = false
                didChange = true
            }
            if focusPauseEnabled {
                focusPauseEnabled = false
                didChange = true
            }
            if focusMuteEnabled {
                focusMuteEnabled = false
                didChange = true
            }
        }

        if !proManager.canUse(.lockScreenSync), lockScreenSyncEnabled {
            lockScreenSyncEnabled = false
            didChange = true
        }

        if !lockScreenSyncEnabled, autoSyncIdleWallpaper {
            autoSyncIdleWallpaper = false
            idleSyncWorkItem?.cancel()
            didChange = true
        }

        if didChange {
            saveSettings()
        }
        return didChange
    }
    @discardableResult
    func requireProAccess(for feature: ProFeature) -> Bool {
        if proManager.canUse(feature) {
            return true
        }
        presentProUpgradePrompt(for: feature)
        liquidController?.refreshUI()
        return false
    }
    func presentProUpgradePrompt(for feature: ProFeature) {
        liquidWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        liquidController?.showProSettings(for: feature)
    }
    func startProTrial(completion: ((Bool, String) -> Void)? = nil) {
        guard !proManager.hasActivatedLicense else {
            completion?(true, "Pro is already unlocked on this Mac.")
            return
        }
        guard let trialURL = proManager.trialStatusURL else {
            let started = proManager.startLegacyTrialFallback()
            if started {
                syncAccessControlledState()
                liquidController?.refreshUI()
                completion?(true, "Pro trial started. Everything marked PRO is unlocked for 7 days.")
            } else if proManager.isTrialActive {
                completion?(true, "Your Pro trial is already active.")
            } else {
                completion?(false, "Your 7-day trial has already been used. Enter a license key to unlock Pro again.")
            }
            return
        }
        guard isTrustedTrialURL(trialURL) else {
            showAlert(title: "Trial Blocked", message: "This build will only start trials against CineWall's secure production endpoint.")
            completion?(false, "This build will only start trials against CineWall's secure production endpoint.")
            return
        }

        var request = URLRequest(url: trialURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "action": "start",
            "install_id": proManager.installID,
            "device_name": analyticsDeviceName,
            "os_version": analyticsOSVersion,
            "architecture": analyticsArchitecture,
            "app_version": analyticsAppVersion
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    completion?(false, error.localizedDescription)
                    return
                }

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let object = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
                    completion?(false, "The trial server response was invalid.")
                    return
                }

                if !(200...299).contains(statusCode) {
                    let message = object["message"] as? String ?? "The trial request failed."
                    completion?(false, message)
                    return
                }

                if self.applyServerTrialStatus(object) {
                    self.syncAccessControlledState()
                    self.liquidController?.refreshUI()
                    if self.proManager.isTrialActive {
                        completion?(true, "Pro trial started. Everything marked PRO is unlocked for 7 days.")
                    } else if self.proManager.hasUsedTrial {
                        completion?(false, "Your 7-day trial has already been used. Enter a license key to unlock Pro again.")
                    } else {
                        completion?(false, "The trial server did not return a usable trial state.")
                    }
                } else {
                    let message = object["message"] as? String ?? "The trial server response was invalid."
                    completion?(false, message)
                }
            }
        }.resume()
    }
    #if DEBUG
    func toggleDeveloperProUnlock() {
        proManager.setDeveloperUnlocked(!proManager.isDeveloperUnlocked)
        syncAccessControlledState()
        liquidController?.refreshUI()
    }

    func resetDebugProTrialState(completion: ((Bool, String) -> Void)? = nil) {
        let finishReset = { [weak self] (message: String) in
            self?.proManager.resetDebugProState()
            self?.syncAccessControlledState()
            self?.refreshServerTrialStatus(silent: true) { _ in
                self?.liquidController?.refreshUI()
                completion?(true, message)
            }
        }

        if let key = proManager.licenseKey,
           let instanceID = proManager.activationInstanceID {
            deactivateLicenseKey(key, instanceID: instanceID) { [weak self] success, message in
                guard let self else { return }
                if success {
                    finishReset("Local Pro, trial, install state, and the current activation slot were reset.")
                } else {
                    self.showAlert(title: "Reset Incomplete", message: message)
                    completion?(false, message)
                }
            }
            return
        }

        finishReset("Local Pro, trial, and install state were reset for this Debug build.")
    }
    #endif
    func activateLicenseKey(_ key: String) {
        guard let activationURL = proManager.activationURL else {
            showAlert(title: "Activation URL Missing", message: "Set your activation endpoint before shipping. The app-side Pro flow is ready, but secure activation should happen through your server or website.")
            return
        }
        guard isTrustedActivationURL(activationURL) else {
            showAlert(title: "Activation Blocked", message: "This build will only activate against CineWall's secure production endpoint.")
            return
        }

        var request = URLRequest(url: activationURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "license_key": key,
            "product": "cinewall-pro",
            "install_id": proManager.installID,
            "device_name": analyticsDeviceName,
            "os_version": analyticsOSVersion,
            "architecture": analyticsArchitecture,
            "app_version": analyticsAppVersion
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error {
                    self?.showAlert(title: "Activation Failed", message: error.localizedDescription)
                    return
                }

                let httpResponse = response as? HTTPURLResponse
                let statusCode = httpResponse?.statusCode ?? 0
                let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let serverMessage = object?["message"] as? String

                guard let object,
                      let success = object["success"] as? Bool else {
                    if statusCode >= 500 {
                        self?.showAlert(title: "Activation Failed", message: "The activation server is unavailable right now. Please try again later.")
                    } else if statusCode >= 400 {
                        self?.showAlert(title: "Activation Failed", message: serverMessage ?? "The activation request was rejected.")
                    } else {
                        self?.showAlert(title: "Activation Failed", message: "The server response was invalid.")
                    }
                    return
                }

                if !(200...299).contains(statusCode) {
                    self?.showAlert(title: "Activation Failed", message: serverMessage ?? "The activation request failed.")
                    return
                }

                if success {
                    self?.proManager.storeLicenseKey(key)
                    if let instanceID = object["instance_id"] as? String, !instanceID.isEmpty {
                        self?.proManager.storeActivationInstanceID(instanceID)
                    }
                    self?.syncAccessControlledState()
                    self?.liquidController?.refreshUI()
                    self?.showAlert(title: "Pro Unlocked", message: "CineWall Pro is now active on this Mac.")
                } else {
                    let message = object["message"] as? String ?? "That license key could not be activated."
                    self?.showAlert(title: "Activation Failed", message: message)
                }
            }
        }.resume()
    }
    func deactivateLicenseKey(_ key: String, instanceID: String, completion: ((Bool, String) -> Void)? = nil) {
        guard let deactivationURL = proManager.deactivationURL else {
            completion?(false, "The deactivation endpoint is missing.")
            return
        }
        guard isTrustedDeactivationURL(deactivationURL) else {
            completion?(false, "This build will only deactivate against CineWall's secure production endpoint.")
            return
        }

        var request = URLRequest(url: deactivationURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = [
            "license_key": key,
            "instance_id": instanceID,
            "product": "cinewall-pro"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion?(false, error.localizedDescription)
                    return
                }

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let message = object?["message"] as? String ?? "The deactivation request failed."
                let success = object?["success"] as? Bool ?? false

                guard (200...299).contains(statusCode), success else {
                    completion?(false, message)
                    return
                }

                completion?(true, message)
            }
        }.resume()
    }
    func refreshServerTrialStatus(silent: Bool = true, completion: ((Bool) -> Void)? = nil) {
        guard !proManager.hasActivatedLicense else {
            completion?(true)
            return
        }
        guard let trialURL = proManager.trialStatusURL else {
            completion?(false)
            return
        }
        guard isTrustedTrialURL(trialURL) else {
            completion?(false)
            return
        }

        var request = URLRequest(url: trialURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "action": "status",
            "install_id": proManager.installID,
            "device_name": analyticsDeviceName,
            "os_version": analyticsOSVersion,
            "architecture": analyticsArchitecture,
            "app_version": analyticsAppVersion
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    if !silent {
                        self.showAlert(title: "Trial Sync Failed", message: error.localizedDescription)
                    }
                    completion?(false)
                    return
                }

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let object = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                      (200...299).contains(statusCode),
                      self.applyServerTrialStatus(object) else {
                    if !silent {
                        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        let message = object?["message"] as? String ?? "The trial server response was invalid."
                        self.showAlert(title: "Trial Sync Failed", message: message)
                    }
                    completion?(false)
                    return
                }

                self.syncAccessControlledState()
                self.liquidController?.refreshUI()
                completion?(true)
            }
        }.resume()
    }
    private func isTrustedActivationURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        #if DEBUG
        return true
        #else
        guard let productionURL = URL(string: "https://cinewall-site.vercel.app/api/activate-license") else { return false }
        return url.host == productionURL.host && url.path == productionURL.path
        #endif
    }
    private func isTrustedDeactivationURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        #if DEBUG
        return true
        #else
        guard let productionURL = URL(string: "https://cinewall-site.vercel.app/api/deactivate-license") else { return false }
        return url.host == productionURL.host && url.path == productionURL.path
        #endif
    }
    private func isTrustedTrialURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        #if DEBUG
        return true
        #else
        guard let productionURL = URL(string: "https://cinewall-site.vercel.app/api/trial-status") else { return false }
        return url.host == productionURL.host && url.path == productionURL.path
        #endif
    }
    @discardableResult
    private func applyServerTrialStatus(_ object: [String: Any]) -> Bool {
        guard let success = object["success"] as? Bool, success else { return false }

        let hasConsumed = object["has_consumed"] as? Bool ?? false
        let startedAt = (object["started_at"] as? String).flatMap { Self.parseServerDate($0) }
        let expiresAt = (object["expires_at"] as? String).flatMap { Self.parseServerDate($0) }

        proManager.updateServerTrial(startDate: startedAt, expiresAt: expiresAt, hasConsumed: hasConsumed)
        return true
    }
    private static func parseServerDate(_ raw: String) -> Date? {
        fractionalISO8601Formatter.date(from: raw) ?? iso8601Formatter.date(from: raw)
    }
    func checkForUpdates() {
        do {
            try sparkleUpdater.checkForUpdates()
        } catch {
            showAlert(title: "Updates Unavailable", message: error.localizedDescription)
        }
        liquidController?.refreshUI()
    }
    func currentUpdateDescription() -> String {
        sparkleUpdater.statusLine
    }
    func openAppWebsite() {
        NSWorkspace.shared.open(Self.appWebsiteURL)
    }
    func openProCheckout() {
        NSWorkspace.shared.open(Self.proCheckoutURL)
    }
    func handleDroppedFile(url: URL) { let ext = url.pathExtension.lowercased(); if ["mp4", "mov", "m4v", "gif"].contains(ext) { if currentQueue.isEmpty { currentQueue = [url]; queueIndex = 0 } else { if let idx = currentQueue.firstIndex(of: url) { queueIndex = idx } else { currentQueue.insert(url, at: queueIndex + 1); queueIndex += 1 } }; startPlayback() } }
    func revealCurrentInFinder() { if !currentQueue.isEmpty && queueIndex < currentQueue.count { NSWorkspace.shared.activateFileViewerSelecting([currentQueue[queueIndex]]) } }
    func showFavoritesWindow() { guard requireProAccess(for: .playlists) else { return }; liquidWindow?.makeKeyAndOrderFront(nil); liquidController?.showLibraryDetail() }
    func playPlaylistItem(at index: Int, playlistName: String? = nil) {
        let name = playlistName ?? selectedPlaylistName
        let items = playlistEntries(named: name)
        guard index < items.count else { return }
        let url = URL(fileURLWithPath: items[index])
        if !currentQueue.contains(url) { currentQueue.append(url) }
        if let idx = currentQueue.firstIndex(of: url) {
            queueIndex = idx
            startPlayback()
        }
    }
    
    // WINDOW CLASSES
    func createGhostWindow() { ghostWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false); ghostWindow?.alphaValue = 0.01; ghostWindow?.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]; ghostWindow?.orderFront(nil) }
    func createWindow() { let s = targetScreen ?? NSScreen.main!; let w = ClickableWindow(contentRect: s.frame, styleMask: [.borderless], backing: .buffered, defer: false); w.appDelegate = self; w.backgroundColor = .black; w.collectionBehavior = [.stationary, .ignoresCycle]; w.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow))); w.ignoresMouseEvents = true; wallpaperWindow = w; let v = NSView(); v.wantsLayer = true; playerA = AVPlayer(); playerB = AVPlayer(); layerA = AVPlayerLayer(player: playerA); layerB = AVPlayerLayer(player: playerB); layerA?.frame = s.frame; layerB?.frame = s.frame; layerA?.isHidden = true; layerB?.isHidden = true; v.layer?.addSublayer(layerA!); v.layer?.addSublayer(layerB!); gifView = NSImageView(frame: s.frame); gifView?.imageScaling = .scaleAxesIndependently; gifView?.isHidden = true; v.addSubview(gifView!); w.contentView = v; w.orderFront(nil); updateScalingMode() }
    func handleWallpaperClick() { if hideDesktopIcons { let s = CGEventSource(stateID: .hidSystemState); let d = CGEvent(keyboardEventSource: s, virtualKey: 103, keyDown: true); let u = CGEvent(keyboardEventSource: s, virtualKey: 103, keyDown: false); d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap) } }

    func registerVideoWithWallpaperSystem(sourceURL: URL, assetID: String, displayName: String, syncRequestID: Int) throws {
        let fileManager = FileManager.default
        let wallpaperRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper", isDirectory: true)
        let aerialsRoot = wallpaperRoot.appendingPathComponent("aerials", isDirectory: true)
        let manifestURL = aerialsRoot.appendingPathComponent("manifest/entries.json")
        let storeURL = wallpaperRoot.appendingPathComponent("Store/Index.plist")
        let videosDir = aerialsRoot.appendingPathComponent("videos", isDirectory: true)
        let thumbnailsDir = aerialsRoot.appendingPathComponent("thumbnails", isDirectory: true)

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw NSError(domain: "CineWall", code: 1001, userInfo: [NSLocalizedDescriptionKey: "The system aerial manifest was not found at \(manifestURL.path)."])
        }
        guard fileManager.fileExists(atPath: storeURL.path) else {
            throw NSError(domain: "CineWall", code: 1002, userInfo: [NSLocalizedDescriptionKey: "The wallpaper store index was not found at \(storeURL.path)."])
        }

        try backupWallpaperStoreIfNeeded(storeURL: storeURL, manifestURL: manifestURL)

        try fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true, attributes: nil)

        let title = displayName.isEmpty ? "CineWall" : displayName
        let videoURL: URL
        switch idleWallpaperSyncMode {
        case .fast:
            videoURL = videosDir.appendingPathComponent("\(assetID).mov")
        case .compatible:
            videoURL = videosDir.appendingPathComponent("\(assetID).mov")
        }
        let thumbnailURL = thumbnailsDir.appendingPathComponent("\(assetID).png")

        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        try cleanupCineWallEntries(from: manifestURL)
        if let previousAssetID = syncedAerialAssetID {
            try cleanupLocalCineWallFiles(assetID: previousAssetID, videosDir: videosDir, thumbnailsDir: thumbnailsDir)
        }

        if fileManager.fileExists(atPath: videoURL.path) { try fileManager.removeItem(at: videoURL) }
        try prepareAerialVideo(sourceURL: sourceURL, destinationURL: videoURL, syncRequestID: syncRequestID)
        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        try writeThumbnail(for: sourceURL, destinationURL: thumbnailURL)
        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: videoURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: thumbnailURL.path)
        try updateAerialManifest(manifestURL: manifestURL, assetID: assetID, title: title, videoURL: videoURL, thumbnailURL: thumbnailURL)
        try updateWallpaperStore(storeURL: storeURL, assetID: assetID)
    }

    func cleanupCineWallEntries(from manifestURL: URL) throws {
        let data = try Data(contentsOf: manifestURL)
        guard var root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              var categories = root["categories"] as? [[String: Any]],
              var assets = root["assets"] as? [[String: Any]] else {
            throw NSError(domain: "CineWall", code: 1003, userInfo: [NSLocalizedDescriptionKey: "The aerial manifest has an unexpected format."])
        }

        let fileManager = FileManager.default
        let staleAssets = assets.filter { asset in
            let categoryIDs = asset["categories"] as? [String] ?? []
            let subcategoryIDs = asset["subcategories"] as? [String] ?? []
            return categoryIDs.contains(cineWallAerialCategoryID) || subcategoryIDs.contains(cineWallAerialSubcategoryID)
        }

        for asset in staleAssets {
            for key in ["url-4K-SDR-240FPS", "previewImage"] {
                guard let value = asset[key] as? String, value.hasPrefix("file://"), let url = URL(string: value), fileManager.fileExists(atPath: url.path) else { continue }
                try? fileManager.removeItem(at: url)
            }
        }

        assets.removeAll { asset in
            let categoryIDs = asset["categories"] as? [String] ?? []
            let subcategoryIDs = asset["subcategories"] as? [String] ?? []
            return categoryIDs.contains(cineWallAerialCategoryID) || subcategoryIDs.contains(cineWallAerialSubcategoryID)
        }
        categories.removeAll { ($0["id"] as? String) == cineWallAerialCategoryID }

        root["categories"] = categories
        root["assets"] = assets
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: manifestURL, options: .atomic)
    }

    func cleanupLocalCineWallFiles(assetID: String, videosDir: URL, thumbnailsDir: URL) throws {
        let fileManager = FileManager.default
        for ext in ["mov", "mp4", "m4v"] {
            let url = videosDir.appendingPathComponent("\(assetID).\(ext)")
            if fileManager.fileExists(atPath: url.path) { try? fileManager.removeItem(at: url) }
        }
        let pngURL = thumbnailsDir.appendingPathComponent("\(assetID).png")
        if fileManager.fileExists(atPath: pngURL.path) { try? fileManager.removeItem(at: pngURL) }
    }

    func writeThumbnail(for sourceURL: URL, destinationURL: URL) throws {
        let asset = AVAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let duration = asset.duration.seconds
        let requestedTime = CMTime(seconds: duration.isFinite && duration > 1.0 ? 1.0 : 0.0, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: requestedTime, actualTime: nil)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CineWall", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Failed to create a PNG thumbnail for the selected video."])
        }
        try data.write(to: destinationURL, options: .atomic)
    }

    func setDesktopWallpaperSnapshotForCurrentMedia() throws {
        guard currentQueue.indices.contains(queueIndex) else { return }
        let sourceURL = currentQueue[queueIndex]
        guard ["mp4", "mov", "m4v"].contains(sourceURL.pathExtension.lowercased()) else { return }

        let fileManager = FileManager.default
        let snapshotDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CineWall/DesktopSnapshot", isDirectory: true)
        try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true, attributes: nil)

        let snapshotURL = snapshotDirectory.appendingPathComponent("last-fast-mode-wallpaper.jpg")
        try writeDesktopWallpaperSnapshot(for: sourceURL, destinationURL: snapshotURL)

        let workspace = NSWorkspace.shared
        let options = workspace.desktopImageOptions(for: NSScreen.main ?? NSScreen.screens.first!) ?? [:]
        for screen in NSScreen.screens {
            try? workspace.setDesktopImageURL(snapshotURL, for: screen, options: options)
        }
    }

    func writeDesktopWallpaperSnapshot(for sourceURL: URL, destinationURL: URL) throws {
        let asset = AVAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let activePlayer = (activePlayerIndex == 0) ? playerA : playerB
        let currentTime = activePlayer?.currentTime() ?? .zero
        let duration = asset.duration
        let requestedTime: CMTime
        if currentTime.isValid, currentTime.seconds.isFinite, currentTime.seconds > 0 {
            let safeSeconds = min(currentTime.seconds, max(duration.seconds - 0.05, 0))
            requestedTime = CMTime(seconds: safeSeconds, preferredTimescale: 600)
        } else {
            requestedTime = CMTime(seconds: duration.seconds.isFinite && duration.seconds > 1.0 ? 1.0 : 0.0, preferredTimescale: 600)
        }

        let cgImage = try generator.copyCGImage(at: requestedTime, actualTime: nil)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw NSError(domain: "CineWall", code: 1091, userInfo: [NSLocalizedDescriptionKey: "Failed to create a desktop wallpaper snapshot from the current video."])
        }
        try data.write(to: destinationURL, options: .atomic)
    }

    func clearIdleWallpaperStateForFastModeQuit() throws {
        let fileManager = FileManager.default
        let wallpaperRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper", isDirectory: true)
        let aerialsRoot = wallpaperRoot.appendingPathComponent("aerials", isDirectory: true)
        let manifestURL = aerialsRoot.appendingPathComponent("manifest/entries.json")
        let storeURL = wallpaperRoot.appendingPathComponent("Store/Index.plist")
        let videosDir = aerialsRoot.appendingPathComponent("videos", isDirectory: true)
        let thumbnailsDir = aerialsRoot.appendingPathComponent("thumbnails", isDirectory: true)

        guard fileManager.fileExists(atPath: manifestURL.path), fileManager.fileExists(atPath: storeURL.path) else { return }

        let fallbackAssetID = try firstNonCineWallAssetID(from: manifestURL)
        try cleanupCineWallEntries(from: manifestURL)
        if let previousAssetID = syncedAerialAssetID {
            try cleanupLocalCineWallFiles(assetID: previousAssetID, videosDir: videosDir, thumbnailsDir: thumbnailsDir)
        }
        if try restorePreviousWallpaperStoreIfAvailable(storeURL: storeURL) {
            syncedAerialAssetID = nil
            restartWallpaperAgent()
            return
        }
        if let fallbackAssetID {
            try updateWallpaperStore(storeURL: storeURL, assetID: fallbackAssetID)
        }
        syncedAerialAssetID = nil
        restartWallpaperAgent()
    }

    func cineWallBackupDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CineWall/WallpaperBackup", isDirectory: true)
    }

    func cineWallWallpaperStoreBackupURL() -> URL {
        cineWallBackupDirectoryURL().appendingPathComponent(cineWallWallpaperStoreBackupFileName)
    }

    func backupWallpaperStoreIfNeeded(storeURL: URL, manifestURL: URL) throws {
        let backupURL = cineWallWallpaperStoreBackupURL()
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: backupURL.path) {
            return
        }

        if let currentAssetID = try currentWallpaperStoreAssetID(storeURL: storeURL),
           try isCineWallAssetID(currentAssetID, manifestURL: manifestURL) {
            return
        }

        try fileManager.createDirectory(at: cineWallBackupDirectoryURL(), withIntermediateDirectories: true, attributes: nil)
        try fileManager.copyItem(at: storeURL, to: backupURL)
    }

    func restorePreviousWallpaperStoreIfAvailable(storeURL: URL) throws -> Bool {
        let backupURL = cineWallWallpaperStoreBackupURL()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupURL.path) else { return false }

        if fileManager.fileExists(atPath: storeURL.path) {
            try fileManager.removeItem(at: storeURL)
        }
        try fileManager.copyItem(at: backupURL, to: storeURL)
        try? fileManager.removeItem(at: backupURL)
        return true
    }

    func currentWallpaperStoreAssetID(storeURL: URL) throws -> String? {
        let data = try Data(contentsOf: storeURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any],
              let systemDefault = root["SystemDefault"] as? [String: Any],
              let linked = systemDefault["Linked"] as? [String: Any],
              let content = linked["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first,
              let configurationData = choice["Configuration"] as? Data,
              let configuration = try PropertyListSerialization.propertyList(from: configurationData, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        return configuration["assetID"] as? String
    }

    func isCineWallAssetID(_ assetID: String, manifestURL: URL) throws -> Bool {
        if syncedAerialAssetID == assetID {
            return true
        }

        let data = try Data(contentsOf: manifestURL)
        guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else {
            return false
        }

        return assets.contains { asset in
            guard (asset["id"] as? String) == assetID else { return false }
            let categoryIDs = asset["categories"] as? [String] ?? []
            let subcategoryIDs = asset["subcategories"] as? [String] ?? []
            return categoryIDs.contains(cineWallAerialCategoryID) || subcategoryIDs.contains(cineWallAerialSubcategoryID)
        }
    }

    func firstNonCineWallAssetID(from manifestURL: URL) throws -> String? {
        let data = try Data(contentsOf: manifestURL)
        guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else {
            throw NSError(domain: "CineWall", code: 1092, userInfo: [NSLocalizedDescriptionKey: "The aerial manifest has an unexpected format."])
        }

        for asset in assets {
            let categoryIDs = asset["categories"] as? [String] ?? []
            let subcategoryIDs = asset["subcategories"] as? [String] ?? []
            if categoryIDs.contains(cineWallAerialCategoryID) || subcategoryIDs.contains(cineWallAerialSubcategoryID) {
                continue
            }
            if let assetID = asset["id"] as? String, !assetID.isEmpty {
                return assetID
            }
        }

        return nil
    }

    func prepareAerialVideo(sourceURL: URL, destinationURL: URL, syncRequestID: Int) throws {
        switch idleWallpaperSyncMode {
        case .fast:
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        case .compatible:
            try exportCompatibleVideoToAerialMovie(sourceURL: sourceURL, destinationURL: destinationURL, syncRequestID: syncRequestID)
        }
    }

    func exportCompatibleVideoToAerialMovie(sourceURL: URL, destinationURL: URL, syncRequestID: Int) throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent("CineWallCompatibleExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let candidateURL = temporaryDirectory.appendingPathComponent("candidate.mov")
        let hybridURL = temporaryDirectory.appendingPathComponent("hybrid.mov")
        let templateURL = try selectBackdropTemplate(for: sourceURL)
        lastCompatibleSyncDebugSummary = "Compatible mode used Backdrop-template hybrid export.\nTemplate: \(templateURL.lastPathComponent)"

        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        try exportCandidateVideoForBackdropHybrid(sourceURL: sourceURL, destinationURL: candidateURL, syncRequestID: syncRequestID)
        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        try runBackdropHybridizer(templateURL: templateURL, candidateURL: candidateURL, destinationURL: hybridURL, syncRequestID: syncRequestID)
        try throwIfIdleWallpaperSyncCancelled(syncRequestID)

        guard fileManager.fileExists(atPath: hybridURL.path) else {
            throw NSError(domain: "CineWall", code: 1016, userInfo: [NSLocalizedDescriptionKey: "The Backdrop-compatible hybrid export did not produce an output file."])
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: hybridURL, to: destinationURL)
    }

    func createMain10PixelBufferPool(renderSize: CGSize) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: renderSize.width,
            kCVPixelBufferHeightKey as String: renderSize.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(domain: "CineWall", code: 1017, userInfo: [NSLocalizedDescriptionKey: "Failed to create a 10-bit full-range pixel buffer pool."])
        }
        return pool
    }

    func makeMain10PixelBuffer(from sourcePixelBuffer: CVPixelBuffer, using pool: CVPixelBufferPool, transferSession: VTPixelTransferSession) -> CVPixelBuffer? {
        var destinationPixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationPixelBuffer)
        guard createStatus == kCVReturnSuccess, let destinationPixelBuffer else { return nil }

        applyRec709Metadata(to: sourcePixelBuffer)
        applyRec709Metadata(to: destinationPixelBuffer)

        let transferStatus = VTPixelTransferSessionTransferImage(transferSession, from: sourcePixelBuffer, to: destinationPixelBuffer)
        guard transferStatus == noErr else { return nil }
        return destinationPixelBuffer
    }

    func applyRec709Metadata(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    func preferredFrameDuration(for track: AVAssetTrack) -> CMTime {
        if track.minFrameDuration.isValid, track.minFrameDuration.seconds > 0 {
            return track.minFrameDuration
        }

        let nominalFrameRate = track.nominalFrameRate
        if nominalFrameRate > 0 {
            let timescale = max(Int32((nominalFrameRate * 1000).rounded()), 600)
            let value = max(Int64((Double(timescale) / Double(nominalFrameRate)).rounded()), 1)
            return CMTime(value: value, timescale: timescale)
        }

        return CMTime(value: 1, timescale: 30)
    }

    func preferredFrameRate(for track: AVAssetTrack, frameDuration: CMTime) -> Double {
        let nominalFrameRate = Double(track.nominalFrameRate)
        if nominalFrameRate > 0 {
            return nominalFrameRate
        }

        let durationSeconds = frameDuration.seconds
        if durationSeconds.isFinite, durationSeconds > 0 {
            return 1.0 / durationSeconds
        }

        return 30
    }

    func preferredAverageBitRate(for track: AVAssetTrack, renderSize: CGSize) -> Int {
        let estimatedDataRate = Int(track.estimatedDataRate.rounded())
        if estimatedDataRate > 0 {
            return max(estimatedDataRate, 2_000_000)
        }

        return max(Int(renderSize.width * renderSize.height), 2_000_000)
    }

    func sampleBufferDuration(_ sampleBuffer: CMSampleBuffer, fallback: CMTime) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.seconds > 0 {
            return duration
        }

        return fallback
    }

    func selectBackdropTemplate(for sourceURL: URL) throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "CineWall", code: 1023, userInfo: [NSLocalizedDescriptionKey: "The selected file does not contain a video track."])
        }

        let transformedSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let renderSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
        let sourceFrameRate = max(preferredFrameRate(for: videoTrack, frameDuration: preferredFrameDuration(for: videoTrack)), 1)

        let backdropCacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BackdropWallpaper/.cache", isDirectory: true)
        let templateURLs = try FileManager.default.contentsOfDirectory(at: backdropCacheURL, includingPropertiesForKeys: nil)
            .filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }

        guard !templateURLs.isEmpty else {
            throw NSError(domain: "CineWall", code: 1024, userInfo: [NSLocalizedDescriptionKey: "Backdrop-compatible mode needs local Backdrop templates, but none were found in \(backdropCacheURL.path). Open Backdrop once so it generates its cached wallpapers, then try again."])
        }

        var bestURL: URL?
        var bestScore = Double.greatestFiniteMagnitude

        for templateURL in templateURLs {
            let templateAsset = AVURLAsset(url: templateURL)
            guard let templateVideoTrack = templateAsset.tracks(withMediaType: .video).first else { continue }
            let templateSize = CGSize(width: templateVideoTrack.naturalSize.width, height: templateVideoTrack.naturalSize.height)
            let templateFrameRate = max(Double(templateVideoTrack.nominalFrameRate), 1)

            let sizeScore = abs(Double(renderSize.width - templateSize.width)) + abs(Double(renderSize.height - templateSize.height))
            let aspectRatio = max(renderSize.width, 1) / max(renderSize.height, 1)
            let templateAspectRatio = max(templateSize.width, 1) / max(templateSize.height, 1)
            let aspectScore = abs(Double(aspectRatio - templateAspectRatio)) * 10_000
            let frameRateScore = abs(sourceFrameRate - templateFrameRate) * 100
            let score = sizeScore * 10 + aspectScore + frameRateScore

            if score < bestScore {
                bestScore = score
                bestURL = templateURL
            }
        }

        guard let bestURL else {
            throw NSError(domain: "CineWall", code: 1025, userInfo: [NSLocalizedDescriptionKey: "Failed to find a usable Backdrop template in \(backdropCacheURL.path)."])
        }
        return bestURL
    }

    func exportCandidateVideoForBackdropHybrid(sourceURL: URL, destinationURL: URL, syncRequestID: Int) throws {
        let ffmpegURL = try locateFFmpegBinary()
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "CineWall", code: 1030, userInfo: [NSLocalizedDescriptionKey: "The selected file does not contain a video track."])
        }
        let transformedSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let renderSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
        let frameRate = max(preferredFrameRate(for: videoTrack, frameDuration: preferredFrameDuration(for: videoTrack)), 1)
        let keyframeInterval = max(Int(frameRate.rounded()) * 2, 1)
        let bitRateKbps = preferredHybridBitRateKbps(for: videoTrack, renderSize: renderSize)

        let hardwareArguments = backdropHybridCandidateArguments(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            bitRateKbps: bitRateKbps,
            keyframeInterval: keyframeInterval,
            useHardwareHEVC: true
        )

        do {
            try runExternalProcess(executableURL: ffmpegURL, arguments: hardwareArguments, failureCode: 1026, failurePrefix: "Failed to create the Backdrop-compatible candidate video with hardware HEVC", syncRequestID: syncRequestID)
        } catch {
            try throwIfIdleWallpaperSyncCancelled(syncRequestID)
            let softwareArguments = backdropHybridCandidateArguments(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                bitRateKbps: bitRateKbps,
                keyframeInterval: keyframeInterval,
                useHardwareHEVC: false
            )
            try runExternalProcess(executableURL: ffmpegURL, arguments: softwareArguments, failureCode: 1031, failurePrefix: "Failed to create the Backdrop-compatible candidate video with software HEVC after hardware fallback", syncRequestID: syncRequestID)
        }
    }

    func preferredHybridBitRateKbps(for track: AVAssetTrack, renderSize: CGSize) -> Int {
        let estimatedKbps = Int(track.estimatedDataRate / 1000.0)
        let pixelCount = Int(renderSize.width * renderSize.height)

        if pixelCount >= 3_840 * 2_160 {
            return max(estimatedKbps, 12_000)
        }
        return max(estimatedKbps, 4_500)
    }

    func backdropHybridCandidateArguments(sourceURL: URL, destinationURL: URL, bitRateKbps: Int, keyframeInterval: Int, useHardwareHEVC: Bool) -> [String] {
        if useHardwareHEVC {
            return [
                "-y",
                "-loglevel", "error",
                "-i", sourceURL.path,
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-c:v", "hevc_videotoolbox",
                "-allow_sw", "1",
                "-profile:v", "main10",
                "-pix_fmt", "p010le",
                "-bf", "0",
                "-b:v", "\(bitRateKbps)k",
                "-maxrate", "\(Int(Double(bitRateKbps) * 1.35))k",
                "-bufsize", "\(bitRateKbps * 2)k",
                "-g", "\(keyframeInterval)",
                "-tag:v", "hvc1",
                "-video_track_timescale", "600",
                "-fps_mode", "passthrough",
                "-c:a", "pcm_s16le",
                "-ar", "48000",
                "-ac", "2",
                destinationURL.path
            ]
        }

        return [
            "-y",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-c:v", "libx265",
            "-pix_fmt", "yuv420p10le",
            "-preset", "veryfast",
            "-tag:v", "hvc1",
            "-bf", "0",
            "-x265-params", "keyint=\(keyframeInterval):min-keyint=\(keyframeInterval):open-gop=0:bframes=0:no-b-adapt=1:repeat-headers=1:pools=4",
            "-video_track_timescale", "600",
            "-fps_mode", "passthrough",
            "-c:a", "pcm_s16le",
            "-ar", "48000",
            "-ac", "2",
            destinationURL.path
        ]
    }

    func runBackdropHybridizer(templateURL: URL, candidateURL: URL, destinationURL: URL, syncRequestID: Int) throws {
        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        do {
            try BackdropHybridizer.buildHybridMovie(templateURL: templateURL, candidateURL: candidateURL, destinationURL: destinationURL)
        } catch {
            let message = error.localizedDescription.isEmpty ? "Failed to build the Backdrop-compatible hybrid movie." : "Failed to build the Backdrop-compatible hybrid movie.\n\(error.localizedDescription)"
            throw NSError(domain: "CineWall", code: 1028, userInfo: [NSLocalizedDescriptionKey: message])
        }
        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
    }

    func locateFFmpegBinary() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]

        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        throw NSError(domain: "CineWall", code: 1029, userInfo: [NSLocalizedDescriptionKey: "Compatible mode now depends on ffmpeg with HEVC/x265 support, but ffmpeg was not found in a standard location."])
    }

    func runExternalProcess(executableURL: URL, arguments: [String], failureCode: Int, failurePrefix: String, syncRequestID: Int? = nil) throws {
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        if let syncRequestID {
            try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        }
        try task.run()
        if let syncRequestID {
            registerActiveIdleWallpaperProcess(task, requestID: syncRequestID)
        }
        task.waitUntilExit()
        if let syncRequestID {
            clearActiveIdleWallpaperProcess(task, requestID: syncRequestID)
            try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        }

        guard task.terminationStatus == 0 else {
            let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            let combined = [stderrText, stdoutText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let message = combined.isEmpty ? failurePrefix : "\(failurePrefix).\n\(combined)"
            throw NSError(domain: "CineWall", code: failureCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func beginIdleWallpaperSyncRequest() -> Int {
        idleWallpaperSyncStateQueue.sync {
            idleWallpaperSyncRequestCounter += 1
            latestIdleWallpaperSyncRequestID = idleWallpaperSyncRequestCounter
            if let activeIdleWallpaperProcess, activeIdleWallpaperProcess.isRunning {
                activeIdleWallpaperProcess.terminate()
            }
            return latestIdleWallpaperSyncRequestID
        }
    }

    func cancelActiveIdleWallpaperSync() {
        idleSyncWorkItem?.cancel()
        idleWallpaperSyncStateQueue.sync {
            idleWallpaperSyncRequestCounter += 1
            latestIdleWallpaperSyncRequestID = idleWallpaperSyncRequestCounter
            if let activeIdleWallpaperProcess, activeIdleWallpaperProcess.isRunning {
                activeIdleWallpaperProcess.terminate()
            }
            activeIdleWallpaperProcess = nil
        }
        setIdleWallpaperSyncInProgress(false)
    }

    func isIdleWallpaperSyncRequestCurrent(_ requestID: Int) -> Bool {
        idleWallpaperSyncStateQueue.sync { latestIdleWallpaperSyncRequestID == requestID }
    }

    func registerActiveIdleWallpaperProcess(_ process: Process, requestID: Int) {
        idleWallpaperSyncStateQueue.sync {
            guard latestIdleWallpaperSyncRequestID == requestID else {
                if process.isRunning {
                    process.terminate()
                }
                return
            }
            activeIdleWallpaperProcess = process
        }
    }

    func clearActiveIdleWallpaperProcess(_ process: Process, requestID: Int) {
        idleWallpaperSyncStateQueue.sync {
            guard latestIdleWallpaperSyncRequestID == requestID, activeIdleWallpaperProcess === process else { return }
            activeIdleWallpaperProcess = nil
        }
    }

    func setIdleWallpaperSyncInProgress(_ inProgress: Bool, requestID: Int? = nil) {
        var shouldRefreshUI = false
        idleWallpaperSyncStateQueue.sync {
            if let requestID, latestIdleWallpaperSyncRequestID != requestID {
                return
            }
            guard idleWallpaperSyncInProgress != inProgress else { return }
            idleWallpaperSyncInProgress = inProgress
            shouldRefreshUI = true
        }
        guard shouldRefreshUI else { return }
        DispatchQueue.main.async { [weak self] in
            self?.liquidController?.refreshUI()
        }
    }

    func idleWallpaperSyncCancelledError() -> NSError {
        NSError(domain: "CineWall", code: 1090, userInfo: [NSLocalizedDescriptionKey: "Idle wallpaper sync was superseded by a newer video selection."])
    }

    func isIdleWallpaperSyncCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "CineWall" && nsError.code == 1090
    }

    func throwIfIdleWallpaperSyncCancelled(_ requestID: Int) throws {
        guard isIdleWallpaperSyncRequestCurrent(requestID) else {
            throw idleWallpaperSyncCancelledError()
        }
    }

    func stableAerialAssetID(for sourceURL: URL) throws -> String {
        let resolvedURL = sourceURL.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let payload = "cinewall|\(idleWallpaperSyncMode.rawValue)|\(resolvedURL.path)|\(fileSize)|\(Int64(modified * 1000))"
        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        return "\(hexSegment(hex, 0, 8))-\(hexSegment(hex, 8, 12))-\(hexSegment(hex, 12, 16))-\(hexSegment(hex, 16, 20))-\(hexSegment(hex, 20, 32))"
    }

    func hexSegment(_ value: String, _ start: Int, _ end: Int) -> String {
        let startIndex = value.index(value.startIndex, offsetBy: start)
        let endIndex = value.index(value.startIndex, offsetBy: end)
        return String(value[startIndex..<endIndex])
    }

    func updateAerialManifest(manifestURL: URL, assetID: String, title: String, videoURL: URL, thumbnailURL: URL) throws {
        let data = try Data(contentsOf: manifestURL)
        guard var root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              var categories = root["categories"] as? [[String: Any]],
              var assets = root["assets"] as? [[String: Any]] else {
            throw NSError(domain: "CineWall", code: 1005, userInfo: [NSLocalizedDescriptionKey: "The aerial manifest has an unexpected format."])
        }

        let categoryEntry: [String: Any] = [
            "id": cineWallAerialCategoryID,
            "localizedDescriptionKey": "Use CineWall to change custom wallpapers",
            "localizedNameKey": "CineWall",
            "preferredOrder": 0,
            "previewImage": thumbnailURL.absoluteString,
            "representativeAssetID": assetID,
            "subcategories": [[
                "id": cineWallAerialSubcategoryID,
                "localizedDescriptionKey": "Use CineWall to change custom wallpapers",
                "localizedNameKey": "CineWall",
                "preferredOrder": 0,
                "previewImage": thumbnailURL.absoluteString,
                "representativeAssetID": assetID
            ]]
        ]

        let shotID = "CINEWALL_\(assetID.prefix(8))"
        let assetEntry: [String: Any] = [
            "accessibilityLabel": title,
            "categories": [cineWallAerialCategoryID],
            "id": assetID,
            "includeInShuffle": true,
            "localizedNameKey": title,
            "pointsOfInterest": ["0": "\(shotID)_0"],
            "preferredOrder": 0,
            "previewImage": thumbnailURL.absoluteString,
            "shotID": shotID,
            "showInTopLevel": true,
            "subcategories": [cineWallAerialSubcategoryID],
            "url-4K-SDR-240FPS": videoURL.absoluteString
        ]

        categories.append(categoryEntry)
        assets.append(assetEntry)
        root["categories"] = categories
        root["assets"] = assets

        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: manifestURL, options: .atomic)
    }

    func updateWallpaperStore(storeURL: URL, assetID: String) throws {
        let data = try Data(contentsOf: storeURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var root = try PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: &format) as? [String: Any] else {
            throw NSError(domain: "CineWall", code: 1006, userInfo: [NSLocalizedDescriptionKey: "The wallpaper store has an unexpected format."])
        }

        let now = Date()
        let configuration = try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        updateWallpaperNode(&root, key: "SystemDefault", configuration: configuration, date: now)

        if var displays = root["Displays"] as? [String: Any] {
            for key in displays.keys {
                if var display = displays[key] as? [String: Any] {
                    updateLinkedChoice(in: &display, configuration: configuration, date: now)
                    displays[key] = display
                }
            }
            root["Displays"] = displays
        }

        if var spaces = root["Spaces"] as? [String: Any] {
            for key in spaces.keys {
                guard var space = spaces[key] as? [String: Any] else { continue }
                updateWallpaperNode(&space, key: "Default", configuration: configuration, date: now)
                if var displays = space["Displays"] as? [String: Any] {
                    for displayKey in displays.keys {
                        if var display = displays[displayKey] as? [String: Any] {
                            updateLinkedChoice(in: &display, configuration: configuration, date: now)
                            displays[displayKey] = display
                        }
                    }
                    space["Displays"] = displays
                }
                spaces[key] = space
            }
            root["Spaces"] = spaces
        }

        let updated = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        try updated.write(to: storeURL, options: .atomic)
    }

    func updateWallpaperNode(_ root: inout [String: Any], key: String, configuration: Data, date: Date) {
        var node = root[key] as? [String: Any] ?? [:]
        updateLinkedChoice(in: &node, configuration: configuration, date: date)
        root[key] = node
    }

    func updateLinkedChoice(in node: inout [String: Any], configuration: Data, date: Date) {
        var linked = node["Linked"] as? [String: Any] ?? [:]
        var content = linked["Content"] as? [String: Any] ?? [:]
        content["Choices"] = [[
            "Configuration": configuration,
            "Files": [],
            "Provider": "com.apple.wallpaper.choice.aerials"
        ]]
        linked["Content"] = content
        linked["LastSet"] = date
        linked["LastUse"] = date
        node["Linked"] = linked
        node["Type"] = "linked"
    }

    func restartWallpaperAgent() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

private final class CineWallEncodedSampleWriter {
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private let finishSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var firstPTS: CMTime?
    private var storedError: Error?

    init(destinationURL: URL) throws {
        writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
        writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw NSError(domain: "CineWall", code: 1018, userInfo: [NSLocalizedDescriptionKey: "Failed to create a movie writer input for encoded HEVC samples."])
        }
        writer.add(writerInput)
    }

    func appendEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard storedError == nil else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            storedError = NSError(domain: "CineWall", code: 1019, userInfo: [NSLocalizedDescriptionKey: "The HEVC encoder produced a sample that was not ready."])
            return
        }

        if writer.status == .unknown {
            firstPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard writer.startWriting() else {
                storedError = writer.error ?? NSError(domain: "CineWall", code: 1020, userInfo: [NSLocalizedDescriptionKey: "Failed to start the movie writer for encoded HEVC samples."])
                return
            }
            writer.startSession(atSourceTime: firstPTS ?? .zero)
        }

        while !writerInput.isReadyForMoreMediaData {
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.001)
            lock.lock()
            guard storedError == nil else { return }
        }

        if !writerInput.append(sampleBuffer) {
            storedError = writer.error ?? NSError(domain: "CineWall", code: 1021, userInfo: [NSLocalizedDescriptionKey: "Failed to append an encoded HEVC sample to the movie writer."])
        }
    }

    func fail(status: OSStatus) {
        lock.lock()
        defer { lock.unlock() }
        guard storedError == nil else { return }
        storedError = NSError(domain: "CineWall", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "VTCompressionSession produced an error. Status: \(status)"])
    }

    func finishWriting() throws {
        lock.lock()
        if let storedError {
            lock.unlock()
            throw storedError
        }
        lock.unlock()

        writerInput.markAsFinished()
        writer.finishWriting { [finishSemaphore] in
            finishSemaphore.signal()
        }
        finishSemaphore.wait()

        if let error = storedError {
            throw error
        }
        if let error = writer.error {
            throw error
        }
        guard writer.status == .completed else {
            throw NSError(domain: "CineWall", code: 1022, userInfo: [NSLocalizedDescriptionKey: "The encoded HEVC writer did not complete successfully. Status: \(writer.status.rawValue)"])
        }
    }
}

private func cineWallCompressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) -> Void {
    guard let outputCallbackRefCon else { return }
    let writer = Unmanaged<CineWallEncodedSampleWriter>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    guard status == noErr, let sampleBuffer else {
        writer.fail(status: status)
        return
    }
    if infoFlags.contains(.frameDropped) { return }
    writer.appendEncodedSampleBuffer(sampleBuffer)
}

class ClickableWindow: NSWindow { weak var appDelegate: AppDelegate?; override func mouseDown(with event: NSEvent) { if !self.ignoresMouseEvents { appDelegate?.handleWallpaperClick() }; super.mouseDown(with: event) } }
