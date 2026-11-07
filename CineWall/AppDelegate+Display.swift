import Cocoa
import AVFoundation
import QuartzCore
import IOKit.ps

class ClickableWindow: NSWindow {
    weak var appDelegate: AppDelegate?
    override func mouseDown(with event: NSEvent) {
        if !self.ignoresMouseEvents {
            appDelegate?.handleWallpaperClick()
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Display, Space & Power Management
extension AppDelegate {
    func isOccluded() -> Bool {
        guard !wallpaperWindows.isEmpty else { return false }
        return wallpaperWindows.allSatisfy { w in
            !w.occlusionState.contains(.visible) || (w.screen?.visibleFrame.height ?? 0) >= (w.screen?.frame.height ?? 0)
        }
    }
    func isOnBattery() -> Bool { return IOPSGetTimeRemainingEstimate() != kIOPSTimeRemainingUnlimited }
    func isDesktopFocused() -> Bool { guard let app = NSWorkspace.shared.frontmostApplication else { return true }; return app.bundleIdentifier == Bundle.main.bundleIdentifier || app.bundleIdentifier == "com.apple.finder" }

    @objc func stateChanged() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.updatePlaybackState() } }
    @objc func spaceDidChange() { ghostWindow?.orderFront(nil); stateChanged() }
    
    @objc func screenDidChange() {
        let screens = NSScreen.screens
        if wallpaperWindows.count != screens.count {
            recreateWindows()
        } else {
            for (i, s) in screens.enumerated() {
                guard i < wallpaperWindows.count else { continue }
                let w = wallpaperWindows[i]
                w.setFrame(s.frame, display: true)
                w.contentView?.frame = NSRect(origin: .zero, size: s.frame.size)
                if i < layersA.count { layersA[i].frame = NSRect(origin: .zero, size: s.frame.size) }
                if i < layersB.count { layersB[i].frame = NSRect(origin: .zero, size: s.frame.size) }
                if i < gifViews.count { gifViews[i].frame = NSRect(origin: .zero, size: s.frame.size) }
            }
        }
        updateScalingMode()
        updatePlaybackState()
    }

    @objc func bringToCurrentDesktop() {
        let screens = NSScreen.screens
        for (i, s) in screens.enumerated() {
            guard i < wallpaperWindows.count else { continue }
            let w = wallpaperWindows[i]
            w.setFrame(s.frame, display: true)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.orderFront(nil)
        }
        if !showOnAllSpaces {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                for w in self.wallpaperWindows {
                    w.collectionBehavior = [.stationary, .ignoresCycle]
                }
                self.updatePlaybackState()
            }
        }
    }

    func applyWindowLevel() {
        let lvl = hideDesktopIcons ? NSWindow.Level(Int(CGWindowLevelForKey(.normalWindow)) - 1) : NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
        for w in wallpaperWindows {
            w.level = lvl
            w.ignoresMouseEvents = !hideDesktopIcons
        }
    }

    func restoreFinder() { let t = Process(); t.launchPath = "/usr/bin/defaults"; t.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", "true"]; t.launch(); t.waitUntilExit() }

    func updateScalingMode() {
        let g: AVLayerVideoGravity = (scalingTag == 1) ? .resizeAspectFill : (scalingTag == 2 ? .resizeAspect : .resize)
        for lay in layersA { lay.videoGravity = g }
        for lay in layersB { lay.videoGravity = g }
        let gContent: CALayerContentsGravity = (scalingTag == 1) ? .resizeAspectFill : (scalingTag == 2 ? .resizeAspect : .resize)
        for gv in gifViews {
            gv.layer?.contentsGravity = gContent
            gv.imageScaling = (scalingTag == 1) ? .scaleAxesIndependently : .scaleProportionallyUpOrDown
        }
    }

    func startStatsMonitor() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.liquidWindow?.isVisible == true else { return }
            self.liquidController?.updateStats()
        }
    }

    func getAppRAM() -> String { var i = task_vm_info_data_t(); var c = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size); if withUnsafeMutablePointer(to: &i, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &c) } }) == KERN_SUCCESS { return ByteCountFormatter.string(fromByteCount: Int64(i.phys_footprint), countStyle: .memory) }; return "0 MB" }
    func getAppCPU() -> Double { var t = 0.0; var l: thread_act_array_t?; var c = mach_msg_type_number_t(0); if task_threads(mach_task_self_, &l, &c) == KERN_SUCCESS, let l = l { for i in 0..<Int(c) { var info = thread_basic_info(); var ic = mach_msg_type_number_t(THREAD_INFO_MAX); let _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(ic)) { thread_info(l[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &ic) } }; if (info.flags & TH_FLAGS_IDLE == 0) { t += (Double(info.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0 } }; vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: l)), vm_size_t(Int(c) * MemoryLayout<thread_t>.stride)) }; return t }

    func createGhostWindow() { ghostWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false); ghostWindow?.alphaValue = 0.01; ghostWindow?.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]; ghostWindow?.orderFront(nil) }

    func createWindow() {
        recreateWindows()
    }

    func recreateWindows() {
        for w in wallpaperWindows {
            w.orderOut(nil)
        }
        wallpaperWindows.removeAll()
        layersA.removeAll()
        layersB.removeAll()
        gifViews.removeAll()

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        if playerA == nil { playerA = AVPlayer() }
        if playerB == nil { playerB = AVPlayer() }

        let g: AVLayerVideoGravity = (scalingTag == 1) ? .resizeAspectFill : (scalingTag == 2 ? .resizeAspect : .resize)

        for s in screens {
            let w = ClickableWindow(contentRect: s.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.appDelegate = self
            w.backgroundColor = .black
            w.collectionBehavior = showOnAllSpaces ? [.canJoinAllSpaces, .stationary, .ignoresCycle] : [.stationary, .ignoresCycle]
            w.level = hideDesktopIcons ? NSWindow.Level(Int(CGWindowLevelForKey(.normalWindow)) - 1) : NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
            w.ignoresMouseEvents = !hideDesktopIcons

            let v = NSView(frame: NSRect(origin: .zero, size: s.frame.size))
            v.wantsLayer = true
            v.autoresizingMask = [.width, .height]

            let layA = AVPlayerLayer(player: playerA)
            layA.frame = v.bounds
            layA.videoGravity = g
            layA.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layA.isHidden = (activePlayerIndex != 0)
            layA.opacity = (activePlayerIndex == 0) ? 1.0 : 0.0
            v.layer?.addSublayer(layA)
            layersA.append(layA)

            let layB = AVPlayerLayer(player: playerB)
            layB.frame = v.bounds
            layB.videoGravity = g
            layB.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layB.isHidden = (activePlayerIndex != 1)
            layB.opacity = (activePlayerIndex == 1) ? 1.0 : 0.0
            v.layer?.addSublayer(layB)
            layersB.append(layB)

            let gView = NSImageView(frame: v.bounds)
            gView.autoresizingMask = [.width, .height]
            gView.imageScaling = (scalingTag == 1) ? .scaleAxesIndependently : .scaleProportionallyUpOrDown
            gView.isHidden = true
            v.addSubview(gView)
            gifViews.append(gView)

            w.contentView = v
            w.orderFront(nil)
            wallpaperWindows.append(w)
        }
        updateScalingMode()
    }

    func handleWallpaperClick() { if hideDesktopIcons { let s = CGEventSource(stateID: .hidSystemState); let d = CGEvent(keyboardEventSource: s, virtualKey: 103, keyDown: true); let u = CGEvent(keyboardEventSource: s, virtualKey: 103, keyDown: false); d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap) } }
}
