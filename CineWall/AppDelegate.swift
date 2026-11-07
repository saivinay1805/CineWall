import Cocoa
import AVFoundation
import ServiceManagement

let liquidMenuWidth: CGFloat = 370
let liquidMenuHeight: CGFloat = 610
let cineWallAerialCategoryID = "91F55C9A-8E4B-4C1D-9A8C-2B759F17A001"
let cineWallAerialSubcategoryID = "91F55C9A-8E4B-4C1D-9A8C-2B759F17A002"
let cineWallWallpaperStoreBackupFileName = "Index.pre-cinewall.plist"

enum IdleWallpaperSyncMode: String {
    case fast
    case compatible
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

    func terminateApp() {
        saveSettings()
        NSApplication.shared.terminate(self)
    }

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

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

}
