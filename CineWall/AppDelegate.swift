import Cocoa
import AVFoundation
import ServiceManagement

let liquidMenuWidth: CGFloat = 320
let liquidMenuHeight: CGFloat = 520
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
    var isPopoverOpen: Bool = false
    var isPinned: Bool = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    let proManager = ProManager.shared
    let sparkleUpdater = SparkleUpdater.shared

    // --- WALLPAPER ENGINE ---
    var wallpaperWindows: [ClickableWindow] = []
    var wallpaperWindow: ClickableWindow? {
        get { wallpaperWindows.first }
        set {
            if let val = newValue {
                if !wallpaperWindows.contains(where: { $0 === val }) {
                    wallpaperWindows.append(val)
                }
            } else {
                wallpaperWindows.removeAll()
            }
        }
    }
    var ghostWindow: NSWindow?
    var playerA: AVPlayer?
    var playerB: AVPlayer?
    var layersA: [AVPlayerLayer] = []
    var layersB: [AVPlayerLayer] = []
    var layerA: AVPlayerLayer? { layersA.first }
    var layerB: AVPlayerLayer? { layersB.first }
    var activePlayerIndex: Int = 0
    var gifViews: [NSImageView] = []
    var gifView: NSImageView? { gifViews.first }
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
                let aspect: CGFloat = img.size.width / max(1, img.size.height)
                let height: CGFloat = 11.0
                let width = round(height * aspect)
                img.size = NSSize(width: width, height: height)
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: "CineWall")
            }
            button.imagePosition = .imageOnly
            button.action = #selector(toggleLiquidPopover)
            button.target = self
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
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
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(toggleLiquidPopover), name: NSNotification.Name("com.cinewall.togglePopover"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openPlayerSubmenuForTest), name: NSNotification.Name("com.cinewall.openPlayerDetail"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openSettingsSubmenuForTest), name: NSNotification.Name("com.cinewall.openSettingsDetail"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(triggerLockScreenSyncForTest), name: NSNotification.Name("com.cinewall.syncLockScreen"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(nextFile), name: NSNotification.Name("com.cinewall.nextTrack"), object: nil)
    }

    @objc func triggerLockScreenSyncForTest() {
        syncCurrentVideoToIdleWallpaper(showAlerts: false)
    }

    @objc func openPlayerSubmenuForTest() {
        if isPopoverOpen {
            closePopover(force: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.openPopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self?.liquidController?.showPlayerDetailTest()
            }
        }
    }

    @objc func openSettingsSubmenuForTest() {
        if isPopoverOpen {
            closePopover(force: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.openPopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self?.liquidController?.showSettingsDetailTest()
            }
        }
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
    
    // MARK: - Liquid Glass Popover Lifecycle (ThemeEngine Alignment & Positioning)
    func createLiquidPopover() {
        let win = LiquidPanel(
            contentRect: NSRect(x: 0, y: 0, width: liquidMenuWidth, height: liquidMenuHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.registerForDraggedTypes([.fileURL])
        win.minSize = NSSize(width: 40, height: 30)
        win.maxSize = NSSize(width: 1000, height: 1000)
        
        let vc = LiquidMenuController()
        vc.appDelegate = self
        win.contentView = vc.view
        
        self.liquidWindow = win
        self.liquidController = vc
    }

    private var menuAnimationTimer: Timer?

    @objc func toggleLiquidPopover() {
        if isPopoverOpen {
            closePopover(force: true)
        } else {
            openPopover()
        }
    }

    func openPopover() {
        guard let window = liquidWindow, let button = statusItem.button else { return }
        guard let screen = button.window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        isPopoverOpen = true
        button.isHighlighted = true

        syncAccessControlledState()
        liquidController?.refreshUI()
        liquidController?.updateStats()
        liquidController?.resetToMainMenu()
        liquidController?.setMenuVisible(true)
        window.isMovableByWindowBackground = isPinned

        // Calculate clamped screen position relative to status item button (from ThemeEngine)
        let visible = screen.visibleFrame
        let buttonScreenRect = button.window?.convertToScreen(button.frame) ?? .zero

        var x = buttonScreenRect.origin.x - (liquidMenuWidth / 2) + (buttonScreenRect.width / 2)
        let topY = buttonScreenRect.minY - 6
        let y = topY - liquidMenuHeight

        let minX = visible.minX + 8
        let maxX = visible.maxX - liquidMenuWidth - 8

        if x < minX {
            x = minX
        } else if x > maxX {
            x = maxX
        }

        let targetFrame = NSRect(x: x, y: y, width: liquidMenuWidth, height: liquidMenuHeight)

        // Start frame: compact pill positioned at the menubar button
        let startW: CGFloat = 80
        let startH: CGFloat = 36
        let startX = min(max(buttonScreenRect.midX - startW / 2, visible.minX + 8), visible.maxX - startW - 8)
        let startY = topY - startH
        let startFrame = NSRect(x: startX, y: startY, width: startW, height: startH)

        animateMenuOpening(from: startFrame, to: targetFrame)

        NSApp.activate(ignoringOtherApps: true)

        if !isPinned {
            setupTransiencyMonitors()
        }
    }

    private func animateMenuOpening(from startFrame: NSRect, to targetFrame: NSRect) {
        menuAnimationTimer?.invalidate()
        menuAnimationTimer = nil

        guard let window = liquidWindow else { return }
        let startTime = CACurrentMediaTime()
        let duration = VorssaintMotion.settlingTime(from: startFrame, to: targetFrame)

        window.setFrame(startFrame, display: true)
        window.alphaValue = 1.0
        liquidController?.mainStack.alphaValue = 0
        window.makeKeyAndOrderFront(nil)

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self = self, let win = self.liquidWindow else {
                t.invalidate()
                return
            }
            let elapsed = CACurrentMediaTime() - startTime
            if elapsed >= duration {
                t.invalidate()
                self.menuAnimationTimer = nil
                win.setFrame(targetFrame, display: true)
                self.liquidController?.mainStack.alphaValue = 1.0
            } else {
                let currentFrame = VorssaintMotion.interpolateRect(from: startFrame, to: targetFrame, time: elapsed)
                win.setFrame(currentFrame, display: true)
                let contentAlpha = CGFloat(max(0.0, min(1.0, (elapsed - 0.06) / 0.22)))
                self.liquidController?.mainStack.alphaValue = contentAlpha
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuAnimationTimer = timer
    }

    func closePopover(force: Bool = false) {
        if isPinned && !force { return }

        isPopoverOpen = false
        statusItem?.button?.isHighlighted = false
        liquidController?.setMenuVisible(false)
        removeTransiencyMonitors()

        guard let window = liquidWindow, window.isVisible else { return }

        menuAnimationTimer?.invalidate()
        menuAnimationTimer = nil

        guard let button = statusItem.button,
              let screen = button.window?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            window.orderOut(nil)
            return
        }

        let buttonScreenRect = button.window?.convertToScreen(button.frame) ?? .zero
        let visible = screen.visibleFrame
        let topY = buttonScreenRect.minY - 6
        let startW: CGFloat = 80
        let startH: CGFloat = 36
        let startX = min(max(buttonScreenRect.midX - startW / 2, visible.minX + 8), visible.maxX - startW - 8)
        let targetCollapseFrame = NSRect(x: startX, y: topY - startH, width: startW, height: startH)

        let currentFrame = window.frame
        let startTime = CACurrentMediaTime()
        let duration = max(VorssaintMotion.shrinkingWidth.duration, VorssaintMotion.shrinkingHeight.duration) * 1.05

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self = self, let win = self.liquidWindow else {
                t.invalidate()
                return
            }
            let elapsed = CACurrentMediaTime() - startTime
            if elapsed >= duration {
                t.invalidate()
                self.menuAnimationTimer = nil
                win.orderOut(nil)
                win.setFrame(currentFrame, display: false)
                win.alphaValue = 1.0
            } else {
                let frame = VorssaintMotion.interpolateRect(from: currentFrame, to: targetCollapseFrame, time: elapsed)
                win.setFrame(frame, display: true)
                let alpha = CGFloat(max(0.0, 1.0 - (elapsed / (duration * 0.75))))
                win.alphaValue = alpha
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuAnimationTimer = timer
    }

    func setupTransiencyMonitors() {
        removeTransiencyMonitors()

        // 1. Global mouse monitor for clicks in other apps
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.handleOutsideClick()
        }

        // 2. Local mouse monitor for clicks within CineWall windows
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideClick()
            return event
        }

        // 3. Local key monitor for Escape key
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isPopoverOpen, !self.isPinned else {
                return event
            }
            if event.keyCode == 53 { // ESC key
                self.closePopover()
                return nil
            }
            return event
        }
    }

    func removeTransiencyMonitors() {
        if let m = globalMouseMonitor {
            NSEvent.removeMonitor(m)
            globalMouseMonitor = nil
        }
        if let m = localMouseMonitor {
            NSEvent.removeMonitor(m)
            localMouseMonitor = nil
        }
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
    }

    @discardableResult
    private func handleOutsideClick() -> Bool {
        guard isPopoverOpen, let window = liquidWindow, window.isVisible, !isPinned else { return false }

        let mouseLoc = NSEvent.mouseLocation

        // Check if click was on the status bar button (with a slight padding for hit-test margin)
        if let button = statusItem?.button, let btnWin = button.window {
            let buttonScreenRect = btnWin.convertToScreen(button.frame).insetBy(dx: -4, dy: -4)
            if buttonScreenRect.contains(mouseLoc) {
                // Click is on the status bar button itself; let button action handle the toggle
                return false
            }
        }

        // Check if click was inside the popover window itself
        if window.frame.contains(mouseLoc) {
            return false
        }

        // Click was truly outside both; close cleanly
        closePopover()
        return true
    }

    func togglePin() {
        isPinned.toggle()
        liquidWindow?.isMovableByWindowBackground = isPinned
        if isPinned {
            removeTransiencyMonitors()
        } else {
            if isPopoverOpen {
                setupTransiencyMonitors()
            }
        }
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
        return true
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

    // Open source compatibility stubs
    func startProTrial(completion: ((Bool, String) -> Void)? = nil) { completion?(true, "CineWall is 100% Free & Open Source.") }
    func activateLicenseKey(_ key: String) {}
    func toggleDeveloperProUnlock() {}
    func resetDebugProTrialState(completion: ((Bool, String) -> Void)? = nil) { completion?(true, "Reset complete.") }
}
