import Cocoa
import ServiceManagement

// MARK: - GLASS COMPONENTS
class LiquidPanel: NSPanel {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        self.isOpaque = false; self.backgroundColor = .clear; self.titlebarAppearsTransparent = true; self.titleVisibility = .hidden
    }
}

class LiquidView: NSView {
    var onDrop: ((URL) -> Void)?
    private var tintLayer: CALayer? // REFERENCE TO LAYER
    
    override init(frame: NSRect) { super.init(frame: frame); setupGlass(); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    
    func setupGlass() {
        self.wantsLayer = true; self.layer?.cornerRadius = 24; self.layer?.masksToBounds = true; self.layer?.borderWidth = 0
        
        // TINT LAYER with Reference
        let t = CALayer()
        t.frame = bounds
        t.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        layer?.addSublayer(t)
        tintLayer = t // Store it
        
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glassView = glassClass.init(frame: bounds); glassView.autoresizingMask = [.width, .height]; glassView.setValue(24.0, forKey: "cornerRadius"); glassView.setValue(1, forKey: "style"); addSubview(glassView, positioned: .below, relativeTo: nil); return
        }
        let v = NSVisualEffectView(frame: bounds); v.autoresizingMask = [.width, .height]; v.material = .underWindowBackground; v.blendingMode = .behindWindow; v.state = .active; addSubview(v, positioned: .below, relativeTo: nil)
    }
    
    // THE FIX: RESIZE TINT LAYER ON LAYOUT CHANGE
    override func layout() {
        super.layout()
        tintLayer?.frame = bounds
    }
    
    // DRAG
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { return .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { guard let item = sender.draggingPasteboard.pasteboardItems?.first, let str = item.string(forType: .fileURL), let url = URL(string: str) else { return false }; onDrop?(url); return true }
}

// MARK: - MAIN CONTROLLER
class LiquidMenuController: NSViewController {
    weak var appDelegate: AppDelegate?
    
    var thumbnailView: NSImageView!
    var trackTitle: NSTextField!
    var favButton: NSButton!
    var pinButton: NSButton!
    var progressSlider: NSSlider!
    
    var playButton: NSButton!
    var shuffleBtn: NSButton!
    var loopBtn: NSButton!
    var favOnlyBtn: NSButton!
    
    var volButton: NSButton!
    var volSlider: NSSlider!
    
    var timerSlider: NSSlider!
    var timerLabel: NSTextField!
    var scalingSeg: NSSegmentedControl!
    var statsLabel: NSTextField!
    
    var smartPauseToggle: NSButton!
    var batterySaverToggle: NSButton!
    var focusPauseToggle: NSButton!
    var focusMuteToggle: NSButton!
    var hideIconsToggle: NSButton!
    var allSpacesToggle: NSButton!
    var loginToggle: NSButton!
    
    override func loadView() {
        // WIDTH 320 to fit Footer
        let v = LiquidView(frame: NSRect(x: 0, y: 0, width: 320, height: 620))
        v.onDrop = { [weak self] url in self?.appDelegate?.handleDroppedFile(url: url) }
        self.view = v; setupUI(in: v)
    }
    
