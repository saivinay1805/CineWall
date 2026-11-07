import Cocoa
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
    func isOccluded() -> Bool { guard let w = wallpaperWindow else { return false }; return !w.occlusionState.contains(.visible) || (NSScreen.main?.visibleFrame.height ?? 0) >= (NSScreen.main?.frame.height ?? 0) }
    func isOnBattery() -> Bool { return IOPSGetTimeRemainingEstimate() != kIOPSTimeRemainingUnlimited }
    func isDesktopFocused() -> Bool { guard let app = NSWorkspace.shared.frontmostApplication else { return true }; return app.bundleIdentifier == Bundle.main.bundleIdentifier || app.bundleIdentifier == "com.apple.finder" }

    @objc func stateChanged() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.updatePlaybackState() } }
    @objc func spaceDidChange() { ghostWindow?.orderFront(nil); stateChanged() }
    @objc func screenDidChange() { guard let w = wallpaperWindow, let s = NSScreen.main else { return }; targetScreen = s; w.setFrame(s.frame, display: true); layerA?.frame = w.contentView!.bounds; layerB?.frame = w.contentView!.bounds; gifView?.frame = w.contentView!.bounds }

    @objc func bringToCurrentDesktop() { guard let w = wallpaperWindow else { return }; if let s = NSScreen.main { w.setFrame(s.frame, display: true); layerA?.frame = w.contentView!.bounds; layerB?.frame = w.contentView!.bounds; gifView?.frame = w.contentView!.bounds }; w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]; w.orderFront(nil); if !showOnAllSpaces { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { w.collectionBehavior = [.stationary, .ignoresCycle]; self.updatePlaybackState() } } }
    func applyWindowLevel() { wallpaperWindow?.level = hideDesktopIcons ? NSWindow.Level(Int(CGWindowLevelForKey(.normalWindow)) - 1) : NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow))); wallpaperWindow?.ignoresMouseEvents = !hideDesktopIcons }
    func restoreFinder() { let t = Process(); t.launchPath = "/usr/bin/defaults"; t.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", "true"]; t.launch(); t.waitUntilExit() }

    func updateScalingMode() { let g: AVLayerVideoGravity = (scalingTag == 1) ? .resizeAspectFill : (scalingTag == 2 ? .resizeAspect : .resize); layerA?.videoGravity = g; layerB?.videoGravity = g; gifView?.layer?.contentsGravity = (scalingTag == 1) ? .resizeAspectFill : (scalingTag == 2 ? .resizeAspect : .resize) }
    func startStatsMonitor() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.liquidWindow?.isVisible == true else { return }
            self.liquidController?.updateStats()
        }
    }
    func getAppRAM() -> String { var i = task_vm_info_data_t(); var c = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size); if withUnsafeMutablePointer(to: &i, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &c) } }) == KERN_SUCCESS { return ByteCountFormatter.string(fromByteCount: Int64(i.phys_footprint), countStyle: .memory) }; return "0 MB" }
    func getAppCPU() -> Double { var t = 0.0; var l: thread_act_array_t?; var c = mach_msg_type_number_t(0); if task_threads(mach_task_self_, &l, &c) == KERN_SUCCESS, let l = l { for i in 0..<Int(c) { var info = thread_basic_info(); var ic = mach_msg_type_number_t(THREAD_INFO_MAX); let _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(ic)) { thread_info(l[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &ic) } }; if (info.flags & TH_FLAGS_IDLE == 0) { t += (Double(info.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0 } }; vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: l)), vm_size_t(Int(c) * MemoryLayout<thread_t>.stride)) }; return t }

    func createGhostWindow() { ghostWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false); ghostWindow?.alphaValue = 0.01; ghostWindow?.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]; ghostWindow?.orderFront(nil) }
    func createWindow() { let s = targetScreen ?? NSScreen.main!; let w = ClickableWindow(contentRect: s.frame, styleMask: [.borderless], backing: .buffered, defer: false); w.appDelegate = self; w.backgroundColor = .black; w.collectionBehavior = [.stationary, .ignoresCycle]; w.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow))); w.ignoresMouseEvents = true; wallpaperWindow = w; let v = NSView(); v.wantsLayer = true; playerA = AVPlayer(); playerB = AVPlayer(); layerA = AVPlayerLayer(player: playerA); layerB = AVPlayerLayer(player: playerB); layerA?.frame = s.frame; layerB?.frame = s.frame; layerA?.isHidden = true; layerB?.isHidden = true; v.layer?.addSublayer(layerA!); v.layer?.addSublayer(layerB!); gifView = NSImageView(frame: s.frame); gifView?.imageScaling = .scaleAxesIndependently; gifView?.isHidden = true; v.addSubview(gifView!); w.contentView = v; w.orderFront(nil); updateScalingMode() }
    func handleWallpaperClick() { if hideDesktopIcons { let s = CGEventSource(stateID: .hidSystemState); let d = CGEvent(keyboardEventSource: s, virtualKey: 103, keyDown: true); let u = CGEvent(keyboardEventSource: s, virtualKey: 103, keyDown: false); d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap) } }

}
