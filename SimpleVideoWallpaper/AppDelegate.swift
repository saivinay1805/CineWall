import Cocoa
import AVFoundation
import ServiceManagement
import QuartzCore
import IOKit.ps

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {

    // --- UI ENGINE ---
    var statusItem: NSStatusItem!
    var liquidWindow: LiquidPanel?
    var liquidController: LiquidMenuController?
    var favWindow: LiquidPanel?
    var favController: FavoritesViewController?
    var popoverTransiency: Any?
    var isPinned: Bool = false

    // --- WALLPAPER ENGINE ---
    var wallpaperWindow: ClickableWindow?
    var ghostWindow: NSWindow?
    var playerA: AVPlayer?
    var playerB: AVPlayer?
    var layerA: AVPlayerLayer?
    var layerB: AVPlayerLayer?
    var activePlayerIndex: Int = 0
    var gifView: NSImageView?
    
    // --- STATE ---
    var allFiles: [URL] = []
    var currentQueue: [URL] = []
    var favorites: [String] = []
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
    var isFavoritesOnly: Bool = false
    var scalingTag: Int = 1
    var autoChangeInterval: Double = 0
    var showOnAllSpaces: Bool = false
    
    // Smart Rules
    var smartPauseEnabled: Bool = true
    var batterySaverEnabled: Bool = false
    var focusPauseEnabled: Bool = false
    var focusMuteEnabled: Bool = false
    var hideDesktopIcons: Bool = false
    
    var lastFolderPath: String?
    var lastPlayedFile: String? // NEW: Remembers exact file
    var targetScreen: NSScreen?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadSettings()
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
    }
    
    func applicationWillTerminate(_ aNotification: Notification) { saveSettings() }
    
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
        stopAllPlayers()
        gifView?.isHidden = true; layerA?.isHidden = true; layerB?.isHidden = true
        
        if currentQueue.isEmpty {
            liquidController?.updateTrackInfo(title: "No Media", image: nil, isFav: false)
            return
        }
        
        if queueIndex >= currentQueue.count { queueIndex = 0 }
        let currentFile = currentQueue[queueIndex]
        let isFav = favorites.contains(currentFile.path)
        
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
        
        resetPlaylistTimer(); updatePlaybackState(); liquidController?.refreshUI()
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
        
        activePlayer?.replaceCurrentItem(with: item)
        activePlayer?.volume = isMuted ? 0 : volumeLevel
        activePlayer?.actionAtItemEnd = .none
        
        setupTimeObserver(for: activePlayer!)
        
        CATransaction.begin(); CATransaction.setAnimationDuration(0.5)
        activeLayer?.isHidden = false; activeLayer?.opacity = 1.0; hiddenLayer?.opacity = 0.0
        CATransaction.commit()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { hiddenLayer?.isHidden = true; hiddenLayer?.player?.replaceCurrentItem(with: nil) }
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
    }
    
    // (Standard Helpers - Minimized for brevity as they haven't changed)
    @objc func nextFile() { if !currentQueue.isEmpty { queueIndex += 1; if queueIndex >= currentQueue.count { queueIndex = 0 }; startPlayback() } }
    @objc func prevFile() { if !currentQueue.isEmpty { queueIndex -= 1; if queueIndex < 0 { queueIndex = currentQueue.count - 1 }; startPlayback() } }
    func setupTimeObserver(for player: AVPlayer) { if let ob = timeObserver, let owner = timeObserverOwner { owner.removeTimeObserver(ob); timeObserver = nil; timeObserverOwner = nil }; let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC)); timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in guard let self = self, !self.isSeeking, let duration = player.currentItem?.duration.seconds, duration > 0 else { return }; self.liquidController?.progressSlider.doubleValue = time.seconds / duration }; timeObserverOwner = player }
    func seekTo(percentage: Double) { let activePlayer = (activePlayerIndex == 0) ? playerA : playerB; guard let duration = activePlayer?.currentItem?.duration.seconds else { return }; isSeeking = true; activePlayer?.seek(to: CMTime(seconds: duration * percentage, preferredTimescale: 1000)) { [weak self] _ in self?.isSeeking = false } }
    func toggleMuteState() { isMuted.toggle(); saveSettings(); updateVolumeState(); liquidController?.refreshUI() }
    func toggleFavorite() { if currentQueue.isEmpty { return }; let path = currentQueue[queueIndex].path; if let idx = favorites.firstIndex(of: path) { favorites.remove(at: idx) } else { favorites.append(path) }; saveSettings(); liquidController?.updateFavIcon(favorites.contains(path)); favController?.reloadData(); if isFavoritesOnly && !favorites.contains(path) { refreshQueue(); startPlayback() } }
    func removeFavorite(path: String) { if let idx = favorites.firstIndex(of: path) { favorites.remove(at: idx) }; saveSettings(); favController?.reloadData(); if !currentQueue.isEmpty && currentQueue[queueIndex].path == path { liquidController?.updateFavIcon(false) }; if isFavoritesOnly { refreshQueue(); startPlayback() } }
    func refreshQueue() { currentQueue = isFavoritesOnly ? allFiles.filter { favorites.contains($0.path) } : (isShuffle ? allFiles.shuffled() : allFiles); queueIndex = 0 }
    func generateThumbnail(for url: URL, completion: @escaping (NSImage?) -> Void) { if url.pathExtension.lowercased() == "gif" { completion(NSImage(contentsOf: url)); return }; DispatchQueue.global(qos: .userInitiated).async { let asset = AVAsset(url: url); let gen = AVAssetImageGenerator(asset: asset); gen.appliesPreferredTrackTransform = true; do { let cg = try gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 60), actualTime: nil); DispatchQueue.main.async { completion(NSImage(cgImage: cg, size: .zero)) } } catch { DispatchQueue.main.async { completion(nil) } } } }
    func updatePlaybackState() { if isManualPaused || (focusPauseEnabled && !isDesktopFocused()) || (smartPauseEnabled && !showOnAllSpaces && isOccluded()) || (batterySaverEnabled && isOnBattery()) { performPause(); return }; performPlay(); updateVolumeState() }
    func isOccluded() -> Bool { guard let w = wallpaperWindow else { return false }; return !w.occlusionState.contains(.visible) || (NSScreen.main?.visibleFrame.height ?? 0) >= (NSScreen.main?.frame.height ?? 0) }
    func isOnBattery() -> Bool { return IOPSGetTimeRemainingEstimate() != kIOPSTimeRemainingUnlimited }
    func isDesktopFocused() -> Bool { guard let app = NSWorkspace.shared.frontmostApplication else { return true }; return app.bundleIdentifier == Bundle.main.bundleIdentifier || app.bundleIdentifier == "com.apple.finder" }
    func performPlay() { let p = (activePlayerIndex == 0) ? playerA : playerB; if p?.rate == 0 { p?.play() }; if !(gifView?.isHidden ?? true) { gifView?.animates = true; if !isLoopingCurrent && autoChangeInterval == 0 && gifTimer == nil { /* Restart GIF timer if needed logic here */ } } }
    func performPause() { let p = (activePlayerIndex == 0) ? playerA : playerB; if p?.rate != 0 { p?.pause() }; if !(gifView?.isHidden ?? true) { gifView?.animates = false; gifTimer?.invalidate(); gifTimer = nil } }
    func updateVolumeState() { let v = (isMuted || (focusMuteEnabled && !isDesktopFocused())) ? 0 : volumeLevel; playerA?.volume = v; playerB?.volume = v }
    @objc func stateChanged() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.updatePlaybackState() } }
    @objc func spaceDidChange() { ghostWindow?.orderFront(nil); stateChanged() }
    @objc func screenDidChange() { guard let w = wallpaperWindow, let s = NSScreen.main else { return }; targetScreen = s; w.setFrame(s.frame, display: true); layerA?.frame = w.contentView!.bounds; layerB?.frame = w.contentView!.bounds; gifView?.frame = w.contentView!.bounds }
    func resetPlaylistTimer() { playlistTimer?.invalidate(); guard autoChangeInterval > 0, !currentQueue.isEmpty else { return }; playlistTimer = Timer.scheduledTimer(withTimeInterval: autoChangeInterval, repeats: true) { [weak self] _ in self?.nextFile() } }
    @objc func bringToCurrentDesktop() { guard let w = wallpaperWindow else { return }; if let s = NSScreen.main { w.setFrame(s.frame, display: true); layerA?.frame = w.contentView!.bounds; layerB?.frame = w.contentView!.bounds; gifView?.frame = w.contentView!.bounds }; w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]; w.orderFront(nil); if !showOnAllSpaces { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { w.collectionBehavior = [.stationary, .ignoresCycle]; self.updatePlaybackState() } } }
    func applyWindowLevel() { wallpaperWindow?.level = hideDesktopIcons ? NSWindow.Level(Int(CGWindowLevelForKey(.normalWindow)) - 1) : NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow))); wallpaperWindow?.ignoresMouseEvents = !hideDesktopIcons }
    func restoreFinder() { let t = Process(); t.launchPath = "/usr/bin/defaults"; t.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", "true"]; t.launch(); t.waitUntilExit() }
    func selectFolder() { let d = NSOpenPanel(); d.canChooseDirectories = true; d.canChooseFiles = false; if d.runModal() == .OK, let url = d.url { loadFolder(folderUrl: url, autoStart: true) } }
    func terminateApp() { saveSettings(); NSApplication.shared.terminate(self) }
    func updateScalingMode() { let g: AVLayerVideoGravity = (scalingTag == 1) ? .resizeAspectFill : (scalingTag == 2 ? .resizeAspect : .resize); layerA?.videoGravity = g; layerB?.videoGravity = g; gifView?.layer?.contentsGravity = (scalingTag == 1) ? .resizeAspectFill : (scalingTag == 2 ? .resizeAspect : .resize) }
    func startStatsMonitor() { statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.liquidController?.updateStats() } }
    func getAppRAM() -> String { var i = task_vm_info_data_t(); var c = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size); if withUnsafeMutablePointer(to: &i, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &c) } }) == KERN_SUCCESS { return ByteCountFormatter.string(fromByteCount: Int64(i.phys_footprint), countStyle: .memory) }; return "0 MB" }
    func getAppCPU() -> Double { var t = 0.0; var l: thread_act_array_t?; var c = mach_msg_type_number_t(0); if task_threads(mach_task_self_, &l, &c) == KERN_SUCCESS, let l = l { for i in 0..<Int(c) { var info = thread_basic_info(); var ic = mach_msg_type_number_t(THREAD_INFO_MAX); let _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(ic)) { thread_info(l[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &ic) } }; if (info.flags & TH_FLAGS_IDLE == 0) { t += (Double(info.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0 } }; vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: l)), vm_size_t(Int(c) * MemoryLayout<thread_t>.stride)) }; return t }
    func saveSettings() { let d = UserDefaults.standard; d.set(isMuted, forKey: "isMuted"); d.set(volumeLevel, forKey: "volumeLevel"); d.set(isShuffle, forKey: "isShuffle"); d.set(showOnAllSpaces, forKey: "showOnAllSpaces"); d.set(smartPauseEnabled, forKey: "smartPause"); d.set(focusPauseEnabled, forKey: "focusPause"); d.set(focusMuteEnabled, forKey: "focusMute"); d.set(batterySaverEnabled, forKey: "batterySaver"); d.set(hideDesktopIcons, forKey: "hideDesktopIcons"); d.set(isLoopingCurrent, forKey: "isLoopingCurrent"); d.set(isFavoritesOnly, forKey: "isFavOnly"); d.set(scalingTag, forKey: "scalingTag"); d.set(autoChangeInterval, forKey: "autoChangeInterval"); d.set(favorites, forKey: "favorites"); if let path = lastFolderPath { d.set(path, forKey: "lastFolderPath") }; if let file = lastPlayedFile { d.set(file, forKey: "lastPlayedFile") } }
    func loadSettings() { let d = UserDefaults.standard; isMuted = d.bool(forKey: "isMuted"); volumeLevel = d.float(forKey: "volumeLevel"); isShuffle = d.bool(forKey: "isShuffle"); showOnAllSpaces = d.bool(forKey: "showOnAllSpaces"); smartPauseEnabled = d.bool(forKey: "smartPause"); focusPauseEnabled = d.bool(forKey: "focusPause"); focusMuteEnabled = d.bool(forKey: "focusMute"); batterySaverEnabled = d.bool(forKey: "batterySaver"); hideDesktopIcons = d.bool(forKey: "hideDesktopIcons"); lastFolderPath = d.string(forKey: "lastFolderPath"); lastPlayedFile = d.string(forKey: "lastPlayedFile"); isLoopingCurrent = d.bool(forKey: "isLoopingCurrent"); isFavoritesOnly = d.bool(forKey: "isFavOnly"); autoChangeInterval = d.double(forKey: "autoChangeInterval"); scalingTag = d.integer(forKey: "scalingTag"); if scalingTag == 0 { scalingTag = 1 }; favorites = d.stringArray(forKey: "favorites") ?? []; if volumeLevel == 0.0 { volumeLevel = 0.5 } }
    
    // ... UI Handling (same as before) ...
    func createLiquidPopover() { let win = LiquidPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 620), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false); win.level = .floating; win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; win.backgroundColor = .clear; win.isOpaque = false; win.hasShadow = true; win.titlebarAppearsTransparent = true; win.titleVisibility = .hidden; win.registerForDraggedTypes([.fileURL]); win.minSize = NSSize(width: 320, height: 620); win.maxSize = NSSize(width: 320, height: 800); let vc = LiquidMenuController(); vc.appDelegate = self; win.contentView = vc.view; self.liquidWindow = win; self.liquidController = vc }
    @objc func toggleLiquidPopover() { guard let window = liquidWindow, let button = statusItem.button else { return }; if window.isVisible { closePopover() } else { liquidController?.refreshUI(); let buttonRect = button.window?.convertToScreen(button.frame) ?? .zero; let x = buttonRect.origin.x - (320 / 2) + (buttonRect.width / 2); let y = buttonRect.origin.y - 620 - 5; window.setFrameOrigin(NSPoint(x: x, y: y)); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); if !isPinned { setupTransiencyMonitor() } } }
    func setupTransiencyMonitor() { if popoverTransiency != nil { return }; popoverTransiency = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.closePopover() } }
    func removeTransiencyMonitor() { if let m = popoverTransiency { NSEvent.removeMonitor(m); popoverTransiency = nil } }
    func togglePin() { isPinned.toggle(); if isPinned { removeTransiencyMonitor() } else { setupTransiencyMonitor() } }
    func closePopover() { if isPinned { return }; liquidWindow?.orderOut(nil); favWindow?.orderOut(nil); removeTransiencyMonitor() }
    func handleDroppedFile(url: URL) { let ext = url.pathExtension.lowercased(); if ["mp4", "mov", "m4v", "gif"].contains(ext) { if currentQueue.isEmpty { currentQueue = [url]; queueIndex = 0 } else { if let idx = currentQueue.firstIndex(of: url) { queueIndex = idx } else { currentQueue.insert(url, at: queueIndex + 1); queueIndex += 1 } }; startPlayback() } }
    func revealCurrentInFinder() { if !currentQueue.isEmpty && queueIndex < currentQueue.count { NSWorkspace.shared.activateFileViewerSelecting([currentQueue[queueIndex]]) } }
    func showFavoritesWindow() { if favWindow == nil { let win = LiquidPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 400), styleMask: [.borderless, .closable, .resizable], backing: .buffered, defer: false); win.level = .floating; win.backgroundColor = .clear; win.isOpaque = false; win.hasShadow = true; win.titlebarAppearsTransparent = true; let vc = FavoritesViewController(); vc.appDelegate = self; win.contentView = vc.view; self.favWindow = win; self.favController = vc }; if let mainFrame = liquidWindow?.frame { let x = mainFrame.origin.x + mainFrame.width + 10; let y = mainFrame.origin.y + mainFrame.height - 400; favWindow?.setFrameOrigin(NSPoint(x: x, y: y)) }; favController?.reloadData(); favWindow?.makeKeyAndOrderFront(nil) }
    func playFavorite(at index: Int) { if index < favorites.count { let url = URL(fileURLWithPath: favorites[index]); if !currentQueue.contains(url) { currentQueue.append(url) }; if let idx = currentQueue.firstIndex(of: url) { queueIndex = idx; startPlayback() } } }
    
    // WINDOW CLASSES
    func createGhostWindow() { ghostWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false); ghostWindow?.alphaValue = 0.01; ghostWindow?.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]; ghostWindow?.orderFront(nil) }
    func createWindow() { let s = targetScreen ?? NSScreen.main!; let w = ClickableWindow(contentRect: s.frame, styleMask: [.borderless], backing: .buffered, defer: false); w.appDelegate = self; w.backgroundColor = .black; w.collectionBehavior = [.stationary, .ignoresCycle]; w.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow))); w.ignoresMouseEvents = true; wallpaperWindow = w; let v = NSView(); v.wantsLayer = true; playerA = AVPlayer(); playerB = AVPlayer(); layerA = AVPlayerLayer(player: playerA); layerB = AVPlayerLayer(player: playerB); layerA?.frame = s.frame; layerB?.frame = s.frame; layerA?.isHidden = true; layerB?.isHidden = true; v.layer?.addSublayer(layerA!); v.layer?.addSublayer(layerB!); gifView = NSImageView(frame: s.frame); gifView?.imageScaling = .scaleAxesIndependently; gifView?.isHidden = true; v.addSubview(gifView!); w.contentView = v; w.orderFront(nil); updateScalingMode() }
    func handleWallpaperClick() { if hideDesktopIcons { let s = CGEventSource(stateID: .hidSystemState); let d = CGEvent(keyboardEventSource: s, virtualKey: 103, keyDown: true); let u = CGEvent(keyboardEventSource: s, virtualKey: 103, keyDown: false); d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap) } }
}
class ClickableWindow: NSWindow { weak var appDelegate: AppDelegate?; override func mouseDown(with event: NSEvent) { if !self.ignoresMouseEvents { appDelegate?.handleWallpaperClick() }; super.mouseDown(with: event) } }