    func setupUI(in view: NSView) {
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14)])
        
        // 1. HEADER
        let header = NSStackView(); header.alignment = .centerY; header.spacing = 8
        let appIcon = NSImageView(); appIcon.image = NSImage(named: "menubar_icon"); appIcon.contentTintColor = .white; appIcon.imageScaling = .scaleProportionallyUpOrDown; appIcon.translatesAutoresizingMaskIntoConstraints = false; appIcon.widthAnchor.constraint(equalToConstant: 50).isActive = true; appIcon.heightAnchor.constraint(equalToConstant: 50).isActive = true
        let logo = NSTextField(labelWithString: "CineWall"); logo.font = NSFont.systemFont(ofSize: 22, weight: .heavy); logo.textColor = .white
        pinButton = createIconBtn("pin", size: 14, action: #selector(togglePin)); pinButton.toolTip = "Pin Menu"; pinButton.contentTintColor = .white.withAlphaComponent(0.6)
        statsLabel = NSTextField(labelWithString: "-"); statsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium); statsLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        header.addArrangedSubview(appIcon); header.addArrangedSubview(logo); header.addArrangedSubview(NSView()); header.addArrangedSubview(statsLabel); header.addArrangedSubview(pinButton)
        stack.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        
        // 2. PLAYER
        let playerCard = createCard(height: 110)
        thumbnailView = NSImageView(); thumbnailView.wantsLayer = true; thumbnailView.layer?.cornerRadius = 8; thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.contentsGravity = .resizeAspectFill; thumbnailView.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil); thumbnailView.translatesAutoresizingMaskIntoConstraints = false; playerCard.addSubview(thumbnailView)
        let thumbMenu = NSMenu(); thumbMenu.addItem(NSMenuItem(title: "Reveal in Finder", action: #selector(revealFile), keyEquivalent: "")); thumbnailView.menu = thumbMenu
        let infoCol = NSStackView(); infoCol.orientation = .vertical; infoCol.alignment = .leading; infoCol.spacing = 4; infoCol.translatesAutoresizingMaskIntoConstraints = false; playerCard.addSubview(infoCol)
        let titleRow = NSStackView(); trackTitle = NSTextField(labelWithString: "Not Playing"); trackTitle.font = NSFont.systemFont(ofSize: 13, weight: .bold); trackTitle.textColor = .white; trackTitle.cell?.lineBreakMode = .byTruncatingTail; trackTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        favButton = createIconBtn("heart", size: 14, action: #selector(toggleFav)); favButton.contentTintColor = .white; favButton.toolTip = "Add to Favorites"
        titleRow.addArrangedSubview(trackTitle); titleRow.addArrangedSubview(favButton); infoCol.addArrangedSubview(titleRow); titleRow.widthAnchor.constraint(equalTo: infoCol.widthAnchor).isActive = true
        progressSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(seekVideo)); progressSlider.controlSize = .mini; progressSlider.toolTip = "Seek Video"; infoCol.addArrangedSubview(progressSlider); progressSlider.widthAnchor.constraint(equalTo: infoCol.widthAnchor).isActive = true
        let controlsRow = NSStackView(); controlsRow.spacing = 12
        let prev = createIconBtn("backward.fill", size: 14, action: #selector(doPrev)); prev.toolTip = "Previous"
        playButton = createIconBtn("play.fill", size: 18, action: #selector(togglePlay)); playButton.toolTip = "Play/Pause"
        let next = createIconBtn("forward.fill", size: 14, action: #selector(doNext)); next.toolTip = "Next"
        controlsRow.addArrangedSubview(prev); controlsRow.addArrangedSubview(playButton); controlsRow.addArrangedSubview(next); infoCol.addArrangedSubview(controlsRow)
        let volRow = NSStackView(); volRow.spacing = 4
        volButton = createIconBtn("speaker.wave.2.fill", size: 12, action: #selector(toggleMute)); volButton.toolTip = "Mute"
        volSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: self, action: #selector(volumeChanged)); volSlider.controlSize = .mini; volSlider.toolTip = "Volume"
        volRow.addArrangedSubview(volButton); volRow.addArrangedSubview(volSlider); infoCol.addArrangedSubview(volRow); volRow.widthAnchor.constraint(equalTo: infoCol.widthAnchor).isActive = true
        NSLayoutConstraint.activate([thumbnailView.leadingAnchor.constraint(equalTo: playerCard.leadingAnchor, constant: 8), thumbnailView.topAnchor.constraint(equalTo: playerCard.topAnchor, constant: 8), thumbnailView.bottomAnchor.constraint(equalTo: playerCard.bottomAnchor, constant: -8), thumbnailView.widthAnchor.constraint(equalTo: thumbnailView.heightAnchor, multiplier: 1.4), infoCol.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 10), infoCol.centerYAnchor.constraint(equalTo: playerCard.centerYAnchor), infoCol.trailingAnchor.constraint(equalTo: playerCard.trailingAnchor, constant: -8)])
        stack.addArrangedSubview(playerCard)
        
        // 3. TOOLS
        let toolCard = createCard(height: 58); let toolStack = NSStackView(); toolStack.distribution = .fillEqually; toolStack.spacing = 8; toolCard.addSubview(toolStack); constrainToCard(view: toolStack, card: toolCard)
        shuffleBtn = createLiquidBtn("Shuffle", icon: "shuffle", action: #selector(toggleShuffle)); shuffleBtn.toolTip = "Random Order"
        loopBtn = createLiquidBtn("Loop", icon: "repeat", action: #selector(toggleLoop)); loopBtn.toolTip = "Repeat Video"
        favOnlyBtn = createLiquidBtn("Favs", icon: "heart.fill", action: #selector(toggleFavOnly)); favOnlyBtn.toolTip = "Play Favorites Only"
        toolStack.addArrangedSubview(shuffleBtn); toolStack.addArrangedSubview(loopBtn); toolStack.addArrangedSubview(favOnlyBtn); stack.addArrangedSubview(toolCard)
        
        // 4. DISPLAY
        let displayCard = createCard(height: 70); let displayStack = NSStackView(); displayStack.orientation = .vertical; displayStack.spacing = 6; displayCard.addSubview(displayStack); constrainToCard(view: displayStack, card: displayCard)
        let timerRow = NSStackView(); timerLabel = NSTextField(labelWithString: "Timer: Off"); timerLabel.font = NSFont.systemFont(ofSize: 10); timerLabel.textColor = .white; timerSlider = NSSlider(value: 0, minValue: 0, maxValue: 60, target: self, action: #selector(timerChanged)); timerSlider.controlSize = .mini; timerSlider.toolTip = "Auto Change"
        timerRow.addArrangedSubview(timerLabel); timerRow.addArrangedSubview(timerSlider); displayStack.addArrangedSubview(timerRow); timerRow.widthAnchor.constraint(equalTo: displayStack.widthAnchor).isActive = true
        scalingSeg = NSSegmentedControl(labels: ["Fill", "Fit", "Stretch"], trackingMode: .selectOne, target: self, action: #selector(scaleChanged)); scalingSeg.controlSize = .small; scalingSeg.toolTip = "Scaling"
        displayStack.addArrangedSubview(scalingSeg); scalingSeg.widthAnchor.constraint(equalTo: displayStack.widthAnchor).isActive = true; stack.addArrangedSubview(displayCard)
        
        // 5. FILES
        let fileCard = createCard(height: 40); let fileStack = NSStackView(); fileStack.distribution = .fillEqually; fileCard.addSubview(fileStack); constrainToCard(view: fileStack, card: fileCard)
        let f1 = createBtn("Folder", action: #selector(pickFolder)); f1.toolTip = "Select Folder"; fileStack.addArrangedSubview(f1)
        let f2 = createBtn("File", action: #selector(pickFile)); f2.toolTip = "Select File"; fileStack.addArrangedSubview(f2)
        let f3 = createBtn("List", action: #selector(showList)); f3.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil); f3.toolTip = "Favorites List"; fileStack.addArrangedSubview(f3)
        stack.addArrangedSubview(fileCard)
        
        // 6. SETTINGS
        let setCard = createCard(height: 185); let setStack = NSStackView(); setStack.orientation = .vertical; setStack.alignment = .leading; setStack.spacing = 6; setCard.addSubview(setStack); constrainToCard(view: setStack, card: setCard)
        smartPauseToggle = createCheck("Smart Pause", action: #selector(togSmart)); smartPauseToggle.toolTip = "Pause when obscured"
        batterySaverToggle = createCheck("Pause on Battery Power", action: #selector(togBattery)); batterySaverToggle.toolTip = "Pause when unplugged"
        focusPauseToggle = createCheck("Pause on App Focus", action: #selector(togFocusP)); focusPauseToggle.toolTip = "Pause when busy"
        focusMuteToggle = createCheck("Mute on App Focus", action: #selector(togFocusM)); hideIconsToggle = createCheck("Hide Desktop Icons", action: #selector(togIcons)); allSpacesToggle = createCheck("Show on All Spaces", action: #selector(togSpaces)); loginToggle = createCheck("Start at Login", action: #selector(togLogin))
        [smartPauseToggle, batterySaverToggle, focusPauseToggle, focusMuteToggle, hideIconsToggle, allSpacesToggle, loginToggle].forEach { setStack.addArrangedSubview($0!) }
        stack.addArrangedSubview(setCard)
        
        // 7. FOOTER
        let foot = NSStackView(); foot.distribution = .fillEqually
        let b1 = createBtn("Bring to Desktop", action: #selector(doBring)); b1.toolTip = "Move to this Space"
        let b2 = createBtn("", action: #selector(showAbout)); b2.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil); b2.toolTip = "About"
        let b3 = createBtn("Quit", action: #selector(doQuit)); b3.toolTip = "Exit"
        foot.addArrangedSubview(b1); foot.addArrangedSubview(b2); foot.addArrangedSubview(b3)
        stack.addArrangedSubview(foot)
    }
    
    func updateTrackInfo(title: String, image: NSImage?, isFav: Bool) { trackTitle.stringValue = title; thumbnailView.image = image ?? NSImage(systemSymbolName: "film", accessibilityDescription: nil); updateFavIcon(isFav) }
    func updateFavIcon(_ isFav: Bool) { favButton.image = NSImage(systemSymbolName: isFav ? "heart.fill" : "heart", accessibilityDescription: nil); favButton.contentTintColor = isFav ? .systemRed : .white }
    func refreshUI() {
        guard let app = appDelegate else { return }
        playButton.image = NSImage(systemSymbolName: app.isManualPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        let vol = app.volumeLevel
        let iconName = (app.isMuted || vol == 0) ? "speaker.slash.fill" : (vol < 0.3 ? "speaker.wave.1.fill" : (vol < 0.7 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
        volButton.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil); volSlider.floatValue = vol
        updateLiquidBtn(shuffleBtn, active: app.isShuffle); updateLiquidBtn(loopBtn, active: app.isLoopingCurrent); updateLiquidBtn(favOnlyBtn, active: app.isFavoritesOnly)
        pinButton.image = NSImage(systemSymbolName: app.isPinned ? "pin.fill" : "pin", accessibilityDescription: nil); pinButton.contentTintColor = app.isPinned ? .systemBlue : .white.withAlphaComponent(0.6)
        scalingSeg.selectedSegment = app.scalingTag - 1; let m = Int(app.autoChangeInterval / 60); timerSlider.doubleValue = Double(m); timerLabel.stringValue = (m == 0) ? "Timer: Off" : "Timer: \(m) min"
        smartPauseToggle.state = app.smartPauseEnabled ? .on : .off; batterySaverToggle.state = app.batterySaverEnabled ? .on : .off; focusPauseToggle.state = app.focusPauseEnabled ? .on : .off; focusMuteToggle.state = app.focusMuteEnabled ? .on : .off; hideIconsToggle.state = app.hideDesktopIcons ? .on : .off; allSpacesToggle.state = app.showOnAllSpaces ? .on : .off; loginToggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }
    func updateStats() { guard let app = appDelegate else { return }; statsLabel.stringValue = "CPU: \(String(format: "%.1f", app.getAppCPU()))% | RAM: \(app.getAppRAM())" }

    @objc func togglePlay() { appDelegate?.isManualPaused.toggle(); appDelegate?.saveSettings(); appDelegate?.updatePlaybackState() }
    @objc func togglePin() { appDelegate?.togglePin(); refreshUI() }
    @objc func doNext() { appDelegate?.nextFile() }
    @objc func doPrev() { appDelegate?.prevFile() }
    @objc func seekVideo() { appDelegate?.seekTo(percentage: progressSlider.doubleValue) }
    @objc func toggleFav() { appDelegate?.toggleFavorite() }
    @objc func toggleFavOnly() { appDelegate?.isFavoritesOnly.toggle(); appDelegate?.saveSettings(); appDelegate?.refreshQueue(); appDelegate?.startPlayback() }
    @objc func volumeChanged() { appDelegate?.volumeLevel = volSlider.floatValue; appDelegate?.isMuted = (volSlider.floatValue == 0); appDelegate?.saveSettings(); appDelegate?.updatePlaybackState(); refreshUI() }
    @objc func toggleMute() { appDelegate?.toggleMuteState() }
    @objc func toggleShuffle() { appDelegate?.isShuffle.toggle(); appDelegate?.saveSettings(); appDelegate?.refreshQueue(); refreshUI() }
    @objc func toggleLoop() { appDelegate?.isLoopingCurrent.toggle(); appDelegate?.saveSettings(); appDelegate?.resetPlaylistTimer(); refreshUI() }
    @objc func pickFolder() { appDelegate?.selectFolder() }
    @objc func pickFile() { appDelegate?.selectSingleVideo() }
    @objc func showList() { appDelegate?.showFavoritesWindow() }
    @objc func doBring() { appDelegate?.bringToCurrentDesktop() }
    @objc func doQuit() { appDelegate?.terminateApp() }
    @objc func revealFile() { appDelegate?.revealCurrentInFinder() }
    @objc func showAbout() { let alert = NSAlert(); alert.messageText = "CineWall"; alert.informativeText = "Version 1.0\n\nThe ultimate video wallpaper utility for macOS.\n\n© 2026"; alert.icon = NSImage(named: "AppIcon"); alert.runModal() }
    @objc func timerChanged() { let v = Int(timerSlider.doubleValue); appDelegate?.autoChangeInterval = Double(v * 60); timerLabel.stringValue = (v == 0) ? "Timer: Off" : "Timer: \(v) min"; if let e = NSApp.currentEvent, e.type == .leftMouseUp { appDelegate?.saveSettings(); appDelegate?.resetPlaylistTimer() } }
    @objc func scaleChanged() { appDelegate?.scalingTag = scalingSeg.selectedSegment + 1; appDelegate?.saveSettings(); appDelegate?.updateScalingMode() }
    @objc func togSmart() { appDelegate?.smartPauseEnabled.toggle(); saveUp() }
    @objc func togBattery() { appDelegate?.batterySaverEnabled.toggle(); saveUp() }
    @objc func togFocusP() { appDelegate?.focusPauseEnabled.toggle(); saveUp() }
    @objc func togFocusM() { appDelegate?.focusMuteEnabled.toggle(); saveUp() }
    @objc func togIcons() { appDelegate?.hideDesktopIcons.toggle(); appDelegate?.applyWindowLevel(); saveUp() }
    @objc func togSpaces() { appDelegate?.showOnAllSpaces.toggle(); appDelegate?.saveSettings(); appDelegate?.wallpaperWindow?.collectionBehavior = (appDelegate?.showOnAllSpaces ?? false) ? [.canJoinAllSpaces, .stationary, .ignoresCycle] : [.stationary, .ignoresCycle]; appDelegate?.updatePlaybackState() }
    @objc func togLogin() { let s = SMAppService.mainApp; try? (s.status == .enabled ? s.unregister() : s.register()); loginToggle.state = (s.status == .enabled) ? .on : .off }
    func saveUp() { appDelegate?.saveSettings(); appDelegate?.updatePlaybackState(); refreshUI() }

    func createCard(height: CGFloat) -> NSView { let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor; v.layer?.cornerRadius = 10; v.translatesAutoresizingMaskIntoConstraints = false; v.heightAnchor.constraint(equalToConstant: height).isActive = true; return v }
    func constrainToCard(view: NSView, card: NSView) { view.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([view.topAnchor.constraint(equalTo: card.topAnchor, constant: 8), view.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8), view.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10), view.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10)]) }
    func createIconBtn(_ icon: String, size: CGFloat, action: Selector) -> NSButton { let b = NSButton(); b.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil); b.bezelStyle = .regularSquare; b.isBordered = false; b.target = self; b.action = action; b.translatesAutoresizingMaskIntoConstraints = false; return b }
    func createBtn(_ title: String, action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; b.controlSize = .small; return b }
    func createCheck(_ title: String, action: Selector) -> NSButton { let b = NSButton(checkboxWithTitle: title, target: self, action: action); b.contentTintColor = .white; b.font = NSFont.systemFont(ofSize: 12); return b }
    func createLiquidBtn(_ title: String, icon: String, action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); b.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil); b.imagePosition = .imageLeading; b.imageHugsTitle = true; b.bezelStyle = .regularSquare; b.isBordered = false; b.wantsLayer = true; b.layer?.cornerRadius = 8; b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor; b.font = NSFont.systemFont(ofSize: 12, weight: .semibold); b.translatesAutoresizingMaskIntoConstraints = false; b.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true; return b }
    func updateLiquidBtn(_ btn: NSButton, active: Bool) { if active { btn.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.30).cgColor; btn.contentTintColor = NSColor.white } else { btn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor; btn.contentTintColor = NSColor.white.withAlphaComponent(0.8) } }
}

class FavoritesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var appDelegate: AppDelegate?
    var tableView: NSTableView!
    override func loadView() {
        let v = LiquidView(frame: NSRect(x: 0, y: 0, width: 280, height: 400)); self.view = v
        let title = NSTextField(labelWithString: "Favorites"); title.font = NSFont.systemFont(ofSize: 16, weight: .bold); title.textColor = .white; title.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(title)
        let sub = NSTextField(labelWithString: "Double-click to Play • Right-click to Remove"); sub.font = NSFont.systemFont(ofSize: 10); sub.textColor = NSColor.white.withAlphaComponent(0.6); sub.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(sub)
        let sv = NSScrollView(); sv.drawsBackground = false; sv.hasVerticalScroller = true; sv.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(sv)
        tableView = NSTableView(); tableView.backgroundColor = .clear; tableView.headerView = nil; tableView.dataSource = self; tableView.delegate = self; tableView.doubleAction = #selector(itemDoubleClicked); let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name")); tableView.addTableColumn(col); sv.documentView = tableView
        let menu = NSMenu(); menu.addItem(NSMenuItem(title: "Play", action: #selector(itemDoubleClicked), keyEquivalent: "")); menu.addItem(NSMenuItem(title: "Remove", action: #selector(deleteItem), keyEquivalent: "")); tableView.menu = menu
        NSLayoutConstraint.activate([title.topAnchor.constraint(equalTo: v.topAnchor, constant: 16), title.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16), sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4), sub.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16), sv.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 10), sv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12), sv.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12), sv.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -16)])
    }
    func reloadData() { tableView.reloadData() }
    func numberOfRows(in tableView: NSTableView) -> Int { return appDelegate?.favorites.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let path = appDelegate?.favorites[row] else { return nil }; let cell = NSTableCellView(); let tf = NSTextField(labelWithString: URL(fileURLWithPath: path).lastPathComponent); tf.textColor = .white; tf.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(tf); tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true; tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true; return cell
    }
    @objc func itemDoubleClicked() { guard tableView.clickedRow >= 0 else { return }; appDelegate?.playFavorite(at: tableView.clickedRow) }
    @objc func deleteItem() { guard tableView.clickedRow >= 0, let path = appDelegate?.favorites[tableView.clickedRow] else { return }; appDelegate?.removeFavorite(path: path) }
}
