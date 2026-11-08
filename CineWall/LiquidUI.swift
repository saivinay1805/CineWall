import Cocoa
import QuartzCore
import ServiceManagement

// MARK: - Vorssaint Liquid Spring Motion Engine
public enum VorssaintMotion {
    public static let departureHidden: TimeInterval = 0.2

    public struct Spring: Equatable {
        public var duration: TimeInterval
        public var bounce: Double

        public init(duration: TimeInterval, bounce: Double) {
            self.duration = duration
            self.bounce = bounce
        }

        /// Progress from rest at 0 toward 1
        public func progress(at time: TimeInterval) -> Double {
            guard time > 0 else { return 0 }
            guard duration > 0 else { return 1 }
            let natural = 2 * Double.pi / duration
            let damping = max(0.001, 1 - bounce)
            if damping >= 1 {
                return 1 - exp(-natural * time) * (1 + natural * time)
            }
            let damped = natural * (1 - damping * damping).squareRoot()
            return 1 - exp(-damping * natural * time)
                * (cos(damped * time) + damping * natural / damped * sin(damped * time))
        }

        public var overshoot: Double {
            guard bounce > 0 else { return 0 }
            let damping = max(0.001, 1 - bounce)
            return exp(-Double.pi * damping / (1 - damping * damping).squareRoot())
        }

        public func limited(travel: CGFloat, limit: CGFloat) -> Spring {
            guard bounce > 0, travel > 0, Double(travel) * overshoot > Double(limit) else { return self }
            let share = log(Double(max(limit, 0.01) / travel))
            return Spring(duration: duration, bounce: 1 + share / (Double.pi * Double.pi + share * share).squareRoot())
        }
    }

    public static let growingWidth = Spring(duration: 0.44, bounce: 0.25)
    public static let growingHeight = Spring(duration: 0.38, bounce: 0.22)
    public static let shrinkingWidth = Spring(duration: 0.30, bounce: 0)
    public static let shrinkingHeight = Spring(duration: 0.26, bounce: 0)

    public static let cardExpandSpring = Spring(duration: 0.38, bounce: 0.22)
    public static let cardCollapseSpring = Spring(duration: 0.26, bounce: 0)

    public static let codenotchUnfold = Spring(duration: 0.44, bounce: 0.16)
    public static let codenotchFold = Spring(duration: 0.34, bounce: 0.08)

    public static let overshootLimit: CGFloat = 12
    public static let settledDistance: CGFloat = 0.5

    public static func interpolateRectUnified(from start: NSRect, to end: NSRect, progress: Double) -> NSRect {
        let p = CGFloat(progress)
        let x = start.origin.x + (end.origin.x - start.origin.x) * p
        let y = start.origin.y + (end.origin.y - start.origin.y) * p
        let w = start.size.width + (end.size.width - start.size.width) * p
        let h = start.size.height + (end.size.height - start.size.height) * p
        return NSRect(x: x, y: y, width: max(10, w), height: max(10, h))
    }

    public static func settlingTime(spring: Spring) -> TimeInterval {
        return spring.duration * 1.15
    }

    public static func spring(from: CGFloat, to: CGFloat, isWidth: Bool) -> Spring {
        let base = to > from ? (isWidth ? growingWidth : growingHeight) : (isWidth ? shrinkingWidth : shrinkingHeight)
        return base.limited(travel: abs(to - from), limit: overshootLimit)
    }

    public static func interpolate(from start: CGFloat, to end: CGFloat, isWidth: Bool, time: TimeInterval) -> CGFloat {
        guard start != end else { return end }
        let s = spring(from: start, to: end, isWidth: isWidth)
        let p = s.progress(at: time)
        return start + (end - start) * CGFloat(p)
    }

    public static func interpolateRect(from start: NSRect, to end: NSRect, time: TimeInterval) -> NSRect {
        let p = codenotchUnfold.progress(at: time)
        return interpolateRectUnified(from: start, to: end, progress: p)
    }

    public static func settlingTime(from start: NSRect, to end: NSRect) -> TimeInterval {
        return codenotchUnfold.duration * 1.15
    }
}

// MARK: - Player Thumbnail View
final class PlayerThumbnailView: NSView {
    var thumbnailImage: NSImage? {
        didSet {
            layer?.contents = thumbnailImage
            needsDisplay = true
        }
    }

    var showsGradient: Bool = true {
        didSet {
            gradientOverlay.isHidden = !showsGradient
        }
    }

    var onClick: (() -> Void)?

    private let gradientOverlay = CAGradientLayer()

    init(frame: NSRect = .zero, cornerRadius: CGFloat = 16, showsGradient: Bool = true) {
        self.showsGradient = showsGradient
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.contentsGravity = .resizeAspectFill

        gradientOverlay.colors = [
            NSColor.black.withAlphaComponent(0.40).cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.45).cgColor
        ]
        gradientOverlay.locations = [0.0, 0.45, 1.0]
        gradientOverlay.isHidden = !showsGradient
        layer?.addSublayer(gradientOverlay)
    }

    override convenience init(frame: NSRect) {
        self.init(frame: frame, cornerRadius: 16, showsGradient: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if let onClick {
            onClick()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func layout() {
        super.layout()
        gradientOverlay.frame = bounds
        if let img = thumbnailImage {
            layer?.contents = img
        }
    }

    override func updateLayer() {
        super.updateLayer()
        if let img = thumbnailImage {
            layer?.contents = img
        }
    }
}

// MARK: - MAIN CONTROLLER
final class LiquidMenuController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum DetailSection {
        case app
        case player
        case playlist
        case display
        case library
        case settings
        case pro

        var title: String {
            switch self {
            case .app: return "CineWall"
            case .player: return "Now Playing"
            case .playlist: return "Playlists"
            case .display: return "Display"
            case .library: return "Library"
            case .settings: return "Settings"
            case .pro: return "About CineWall"
            }
        }

        var subtitle: String {
            switch self {
            case .app: return "App info, updates, and startup behavior."
            case .player: return "Expanded transport controls and scrubber."
            case .playlist: return "Choose the active playlist."
            case .display: return "Wallpaper fit, timer, and screen behavior"
            case .library: return "Manage playlists and add media in bulk."
            case .settings: return "Playback rules, power behavior, and lock screen."
            case .pro: return "v3.0 Tahoe Edition • Free & Open Source"
            }
        }
    }

    weak var appDelegate: AppDelegate?

    var thumbnailView: PlayerThumbnailView!
    private var currentTrackThumbnail: NSImage?
    var trackTitle: NSTextField!
    var compactTrackMarquee: MarqueeLabelView!
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
    var timerHoursField: NSTextField!
    var timerMinutesField: NSTextField!
    var timerSecondsField: NSTextField!
    var scalingSeg: NSSegmentedControl!
    private var cpuLabel: NSTextField!
    private var ramLabel: NSTextField!
    var smartPauseToggle: NSButton!
    var batterySaverToggle: NSButton!
    var focusPauseToggle: NSButton!
    var focusMuteToggle: NSButton!
    var hideIconsToggle: NSButton!
    var allSpacesToggle: NSButton!
    var loginToggle: NSButton!
    var autoIdleSyncToggle: NSButton!
    var idleSyncButton: NSButton!
    var restoreWallpaperButton: NSButton!
    var restoreOnQuitToggle: NSButton!
    var idleSyncStatusLabel: NSTextField!
    var menuTintSlider: NSSlider!
    var menuTintValueLabel: NSTextField!
    var ambientGlowToggle: NSButton!
    var spanDisplaysToggle: NSButton?
    private var updatesStatusLabel: NSTextField!
    private var appVersionLabel: NSTextField!
    private var appStatusLabel: NSTextField!
    private var appHeaderSubtitleLabel: NSTextField!

    var mainStack: NSStackView!
    private var playerCardView: LiquidGlassCardView!
    private var playlistCard: LiquidGlassCardView!
    private var displayCard: LiquidGlassCardView!
    private var libraryCard: LiquidGlassCardView!
    private var settingsCard: LiquidGlassCardView!
    private var appHeaderCard: LiquidGlassCardView!
    private var displaySummaryLabel: NSTextField!
    private var librarySummaryLabel: NSTextField!
    private var settingsSummaryLabel: NSTextField!
    private var playlistSummaryLabel: NSTextField!
    private var playlistToggleButton: NSButton!

    private var detailOverlay: NSView!
    private var detailCard: DismissibleDetailCardView!
    private var detailHeaderView: NSView!
    private var detailTitleLabel: NSTextField!
    private var detailSubtitleLabel: NSTextField!
    private var detailBodyHost: NSView!
    private var activeDetail: DetailSection?
    private var detailSourceFrame: NSRect = .zero
    private var detailAnimationTimer: Timer?
    private var mainStackLeadingConstraint: NSLayoutConstraint?
    private var bodyTopToHeaderConstraint: NSLayoutConstraint!
    private var bodyTopToCardConstraint: NSLayoutConstraint!
    private var detailWidth: CGFloat { max(280, view.bounds.width - 16) }

    private var appDetailView: NSView!
    private var displayDetailView: NSView!
    private var playerDetailView: NSView!
    private var playlistDetailView: NSView!
    private var libraryDetailView: NSView!
    private var settingsDetailView: NSView!
    private var proDetailView: NSView!
    private var playlistTableView: NSTableView!
    private var libraryPlaylistTableView: NSTableView!
    private var playlistItemsTableView: NSTableView!
    private var playlistSelectionHintLabel: NSTextField!
    private var libraryPlaylistNameLabel: NSTextField!
    private var libraryPlaylistHintLabel: NSTextField!
    private var libraryVideosTitleLabel: NSTextField!
    private var libraryCreatePlaylistRow: NSStackView!
    private var libraryCreatePlaylistField: NSTextField!
    private var librarySelectVideosButton: NSButton!
    private var libraryRemoveSelectedButton: NSButton!
    private var isSelectingPlaylistVideos: Bool = false
    private var expandedArtworkView: PlayerThumbnailView!
    private var expandedTrackTitle: NSTextField!
    private var expandedTrackSubtitle: NSTextField!
    private var expandedPlayButton: NSButton!
    private var expandedFavButton: NSButton!
    private var expandedMoreButton: NSButton!
    private var addToPlaylistButton: NSButton!
    private var proFooterButton: NSButton!
    private var proFooterCardView: LiquidGlassCardView!
    private var proStatusLabel: NSTextField!
    private var proDescriptionLabel: NSTextField!
    private var proTrialButton: NSButton!
    private var proPasteButton: NSButton!
    private var proActivateButton: NSButton!
    private var proLicenseField: NSTextField!
    private var proFeatureFocusLabel: NSTextField!
    private var proDeveloperButton: NSButton?
    private var proResetDebugButton: NSButton?
    private var lockScreenEnabledToggle: NSButton!
    var playerElapsedLabel: NSTextField!
    var playerRemainingLabel: NSTextField!

    override func loadView() {
        let root = LiquidView(frame: NSRect(x: 0, y: 0, width: liquidMenuWidth, height: liquidMenuHeight))
        root.onDrop = { [weak self] url in
            self?.appDelegate?.handleDroppedFile(url: url)
        }
        view = root
        setupUI(in: root)
    }

    func setMenuVisible(_ visible: Bool) {
        compactTrackMarquee?.setMenuVisible(visible)
    }

    func setupUI(in root: NSView) {
        mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 14
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            mainStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            mainStack.widthAnchor.constraint(equalToConstant: 282),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16)
        ])

        buildHeader()
        buildPlayerCard()
        buildSoundCard()
        buildSummaryCards()
        buildFooter()
        buildDetailOverlay(in: root)
        applyMenuTintStrength(CGFloat(appDelegate?.menuDarkTintStrength ?? 0.0))
    }

    private func buildHeader() {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: 282).isActive = true
        header.heightAnchor.constraint(equalToConstant: 60).isActive = true

        // Row 1: Left 208 x 60 Stadium Capsule for CineWall branding & stats
        let appChip = LiquidGlassCardView(cornerRadius: 30, tintAlpha: 0.025)
        appChip.configureNeutralGlass(tintAlpha: 0.05, glowOpacity: 0.0, refractionOpacity: 0.10)
        appChip.translatesAutoresizingMaskIntoConstraints = false
        appChip.heightAnchor.constraint(equalToConstant: 60).isActive = true
        appChip.widthAnchor.constraint(equalToConstant: 208).isActive = true
        appHeaderCard = appChip

        let iconView = NSImageView()
        iconView.image = NSImage(named: "menubar_icon")
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 38).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let logo = NSTextField.liquidLabel("CineWall", size: 14.5, weight: .bold)
        logo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        logo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        logo.lineBreakMode = .byTruncatingTail

        appHeaderSubtitleLabel = NSTextField.liquidLabel("CPU 0.0% • RAM 55 MB", size: 9.5, weight: .medium, color: .white.withAlphaComponent(0.70))
        appHeaderSubtitleLabel.lineBreakMode = .byTruncatingTail
        appHeaderSubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        appHeaderSubtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [logo, appHeaderSubtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1.5
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let textRow = NSStackView(views: [iconView, textStack])
        textRow.orientation = .horizontal
        textRow.alignment = .centerY
        textRow.spacing = 10
        textRow.translatesAutoresizingMaskIntoConstraints = false

        appChip.contentView.addSubview(textRow)

        let appChipButton = NSButton(title: "", target: self, action: #selector(showAppDetail(_:)))
        appChipButton.isBordered = false
        appChipButton.title = ""
        appChipButton.isTransparent = true
        appChipButton.translatesAutoresizingMaskIntoConstraints = false
        appChipButton.toolTip = "About CineWall"
        appChip.contentView.addSubview(appChipButton)

        // Row 1: Right 60 x 60 Circle Pill for Pin button
        let pinCard = LiquidGlassCardView(cornerRadius: 30, tintAlpha: 0.025)
        pinCard.configureNeutralGlass(tintAlpha: 0.05, glowOpacity: 0.0, refractionOpacity: 0.10)
        pinCard.translatesAutoresizingMaskIntoConstraints = false
        pinCard.heightAnchor.constraint(equalToConstant: 60).isActive = true
        pinCard.widthAnchor.constraint(equalToConstant: 60).isActive = true

        pinButton = NSButton.liquidSymbol(symbol: "pin", pointSize: 16, target: self, action: #selector(togglePin))
        pinButton.contentTintColor = .white.withAlphaComponent(0.75)
        pinButton.toolTip = "Pin Menu"
        pinCard.contentView.addSubview(pinButton)

        header.addArrangedSubview(appChip)
        header.addArrangedSubview(pinCard)

        NSLayoutConstraint.activate([
            textRow.leadingAnchor.constraint(equalTo: appChip.contentView.leadingAnchor, constant: 14),
            textRow.trailingAnchor.constraint(lessThanOrEqualTo: appChip.contentView.trailingAnchor, constant: -8),
            textRow.centerYAnchor.constraint(equalTo: appChip.contentView.centerYAnchor),

            appChipButton.leadingAnchor.constraint(equalTo: appChip.contentView.leadingAnchor),
            appChipButton.trailingAnchor.constraint(equalTo: appChip.contentView.trailingAnchor),
            appChipButton.topAnchor.constraint(equalTo: appChip.contentView.topAnchor),
            appChipButton.bottomAnchor.constraint(equalTo: appChip.contentView.bottomAnchor),

            pinButton.centerXAnchor.constraint(equalTo: pinCard.contentView.centerXAnchor),
            pinButton.centerYAnchor.constraint(equalTo: pinCard.contentView.centerYAnchor)
        ])

        mainStack.addArrangedSubview(header)
    }

    private func buildPlayerCard() {
        let playerCard = LiquidGlassCardView(cornerRadius: 24, tintAlpha: 0.025)
        playerCard.configureNeutralGlass(tintAlpha: 0.05, glowOpacity: 0.0, refractionOpacity: 0.10)
        playerCardView = playerCard
        playerCard.translatesAutoresizingMaskIntoConstraints = false
        playerCard.widthAnchor.constraint(equalToConstant: 134).isActive = true
        playerCard.heightAnchor.constraint(equalToConstant: 134).isActive = true

        thumbnailView = PlayerThumbnailView()
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        let thumbMenu = NSMenu()
        thumbMenu.addItem(NSMenuItem(title: "Reveal in Finder", action: #selector(revealFile), keyEquivalent: ""))
        thumbnailView.menu = thumbMenu

        trackTitle = NSTextField.liquidLabel("Not Playing", size: 12, weight: .semibold)
        trackTitle.isHidden = true
        compactTrackMarquee = MarqueeLabelView(font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                               color: .white.withAlphaComponent(0.96))
        compactTrackMarquee.stringValue = "Not Playing"

        favButton = NSButton.liquidSymbol(symbol: "heart", pointSize: 13, weight: .semibold, target: self, action: #selector(toggleFav))
        favButton.contentTintColor = .white
        favButton.toolTip = "Add to Favorites"
        favButton.translatesAutoresizingMaskIntoConstraints = false
        favButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        favButton.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let transportRow = NSStackView()
        transportRow.alignment = .centerY
        transportRow.spacing = 14
        transportRow.translatesAutoresizingMaskIntoConstraints = false

        let prev = NSButton.liquidSymbol(symbol: "backward.fill", pointSize: 12, weight: .semibold, target: self, action: #selector(doPrev))
        prev.toolTip = "Previous"
        prev.contentTintColor = .white
        prev.translatesAutoresizingMaskIntoConstraints = false
        prev.widthAnchor.constraint(equalToConstant: 24).isActive = true
        prev.heightAnchor.constraint(equalToConstant: 24).isActive = true

        playButton = NSButton.liquidSymbol(symbol: "play.fill", pointSize: 16, weight: .bold, target: self, action: #selector(togglePlay))
        playButton.toolTip = "Play/Pause"
        playButton.contentTintColor = .white
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        playButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let next = NSButton.liquidSymbol(symbol: "forward.fill", pointSize: 12, weight: .semibold, target: self, action: #selector(doNext))
        next.toolTip = "Next"
        next.contentTintColor = .white
        next.translatesAutoresizingMaskIntoConstraints = false
        next.widthAnchor.constraint(equalToConstant: 24).isActive = true
        next.heightAnchor.constraint(equalToConstant: 24).isActive = true

        transportRow.addArrangedSubview(prev)
        transportRow.addArrangedSubview(playButton)
        transportRow.addArrangedSubview(next)

        thumbnailView.onClick = { [weak self] in
            self?.showPlayerDetail(nil)
        }

        let openButton = NSButton(title: "", target: self, action: #selector(showPlayerDetail))
        openButton.isBordered = false
        openButton.isTransparent = true
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.menu = thumbMenu

        playerCard.contentView.addSubview(thumbnailView)
        playerCard.contentView.addSubview(compactTrackMarquee)
        playerCard.contentView.addSubview(openButton)
        playerCard.contentView.addSubview(favButton)
        playerCard.contentView.addSubview(transportRow)

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: playerCard.contentView.leadingAnchor, constant: 10),
            thumbnailView.trailingAnchor.constraint(equalTo: playerCard.contentView.trailingAnchor, constant: -10),
            thumbnailView.topAnchor.constraint(equalTo: playerCard.contentView.topAnchor, constant: 10),
            thumbnailView.bottomAnchor.constraint(equalTo: playerCard.contentView.bottomAnchor, constant: -10),

            compactTrackMarquee.topAnchor.constraint(equalTo: playerCard.contentView.topAnchor, constant: 14),
            compactTrackMarquee.leadingAnchor.constraint(equalTo: playerCard.contentView.leadingAnchor, constant: 16),
            compactTrackMarquee.trailingAnchor.constraint(equalTo: favButton.leadingAnchor, constant: -4),
            compactTrackMarquee.heightAnchor.constraint(equalToConstant: 18),

            favButton.topAnchor.constraint(equalTo: playerCard.contentView.topAnchor, constant: 12),
            favButton.trailingAnchor.constraint(equalTo: playerCard.contentView.trailingAnchor, constant: -14),

            openButton.topAnchor.constraint(equalTo: playerCard.contentView.topAnchor),
            openButton.bottomAnchor.constraint(equalTo: playerCard.contentView.bottomAnchor),
            openButton.leadingAnchor.constraint(equalTo: playerCard.contentView.leadingAnchor),
            openButton.trailingAnchor.constraint(equalTo: playerCard.contentView.trailingAnchor),

            transportRow.centerXAnchor.constraint(equalTo: playerCard.contentView.centerXAnchor),
            transportRow.bottomAnchor.constraint(equalTo: playerCard.contentView.bottomAnchor, constant: -12)
        ])

        var dummyVar: NSButton? = nil
        var dummyVar2: NSButton? = nil

        let shufView = createGlassAction(symbol: "shuffle", size: 18, baseRadius: 30, action: #selector(toggleShuffle), storeTo: &shuffleBtn)
        shufView.toolTip = "Toggle Shuffle"
        let loopView = createGlassAction(symbol: "repeat", size: 18, baseRadius: 30, action: #selector(toggleLoop), storeTo: &loopBtn)
        loopView.toolTip = "Toggle Loop"
        let topGrid = NSStackView(views: [shufView, loopView])
        topGrid.spacing = 14

        let filView = createGlassAction(symbol: "doc.fill", size: 18, baseRadius: 30, action: #selector(pickFile), storeTo: &dummyVar2)
        filView.toolTip = "Pick Video File"
        let folView = createGlassAction(symbol: "folder.fill", size: 18, baseRadius: 30, action: #selector(pickFolder), storeTo: &dummyVar)
        folView.toolTip = "Pick Video Folder"
        let botGrid = NSStackView(views: [filView, folView])
        botGrid.spacing = 14

        let actionsGrid = NSStackView(views: [topGrid, botGrid])
        actionsGrid.orientation = .vertical
        actionsGrid.spacing = 14
        actionsGrid.translatesAutoresizingMaskIntoConstraints = false
        actionsGrid.widthAnchor.constraint(equalToConstant: 134).isActive = true
        actionsGrid.heightAnchor.constraint(equalToConstant: 134).isActive = true

        let row = NSStackView(views: [playerCard, actionsGrid])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 282).isActive = true
        row.heightAnchor.constraint(equalToConstant: 134).isActive = true
        mainStack.addArrangedSubview(row)
    }

    private func createGlassAction(symbol: String, size: CGFloat, baseRadius: CGFloat, action: Selector, storeTo: inout NSButton?) -> NSView {
        let card = LiquidGlassCardView(cornerRadius: baseRadius, tintAlpha: 0.025)
        card.configureNeutralGlass(tintAlpha: 0.05, glowOpacity: 0.0, refractionOpacity: 0.10)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: baseRadius * 2).isActive = true
        card.heightAnchor.constraint(equalToConstant: baseRadius * 2).isActive = true
        
        let btn = NSButton.liquidSymbol(symbol: symbol, pointSize: size, target: self, action: action)
        btn.contentTintColor = .white
        btn.wantsLayer = true
        storeTo = btn
        
        card.contentView.addSubview(btn)
        constrainEdges(of: btn, to: card.contentView)
        return card
    }

    private func buildSoundCard() {
        let soundCard = LiquidGlassCardView(cornerRadius: 30, tintAlpha: 0.025)
        soundCard.configureNeutralGlass(tintAlpha: 0.05, glowOpacity: 0.0, refractionOpacity: 0.10)
        soundCard.translatesAutoresizingMaskIntoConstraints = false
        soundCard.heightAnchor.constraint(equalToConstant: 60).isActive = true
        soundCard.widthAnchor.constraint(equalToConstant: 282).isActive = true

        let soundLabel = NSTextField.liquidLabel("Sound", size: 13, weight: .semibold)
        volButton = NSButton.liquidSymbol(symbol: "speaker.wave.2.fill", pointSize: 14, weight: .medium, target: self, action: #selector(toggleMute))
        volButton.contentTintColor = .white
        volButton.toolTip = "Mute"
        volButton.translatesAutoresizingMaskIntoConstraints = false
        volButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        volButton.heightAnchor.constraint(equalToConstant: 22).isActive = true

        volSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: self, action: #selector(volumeChanged))
        volSlider.controlSize = .small
        volSlider.toolTip = "Volume"

        let row = NSStackView(views: [soundLabel, volButton, volSlider])
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        soundCard.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            row.centerYAnchor.constraint(equalTo: soundCard.contentView.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: soundCard.contentView.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: soundCard.contentView.trailingAnchor, constant: -14)
        ])

        mainStack.addArrangedSubview(soundCard)
    }

    private func buildSummaryCards() {
        let (dispCard, dispSub) = buildSideBySideCard(title: "Display", subtitle: "Fit • Timer off", icon: "display", iconColor: .white.withAlphaComponent(0.12), action: #selector(showDisplayDetail(_:)))
        displayCard = dispCard
        displaySummaryLabel = dispSub

        let (setCard, setSub) = buildSideBySideCard(title: "Settings", subtitle: "Smart • Lock", icon: "gearshape.fill", iconColor: .white.withAlphaComponent(0.12), action: #selector(showSettingsDetail(_:)))
        settingsCard = setCard
        settingsSummaryLabel = setSub

        let displaySettingsRow = NSStackView(views: [displayCard, settingsCard])
        displaySettingsRow.orientation = .horizontal
        displaySettingsRow.spacing = 14
        displaySettingsRow.translatesAutoresizingMaskIntoConstraints = false
        displaySettingsRow.widthAnchor.constraint(equalToConstant: 282).isActive = true
        displaySettingsRow.heightAnchor.constraint(equalToConstant: 60).isActive = true

        let playlistLibrarySummary = buildPlaylistLibraryCard()
        playlistCard = playlistLibrarySummary.card
        libraryCard = playlistLibrarySummary.card
        playlistSummaryLabel = playlistLibrarySummary.subtitleLabel
        librarySummaryLabel = playlistLibrarySummary.subtitleLabel
        playlistToggleButton = playlistLibrarySummary.toggleButton

        mainStack.addArrangedSubview(displaySettingsRow)
        mainStack.addArrangedSubview(playlistLibrarySummary.card)
    }

    private func buildPlaylistLibraryCard() -> (card: LiquidGlassCardView, subtitleLabel: NSTextField, toggleButton: NSButton) {
        let card = LiquidGlassCardView(cornerRadius: 30, tintAlpha: 0.02)
        card.configureNeutralGlass(tintAlpha: 0.05, glowOpacity: 0.0, refractionOpacity: 0.10)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 60).isActive = true
        card.widthAnchor.constraint(equalToConstant: 282).isActive = true

        let toggleButton = NSButton.liquidSymbol(symbol: "music.note.list", pointSize: 18, weight: .medium, target: self, action: #selector(togglePlaylistMode))
        toggleButton.contentTintColor = .white
        toggleButton.toolTip = "Toggle playlist mode on/off"
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        toggleButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let titleLabel = NSTextField.liquidLabel("Playlists & Library", size: 14, weight: .semibold, color: .white)
        titleLabel.alignment = .center

        let sLabel = NSTextField.liquidLabel("Off • Favorites", size: 10.5, weight: .regular, color: .white.withAlphaComponent(0.65))
        sLabel.alignment = .center
        sLabel.lineBreakMode = .byTruncatingTail
        sLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, sLabel])
        textStack.orientation = .vertical
        textStack.alignment = .centerX
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let overlayBtn = NSButton(title: "", target: self, action: #selector(showPlaylistLibraryDetail(_:)))
        overlayBtn.isBordered = false
        overlayBtn.isTransparent = true
        overlayBtn.translatesAutoresizingMaskIntoConstraints = false
        overlayBtn.toolTip = "Manage Playlists & Library"

        card.contentView.addSubview(toggleButton)
        card.contentView.addSubview(textStack)
        card.contentView.addSubview(overlayBtn, positioned: .below, relativeTo: toggleButton)

        NSLayoutConstraint.activate([
            toggleButton.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 14),
            toggleButton.centerYAnchor.constraint(equalTo: card.contentView.centerYAnchor),

            textStack.centerXAnchor.constraint(equalTo: card.contentView.centerXAnchor),
            textStack.centerYAnchor.constraint(equalTo: card.contentView.centerYAnchor),
            textStack.leadingAnchor.constraint(greaterThanOrEqualTo: toggleButton.trailingAnchor, constant: 8),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: card.contentView.trailingAnchor, constant: -14),

            overlayBtn.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            overlayBtn.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            overlayBtn.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor),
            overlayBtn.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor)
        ])

        return (card, sLabel, toggleButton)
    }

    private func buildSideBySideCard(title: String, subtitle: String, icon: String, iconColor: NSColor, action: Selector, showsProBadge: Bool = false) -> (LiquidGlassCardView, NSTextField) {
        let card = LiquidGlassCardView(cornerRadius: 30, tintAlpha: 0.02)
        card.configureNeutralGlass(tintAlpha: 0.05, glowOpacity: 0.0, refractionOpacity: 0.10)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 60).isActive = true
        card.widthAnchor.constraint(equalToConstant: 134).isActive = true
        
        let overlayBtn = NSButton(title: "", target: self, action: action)
        overlayBtn.isBordered = false
        overlayBtn.isTransparent = true
        overlayBtn.translatesAutoresizingMaskIntoConstraints = false
        overlayBtn.toolTip = "Open \(title)"
        
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        let iconImage = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(iconConfig)
        let iconView = NSImageView(image: iconImage ?? NSImage())
        iconView.contentTintColor = .white
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 22).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 22).isActive = true
        
        let titleRow = createSectionTitleRow(title: title, showsProBadge: showsProBadge)
        let sLabel = NSTextField.liquidLabel(subtitle, size: 10, weight: .regular, color: .white.withAlphaComponent(0.6))
        sLabel.lineBreakMode = .byTruncatingTail
        sLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [titleRow, sLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        let textRow = NSStackView(views: [iconView, stack])
        textRow.orientation = .horizontal
        textRow.alignment = .centerY
        textRow.spacing = 10
        textRow.translatesAutoresizingMaskIntoConstraints = false
        
        card.contentView.addSubview(textRow)
        card.contentView.addSubview(overlayBtn, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            textRow.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 14),
            textRow.trailingAnchor.constraint(lessThanOrEqualTo: card.contentView.trailingAnchor, constant: -8),
            textRow.centerYAnchor.constraint(equalTo: card.contentView.centerYAnchor)
        ])
        constrainEdges(of: overlayBtn, to: card.contentView)
        return (card, sLabel)
    }

    private func buildFooter() {
        let bringCard = buildFooterActionCard(title: "Bring Here", icon: "macwindow", action: #selector(doBring))
        let proCard = buildFooterActionCard(title: "Community", icon: "sparkles", action: #selector(showProSettingsAction))
        let quitCard = buildFooterActionCard(title: "Quit", icon: "power", action: #selector(doQuit))

        proFooterButton = proCard.button
        proFooterCardView = proCard.card
        proFooterButton?.toolTip = "About & Community"

        let footerRow = NSStackView(views: [bringCard.card, proCard.card, quitCard.card])
        footerRow.orientation = .horizontal
        footerRow.distribution = .fillEqually
        footerRow.spacing = 10
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.widthAnchor.constraint(equalToConstant: 282).isActive = true
        footerRow.heightAnchor.constraint(equalToConstant: 54).isActive = true

        mainStack.addArrangedSubview(footerRow)
    }

    private func buildFooterActionCard(title: String, icon: String, action: Selector) -> (card: LiquidGlassCardView, button: NSButton) {
        let card = LiquidGlassCardView(cornerRadius: 27, tintAlpha: 0.025)
        card.configureNeutralGlass(tintAlpha: 0.05, glowOpacity: 0.0, refractionOpacity: 0.10)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 54).isActive = true

        let overlayButton = NSButton(title: "", target: self, action: action)
        overlayButton.isBordered = false
        overlayButton.isTransparent = true
        overlayButton.translatesAutoresizingMaskIntoConstraints = false
        overlayButton.toolTip = title

        let iconView = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: nil)!)
        iconView.contentTintColor = .white
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField.liquidLabel(title, size: 12, weight: .semibold, color: .white.withAlphaComponent(0.94))
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let textRow = NSStackView(views: [iconView, titleLabel])
        textRow.orientation = .horizontal
        textRow.alignment = .centerY
        textRow.spacing = 6
        textRow.translatesAutoresizingMaskIntoConstraints = false

        card.contentView.addSubview(textRow)
        card.contentView.addSubview(overlayButton, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            textRow.leadingAnchor.constraint(greaterThanOrEqualTo: card.contentView.leadingAnchor, constant: 4),
            textRow.trailingAnchor.constraint(lessThanOrEqualTo: card.contentView.trailingAnchor, constant: -4),
            textRow.centerXAnchor.constraint(equalTo: card.contentView.centerXAnchor),
            textRow.centerYAnchor.constraint(equalTo: card.contentView.centerYAnchor)
        ])
        constrainEdges(of: overlayButton, to: card.contentView)

        return (card, overlayButton)
    }

    private func buildDetailOverlay(in root: NSView) {
        detailOverlay = NSView()
        detailOverlay.translatesAutoresizingMaskIntoConstraints = false
        detailOverlay.isHidden = true
        detailOverlay.alphaValue = 0
        detailOverlay.wantsLayer = true
        detailOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(detailOverlay)

        NSLayoutConstraint.activate([
            detailOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            detailOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            detailOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            detailOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])

        detailCard = DismissibleDetailCardView(cornerRadius: 30, tintAlpha: 0.025, useGlassEffect: true)
        detailCard.onBackgroundClick = { [weak self] in
            self?.hideDetail()
        }
        detailCard.translatesAutoresizingMaskIntoConstraints = true
        detailCard.autoresizingMask = []
        detailOverlay.addSubview(detailCard)

        detailTitleLabel = NSTextField.liquidLabel("", size: 15, weight: .bold)
        detailTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailTitleLabel.heightAnchor.constraint(equalToConstant: 18).isActive = true
        detailSubtitleLabel = NSTextField.liquidLabel("", size: 10, weight: .medium, color: .white.withAlphaComponent(0.72))
        detailSubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailSubtitleLabel.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let backButton = createCircleButton(icon: "chevron.left", size: 14, action: #selector(hideDetailAction), diameter: 30)
        backButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        backButton.toolTip = "Back"

        let headerTextStack = NSStackView(views: [detailTitleLabel, detailSubtitleLabel])
        headerTextStack.orientation = .vertical
        headerTextStack.alignment = .leading
        headerTextStack.spacing = 3
        headerTextStack.translatesAutoresizingMaskIntoConstraints = false

        let detailHeader = NSStackView(views: [backButton, headerTextStack, NSView()])
        detailHeader.alignment = .centerY
        detailHeader.spacing = 10
        detailHeader.translatesAutoresizingMaskIntoConstraints = false
        detailHeaderView = detailHeader

        detailBodyHost = NSView()
        detailBodyHost.translatesAutoresizingMaskIntoConstraints = false

        detailCard.contentView.addSubview(detailBodyHost)
        detailCard.contentView.addSubview(detailHeader)

        bodyTopToHeaderConstraint = detailBodyHost.topAnchor.constraint(equalTo: detailHeader.bottomAnchor, constant: 20)
        bodyTopToCardConstraint = detailBodyHost.topAnchor.constraint(equalTo: detailCard.contentView.topAnchor, constant: 14)
        bodyTopToHeaderConstraint.isActive = true
        bodyTopToCardConstraint.isActive = false

        NSLayoutConstraint.activate([
            detailHeader.topAnchor.constraint(equalTo: detailCard.contentView.topAnchor, constant: 18),
            detailHeader.leadingAnchor.constraint(equalTo: detailCard.contentView.leadingAnchor, constant: 18),
            detailHeader.trailingAnchor.constraint(equalTo: detailCard.contentView.trailingAnchor, constant: -18),
            detailBodyHost.bottomAnchor.constraint(equalTo: detailCard.contentView.bottomAnchor, constant: -18),
            detailBodyHost.leadingAnchor.constraint(equalTo: detailCard.contentView.leadingAnchor, constant: 18),
            detailBodyHost.trailingAnchor.constraint(equalTo: detailCard.contentView.trailingAnchor, constant: -18)
        ])

        buildDisplayDetail()
        buildPlayerDetail()
        buildAppDetail()
        buildPlaylistDetail()
        buildLibraryDetail()
        buildSettingsDetail()
        buildProDetail()
    }

    private func buildPlayerDetail() {
        let contentView = DismissibleContentView()
        contentView.onBackgroundClick = { [weak self] in self?.hideDetail() }
        playerDetailView = contentView
        playerDetailView.translatesAutoresizingMaskIntoConstraints = false

        // 1. Artwork: 48x48 square with continuous rounded corners
        expandedArtworkView = PlayerThumbnailView(cornerRadius: 10, showsGradient: false)
        expandedArtworkView.translatesAutoresizingMaskIntoConstraints = false
        let initialImg = currentTrackThumbnail ?? NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        expandedArtworkView.thumbnailImage = initialImg

        // 2. Title & Subtitle Stack (Static bold title with tail truncation)
        expandedTrackTitle = NSTextField.liquidLabel("Not Playing", size: 14, weight: .bold, color: .white)
        expandedTrackTitle.lineBreakMode = .byTruncatingTail
        expandedTrackTitle.maximumNumberOfLines = 1
        expandedTrackTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        expandedTrackSubtitle = NSTextField.liquidLabel("CineWall", size: 12, weight: .regular, color: .white.withAlphaComponent(0.65))
        expandedTrackSubtitle.lineBreakMode = .byTruncatingTail
        expandedTrackSubtitle.maximumNumberOfLines = 1
        expandedTrackSubtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let infoStack = NSStackView(views: [expandedTrackTitle, expandedTrackSubtitle])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 2
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        // 3. Top Right Actions (Favorite heart if active, and '•••' more options pinned to right)
        expandedFavButton = NSButton.liquidSymbol(symbol: "heart.fill", pointSize: 13, weight: .semibold, target: self, action: #selector(toggleFav))
        expandedFavButton.contentTintColor = .systemRed
        expandedFavButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        expandedFavButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        expandedFavButton.toolTip = "Remove from Favorites"
        expandedFavButton.isHidden = true

        expandedMoreButton = NSButton.liquidSymbol(symbol: "ellipsis", pointSize: 15, weight: .bold, target: self, action: #selector(showPlayerMoreMenu))
        expandedMoreButton.contentTintColor = .white.withAlphaComponent(0.85)
        expandedMoreButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        expandedMoreButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        expandedMoreButton.toolTip = "More Options"

        let actionsStack = NSStackView(views: [expandedFavButton, expandedMoreButton])
        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = 4
        actionsStack.translatesAutoresizingMaskIntoConstraints = false

        // Header Row Container: Artwork on left, Actions pinned to far right, InfoStack between them
        let headerRow = NSView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(expandedArtworkView)
        headerRow.addSubview(infoStack)
        headerRow.addSubview(actionsStack)

        NSLayoutConstraint.activate([
            headerRow.heightAnchor.constraint(equalToConstant: 48),

            expandedArtworkView.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            expandedArtworkView.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            expandedArtworkView.widthAnchor.constraint(equalToConstant: 48),
            expandedArtworkView.heightAnchor.constraint(equalToConstant: 48),

            actionsStack.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            actionsStack.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),

            infoStack.leadingAnchor.constraint(equalTo: expandedArtworkView.trailingAnchor, constant: 12),
            infoStack.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            infoStack.trailingAnchor.constraint(lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -8)
        ])

        // 4. Scrubber / Progress row
        progressSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(seekVideo))
        progressSlider.controlSize = .small
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        progressSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        playerElapsedLabel = NSTextField.liquidLabel("0:00", size: 11, weight: .medium, color: .white.withAlphaComponent(0.65))
        playerRemainingLabel = NSTextField.liquidLabel("-0:00", size: 11, weight: .medium, color: .white.withAlphaComponent(0.65))
        playerElapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        playerRemainingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        playerElapsedLabel.alignment = .left
        playerRemainingLabel.alignment = .right
        playerElapsedLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        playerRemainingLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true

        let progressRow = NSStackView(views: [playerElapsedLabel, progressSlider, playerRemainingLabel])
        progressRow.alignment = .centerY
        progressRow.spacing = 8
        progressRow.distribution = .fill
        progressRow.translatesAutoresizingMaskIntoConstraints = false
        progressRow.heightAnchor.constraint(equalToConstant: 16).isActive = true

        // 5. Bottom Row: Playlist button (bottom-left) and Transport Controls (exact center)
        addToPlaylistButton = NSButton.liquidSymbol(symbol: "list.bullet.rectangle", pointSize: 15, weight: .regular, target: self, action: #selector(showAddToPlaylistMenu))
        addToPlaylistButton.contentTintColor = .white.withAlphaComponent(0.85)
        addToPlaylistButton.toolTip = "Playlists"
        addToPlaylistButton.translatesAutoresizingMaskIntoConstraints = false

        let prev = NSButton.liquidSymbol(symbol: "backward.fill", pointSize: 16, weight: .semibold, target: self, action: #selector(doPrev))
        prev.contentTintColor = .white
        prev.widthAnchor.constraint(equalToConstant: 32).isActive = true
        prev.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let playConfig = NSImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        let playImg = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?.withSymbolConfiguration(playConfig)
        expandedPlayButton = NSButton.liquidSymbol(symbol: "play.fill", pointSize: 22, weight: .bold, target: self, action: #selector(togglePlay))
        expandedPlayButton.image = playImg
        expandedPlayButton.contentTintColor = .white
        expandedPlayButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        expandedPlayButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let next = NSButton.liquidSymbol(symbol: "forward.fill", pointSize: 16, weight: .semibold, target: self, action: #selector(doNext))
        next.contentTintColor = .white
        next.widthAnchor.constraint(equalToConstant: 32).isActive = true
        next.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let transportRow = NSStackView(views: [prev, expandedPlayButton, next])
        transportRow.alignment = .centerY
        transportRow.spacing = 24
        transportRow.translatesAutoresizingMaskIntoConstraints = false

        let bottomRow = NSView()
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.addSubview(addToPlaylistButton)
        bottomRow.addSubview(transportRow)

        NSLayoutConstraint.activate([
            bottomRow.heightAnchor.constraint(equalToConstant: 36),

            addToPlaylistButton.leadingAnchor.constraint(equalTo: bottomRow.leadingAnchor),
            addToPlaylistButton.centerYAnchor.constraint(equalTo: bottomRow.centerYAnchor),
            addToPlaylistButton.widthAnchor.constraint(equalToConstant: 28),
            addToPlaylistButton.heightAnchor.constraint(equalToConstant: 28),

            transportRow.centerXAnchor.constraint(equalTo: bottomRow.centerXAnchor),
            transportRow.centerYAnchor.constraint(equalTo: bottomRow.centerYAnchor)
        ])

        // Root Vertical Stack
        let rootStack = DismissibleStackView(views: [headerRow, progressRow, bottomRow])
        rootStack.onBackgroundClick = { [weak self] in self?.hideDetail() }
        rootStack.orientation = .vertical
        rootStack.spacing = 10
        rootStack.distribution = .fill
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        playerDetailView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: playerDetailView.topAnchor, constant: 0),
            rootStack.leadingAnchor.constraint(equalTo: playerDetailView.leadingAnchor, constant: 0),
            rootStack.trailingAnchor.constraint(equalTo: playerDetailView.trailingAnchor, constant: 0),
            rootStack.bottomAnchor.constraint(equalTo: playerDetailView.bottomAnchor),

            headerRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            progressRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
    }

    private func buildDisplayDetail() {
        let contentView = DismissibleContentView()
        contentView.onBackgroundClick = { [weak self] in self?.hideDetail() }
        displayDetailView = contentView
        displayDetailView.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = DismissibleStackView()
        rootStack.onBackgroundClick = { [weak self] in self?.hideDetail() }
        rootStack.orientation = .vertical
        rootStack.alignment = .centerX
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let scalingTitle = NSTextField.liquidLabel("Scaling", size: 14, weight: .semibold)
        scalingSeg = NSSegmentedControl(labels: ["Fill", "Fit", "Stretch"], trackingMode: .selectOne, target: self, action: #selector(scaleChanged))
        scalingSeg.segmentStyle = .rounded
        scalingSeg.controlSize = .regular

        let timerTitle = NSTextField.liquidLabel("Timer", size: 14, weight: .semibold)
        timerTitle.setContentHuggingPriority(.required, for: .horizontal)
        timerTitle.setContentCompressionResistancePriority(.required, for: .horizontal)

        timerLabel = NSTextField.liquidLabel("Off", size: 11, weight: .medium, color: .white.withAlphaComponent(0.72))
        timerLabel.setContentHuggingPriority(.required, for: .horizontal)
        timerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let timerSpacer = NSView()
        timerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        timerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let timerHeader = NSStackView(views: [timerTitle, timerSpacer, timerLabel])
        timerHeader.orientation = .horizontal
        timerHeader.alignment = .centerY
        timerHeader.distribution = .fill
        timerHeader.spacing = 8
        timerHeader.translatesAutoresizingMaskIntoConstraints = false

        let hoursInput = createTimerInputControl(placeholder: "00", action: #selector(timerChanged))
        let minutesInput = createTimerInputControl(placeholder: "00", action: #selector(timerChanged))
        let secondsInput = createTimerInputControl(placeholder: "00", action: #selector(timerChanged))
        timerHoursField = hoursInput.field
        timerMinutesField = minutesInput.field
        timerSecondsField = secondsInput.field

        let presetRow = NSStackView(views: [
            createTimerPresetButton("Off", seconds: 0),
            createTimerPresetButton("5s", seconds: 5),
            createTimerPresetButton("10s", seconds: 10),
            createTimerPresetButton("30s", seconds: 30),
            createTimerPresetButton("1m", seconds: 60),
            createTimerPresetButton("5m", seconds: 300)
        ])
        presetRow.alignment = .centerY
        presetRow.spacing = 5
        presetRow.translatesAutoresizingMaskIntoConstraints = false

        let hoursLabel = NSTextField.liquidLabel("HH", size: 10.5, weight: .semibold, color: .white.withAlphaComponent(0.75))
        hoursLabel.setContentHuggingPriority(.required, for: .horizontal)
        hoursLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let minutesLabel = NSTextField.liquidLabel("MM", size: 10.5, weight: .semibold, color: .white.withAlphaComponent(0.75))
        minutesLabel.setContentHuggingPriority(.required, for: .horizontal)
        minutesLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let secondsLabel = NSTextField.liquidLabel("SS", size: 10.5, weight: .semibold, color: .white.withAlphaComponent(0.75))
        secondsLabel.setContentHuggingPriority(.required, for: .horizontal)
        secondsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let setTimerButton = createCompactPillButton("Set", action: #selector(timerChanged))
        setTimerButton.widthAnchor.constraint(equalToConstant: 38).isActive = true

        let timerRow = NSStackView(views: [hoursLabel, hoursInput.container, minutesLabel, minutesInput.container, secondsLabel, secondsInput.container, setTimerButton])
        timerRow.alignment = .centerY
        timerRow.spacing = 4
        timerRow.translatesAutoresizingMaskIntoConstraints = false

        let timerCard = nestedGroupCard()
        timerCard.heightAnchor.constraint(equalToConstant: 104).isActive = true
        let timerStack = NSStackView(views: [timerHeader, presetRow, timerRow])
        timerStack.orientation = .vertical
        timerStack.alignment = .leading
        timerStack.spacing = 8
        timerStack.translatesAutoresizingMaskIntoConstraints = false
        timerHeader.widthAnchor.constraint(equalTo: timerStack.widthAnchor).isActive = true
        presetRow.widthAnchor.constraint(equalTo: timerStack.widthAnchor).isActive = true
        timerRow.widthAnchor.constraint(equalTo: timerStack.widthAnchor).isActive = true
        timerCard.contentView.addSubview(timerStack)

        let scalingCard = nestedGroupCard()
        scalingCard.heightAnchor.constraint(equalToConstant: 68).isActive = true
        let scalingStack = NSStackView(views: [scalingTitle, scalingSeg])
        scalingStack.orientation = .vertical
        scalingStack.alignment = .leading
        scalingStack.spacing = 6
        scalingStack.translatesAutoresizingMaskIntoConstraints = false
        scalingCard.contentView.addSubview(scalingStack)

        let desktopCard = nestedGroupCard()
        let desktopStack = NSStackView()
        desktopStack.orientation = .vertical
        desktopStack.alignment = .leading
        desktopStack.spacing = 6
        desktopStack.translatesAutoresizingMaskIntoConstraints = false

        let desktopTitle = NSTextField.liquidLabel("Desktop", size: 14, weight: .semibold)
        hideIconsToggle = createCheck("Hide Desktop Icons", action: #selector(togIcons))
        allSpacesToggle = createCheck("Show on All Spaces", action: #selector(togSpaces))
        [desktopTitle, hideIconsToggle!, allSpacesToggle!].forEach { desktopStack.addArrangedSubview($0) }
        let hasMultipleScreens = NSScreen.screens.count > 1
        if hasMultipleScreens {
            let spanCheck = createCheck("Span Ultrawide Across Displays", action: #selector(togSpanDisplays))
            spanDisplaysToggle = spanCheck
            desktopStack.addArrangedSubview(spanCheck)
        }
        desktopCard.contentView.addSubview(desktopStack)
        desktopCard.heightAnchor.constraint(equalToConstant: hasMultipleScreens ? 110 : 84).isActive = true

        let appearanceCard = nestedGroupCard()
        appearanceCard.heightAnchor.constraint(equalToConstant: 114).isActive = true
        let appearanceTitle = NSTextField.liquidLabel("Menu Darkness", size: 14, weight: .semibold)
        appearanceTitle.setContentHuggingPriority(.required, for: .horizontal)
        appearanceTitle.setContentCompressionResistancePriority(.required, for: .horizontal)

        menuTintValueLabel = NSTextField.liquidLabel("0%", size: 11, weight: .medium, color: .white.withAlphaComponent(0.72))
        menuTintValueLabel.setContentHuggingPriority(.required, for: .horizontal)
        menuTintValueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let appearanceSpacer = NSView()
        appearanceSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        appearanceSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let appearanceHeader = NSStackView(views: [appearanceTitle, appearanceSpacer, menuTintValueLabel])
        appearanceHeader.orientation = .horizontal
        appearanceHeader.alignment = .centerY
        appearanceHeader.distribution = .fill
        appearanceHeader.spacing = 8
        appearanceHeader.translatesAutoresizingMaskIntoConstraints = false

        menuTintSlider = NSSlider(value: appDelegate?.menuDarkTintStrength ?? 0.0, minValue: 0.0, maxValue: 1.0, target: self, action: #selector(menuTintChanged))
        menuTintSlider.controlSize = .regular
        menuTintSlider.translatesAutoresizingMaskIntoConstraints = false

        ambientGlowToggle = createCheck("Ambient Wallpaper Glow", action: #selector(togAmbientTint))

        let appearanceHint = NSTextField.liquidLabel("Subtly accents glass cards with active wallpaper colors.", size: 10.5, weight: .medium, color: .white.withAlphaComponent(0.65))
        appearanceHint.maximumNumberOfLines = 1
        appearanceHint.lineBreakMode = .byTruncatingTail
        let hintRow = NSStackView()
        hintRow.orientation = .horizontal
        hintRow.alignment = .centerY
        hintRow.spacing = 4
        hintRow.translatesAutoresizingMaskIntoConstraints = false
        let indentSpacer = NSView()
        indentSpacer.translatesAutoresizingMaskIntoConstraints = false
        indentSpacer.widthAnchor.constraint(equalToConstant: 18).isActive = true
        hintRow.addArrangedSubview(indentSpacer)
        hintRow.addArrangedSubview(appearanceHint)

        let appearanceStack = NSStackView(views: [appearanceHeader, menuTintSlider, ambientGlowToggle!, hintRow])
        appearanceStack.orientation = .vertical
        appearanceStack.alignment = .leading
        appearanceStack.spacing = 6
        appearanceStack.translatesAutoresizingMaskIntoConstraints = false
        appearanceHeader.widthAnchor.constraint(equalTo: appearanceStack.widthAnchor).isActive = true
        menuTintSlider.widthAnchor.constraint(equalTo: appearanceStack.widthAnchor).isActive = true
        appearanceCard.contentView.addSubview(appearanceStack)

        [timerCard, scalingCard, desktopCard, appearanceCard].forEach {
            rootStack.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalToConstant: detailWidth - 36).isActive = true
        }
        displayDetailView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: displayDetailView.topAnchor, constant: 4),
            rootStack.centerXAnchor.constraint(equalTo: displayDetailView.centerXAnchor),
            rootStack.leadingAnchor.constraint(greaterThanOrEqualTo: displayDetailView.leadingAnchor),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: displayDetailView.trailingAnchor),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: displayDetailView.bottomAnchor, constant: -4)
        ])
        constrainEdges(of: timerStack, to: timerCard.contentView, inset: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        constrainEdges(of: scalingStack, to: scalingCard.contentView, inset: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        constrainEdges(of: desktopStack, to: desktopCard.contentView, inset: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        constrainEdges(of: appearanceStack, to: appearanceCard.contentView, inset: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
    }

    private func buildPlaylistDetail() {
        let contentView = DismissibleContentView()
        contentView.onBackgroundClick = { [weak self] in self?.hideDetail() }
        playlistDetailView = contentView
        playlistDetailView.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = DismissibleStackView()
        rootStack.onBackgroundClick = { [weak self] in self?.hideDetail() }
        rootStack.orientation = .vertical
        rootStack.alignment = .centerX
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = createInlineDetailHeader(title: "Playlists", subtitle: "Choose the active playlist.")

        let modeCard = nestedGroupCard()
        modeCard.heightAnchor.constraint(equalToConstant: 78).isActive = true
        let modeStack = NSStackView()
        modeStack.orientation = .vertical
        modeStack.alignment = .leading
        modeStack.spacing = 6
        modeStack.translatesAutoresizingMaskIntoConstraints = false

        let modeTitle = NSTextField.liquidLabel("Playlist Mode", size: 14, weight: .semibold)
        modeTitle.heightAnchor.constraint(equalToConstant: 18).isActive = true
        playlistSelectionHintLabel = NSTextField.liquidLabel("Playlist mode is off.", size: 11, weight: .medium, color: .white.withAlphaComponent(0.68))
        playlistSelectionHintLabel.maximumNumberOfLines = 2
        playlistSelectionHintLabel.lineBreakMode = .byWordWrapping
        [modeTitle, playlistSelectionHintLabel].forEach { modeStack.addArrangedSubview($0) }
        modeCard.contentView.addSubview(modeStack)

        let listCard = nestedGroupCard()
        listCard.heightAnchor.constraint(equalToConstant: 206).isActive = true
        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let listTitle = NSTextField.liquidLabel("Choose Playlist", size: 14, weight: .semibold)
        let hint = NSTextField.liquidLabel("Select a playlist to make it active.", size: 11, weight: .medium, color: .white.withAlphaComponent(0.65))
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        playlistTableView = NSTableView()
        playlistTableView.backgroundColor = .clear
        playlistTableView.headerView = nil
        playlistTableView.dataSource = self
        playlistTableView.delegate = self
        playlistTableView.target = self
        playlistTableView.action = #selector(selectPlaylistFromTable(_:))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PlaylistName"))
        column.resizingMask = .autoresizingMask
        playlistTableView.addTableColumn(column)
        scrollView.documentView = playlistTableView

        listStack.addArrangedSubview(listTitle)
        listStack.addArrangedSubview(hint)
        listStack.addArrangedSubview(scrollView)
        listCard.contentView.addSubview(listStack)

        rootStack.addArrangedSubview(headerRow)
        rootStack.addArrangedSubview(modeCard)
        rootStack.addArrangedSubview(listCard)
        headerRow.widthAnchor.constraint(equalToConstant: detailWidth - 36).isActive = true
        modeCard.widthAnchor.constraint(equalToConstant: detailWidth - 36).isActive = true
        listCard.widthAnchor.constraint(equalToConstant: detailWidth - 36).isActive = true
        playlistDetailView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: playlistDetailView.topAnchor, constant: 0),
            rootStack.centerXAnchor.constraint(equalTo: playlistDetailView.centerXAnchor),
            rootStack.leadingAnchor.constraint(greaterThanOrEqualTo: playlistDetailView.leadingAnchor),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: playlistDetailView.trailingAnchor),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: playlistDetailView.bottomAnchor, constant: -6)
        ])
        constrainEdges(of: modeStack, to: modeCard.contentView, inset: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        constrainEdges(of: listStack, to: listCard.contentView, inset: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        scrollView.heightAnchor.constraint(equalToConstant: 116).isActive = true
    }

    private func buildLibraryDetail() {
        let contentView = DismissibleContentView()
        contentView.onBackgroundClick = { [weak self] in self?.hideDetail() }
        libraryDetailView = contentView
        libraryDetailView.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = DismissibleStackView()
        rootStack.onBackgroundClick = { [weak self] in self?.hideDetail() }
        rootStack.orientation = .vertical
        rootStack.alignment = .centerX
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = createInlineDetailHeader(title: "Library", subtitle: "Manage playlists and add media in bulk.")

        let manageCard = nestedGroupCard()
        manageCard.heightAnchor.constraint(equalToConstant: 144).isActive = true
        let manageStack = NSStackView()
        manageStack.orientation = .vertical
        manageStack.alignment = .leading
        manageStack.spacing = 6
        manageStack.translatesAutoresizingMaskIntoConstraints = false

        libraryPlaylistNameLabel = NSTextField.liquidLabel("Playlists", size: 14, weight: .semibold)
        libraryPlaylistHintLabel = NSTextField.liquidLabel("", size: 11, weight: .medium, color: .white.withAlphaComponent(0.65))
        libraryPlaylistHintLabel.isHidden = true

        let createPlaylistButton = createCircleButton(icon: "plus", size: 12, action: #selector(toggleCreatePlaylistEditor), diameter: 28)
        let deletePlaylistButton = createCircleButton(icon: "trash", size: 12, action: #selector(deletePlaylist), diameter: 28)
        let clearPlaylistButton = createCircleButton(icon: "eraser", size: 12, action: #selector(clearPlaylist), diameter: 28)
        createPlaylistButton.toolTip = "Create Playlist"
        deletePlaylistButton.toolTip = "Delete Playlist"
        clearPlaylistButton.toolTip = "Clear Playlist"

        let manageButtons = NSStackView(views: [createPlaylistButton, deletePlaylistButton, clearPlaylistButton])
        manageButtons.alignment = .centerY
        manageButtons.spacing = 6
        manageButtons.translatesAutoresizingMaskIntoConstraints = false

        let manageSpacer = NSView()
        manageSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        manageSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let manageHeader = NSStackView(views: [libraryPlaylistNameLabel, manageSpacer, manageButtons])
        manageHeader.alignment = .centerY
        manageHeader.spacing = 10
        manageHeader.translatesAutoresizingMaskIntoConstraints = false
        manageHeader.heightAnchor.constraint(equalToConstant: 28).isActive = true

        libraryCreatePlaylistField = NSTextField()
        libraryCreatePlaylistField.placeholderString = "Playlist name"
        libraryCreatePlaylistField.translatesAutoresizingMaskIntoConstraints = false
        libraryCreatePlaylistField.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let confirmCreateButton = createPillButton("Create", icon: "checkmark", action: #selector(confirmCreatePlaylist))
        let cancelCreateButton = createPillButton("Cancel", icon: "xmark", action: #selector(cancelCreatePlaylist))
        confirmCreateButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelCreateButton.setContentHuggingPriority(.required, for: .horizontal)
        libraryCreatePlaylistRow = NSStackView(views: [libraryCreatePlaylistField, confirmCreateButton, cancelCreateButton])
        libraryCreatePlaylistRow.alignment = .centerY
        libraryCreatePlaylistRow.spacing = 8
        libraryCreatePlaylistRow.translatesAutoresizingMaskIntoConstraints = false
        libraryCreatePlaylistRow.isHidden = true

        let playlistScrollView = NSScrollView()
        playlistScrollView.drawsBackground = false
        playlistScrollView.hasVerticalScroller = true
        playlistScrollView.borderType = .noBorder
        playlistScrollView.translatesAutoresizingMaskIntoConstraints = false

        libraryPlaylistTableView = NSTableView()
        libraryPlaylistTableView.backgroundColor = .clear
        libraryPlaylistTableView.headerView = nil
        libraryPlaylistTableView.dataSource = self
        libraryPlaylistTableView.delegate = self
        libraryPlaylistTableView.target = self
        libraryPlaylistTableView.action = #selector(selectPlaylistFromTable(_:))
        let playlistColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PlaylistName"))
        playlistColumn.resizingMask = .autoresizingMask
        libraryPlaylistTableView.addTableColumn(playlistColumn)
        playlistScrollView.documentView = libraryPlaylistTableView

        manageStack.addArrangedSubview(manageHeader)
        manageStack.addArrangedSubview(libraryCreatePlaylistRow)
        manageStack.addArrangedSubview(playlistScrollView)
        manageCard.contentView.addSubview(manageStack)

        let listCard = nestedGroupCard()
        listCard.heightAnchor.constraint(equalToConstant: 260).isActive = true
        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false

        libraryVideosTitleLabel = NSTextField.liquidLabel("Favorites", size: 14, weight: .semibold)
        libraryVideosTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        libraryVideosTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let addVideosButton = createCircleButton(icon: "plus.rectangle.on.folder", size: 12, action: #selector(addVideosToPlaylist), diameter: 28)
        addVideosButton.toolTip = "Add videos"
        librarySelectVideosButton = createCircleButton(icon: "checklist", size: 12, action: #selector(toggleVideoSelectionMode), diameter: 28)
        librarySelectVideosButton.toolTip = "Select videos"
        libraryRemoveSelectedButton = createCircleButton(icon: "minus.circle", size: 12, action: #selector(removeSelectedPlaylistVideos), diameter: 28)
        libraryRemoveSelectedButton.toolTip = "Remove selected videos"
        libraryRemoveSelectedButton.isHidden = true
        let videoButtons = NSStackView(views: [addVideosButton, librarySelectVideosButton, libraryRemoveSelectedButton])
        videoButtons.alignment = .centerY
        videoButtons.spacing = 6
        videoButtons.translatesAutoresizingMaskIntoConstraints = false

        let videoSpacer = NSView()
        videoSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        videoSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let videoHeader = NSStackView(views: [libraryVideosTitleLabel, videoSpacer, videoButtons])
        videoHeader.alignment = .centerY
        videoHeader.spacing = 10
        videoHeader.translatesAutoresizingMaskIntoConstraints = false
        videoHeader.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        playlistItemsTableView = NSTableView()
        playlistItemsTableView.backgroundColor = .clear
        playlistItemsTableView.headerView = nil
        playlistItemsTableView.dataSource = self
        playlistItemsTableView.delegate = self
        playlistItemsTableView.allowsMultipleSelection = true
        playlistItemsTableView.doubleAction = #selector(itemDoubleClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PlaylistItemName"))
        column.resizingMask = .autoresizingMask
        playlistItemsTableView.addTableColumn(column)
        scrollView.documentView = playlistItemsTableView

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Play", action: #selector(itemDoubleClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Remove from Playlist", action: #selector(deleteItem), keyEquivalent: ""))
        playlistItemsTableView.menu = menu

        listStack.addArrangedSubview(videoHeader)
        listStack.addArrangedSubview(scrollView)
        listCard.contentView.addSubview(listStack)

        rootStack.addArrangedSubview(headerRow)
        rootStack.addArrangedSubview(manageCard)
        rootStack.addArrangedSubview(listCard)
        headerRow.widthAnchor.constraint(equalToConstant: detailWidth - 36).isActive = true
        manageCard.widthAnchor.constraint(equalToConstant: detailWidth - 36).isActive = true
        listCard.widthAnchor.constraint(equalToConstant: detailWidth - 36).isActive = true
        libraryDetailView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: libraryDetailView.topAnchor, constant: 0),
            rootStack.centerXAnchor.constraint(equalTo: libraryDetailView.centerXAnchor),
            rootStack.leadingAnchor.constraint(greaterThanOrEqualTo: libraryDetailView.leadingAnchor),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: libraryDetailView.trailingAnchor),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: libraryDetailView.bottomAnchor, constant: -6)
        ])
        constrainEdges(of: manageStack, to: manageCard.contentView, inset: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        constrainEdges(of: listStack, to: listCard.contentView, inset: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        playlistScrollView.heightAnchor.constraint(equalToConstant: 78).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 194).isActive = true
        updatePlaylistSelectionUI()
    }

    private func buildSettingsDetail() {
        let contentView = DismissibleContentView()
        contentView.onBackgroundClick = { [weak self] in self?.hideDetail() }
        settingsDetailView = contentView
        settingsDetailView.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = DismissibleStackView()
        rootStack.onBackgroundClick = { [weak self] in self?.hideDetail() }
        rootStack.orientation = .vertical
        rootStack.alignment = .centerX
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let smartCard = nestedGroupCard()
        let smartStack = NSStackView()
        smartStack.orientation = .vertical
        smartStack.alignment = .leading
        smartStack.spacing = 8
        smartStack.translatesAutoresizingMaskIntoConstraints = false

        smartPauseToggle = createCheck("Smart Pause", action: #selector(togSmart))
        batterySaverToggle = createCheck("Pause on Battery Power", action: #selector(togBattery))
        focusPauseToggle = createCheck("Pause on App Focus", action: #selector(togFocusP))
        focusMuteToggle = createCheck("Mute on App Focus", action: #selector(togFocusM))
        let smartTitle = createSectionTitleRow(title: "Smart Settings", showsProBadge: false)
        [smartTitle, smartPauseToggle!, focusMuteToggle!, focusPauseToggle!, batterySaverToggle!]
            .forEach { smartStack.addArrangedSubview($0) }
        smartCard.contentView.addSubview(smartStack)

        let lockScreenCard = nestedGroupCard()
        let lockScreenStack = NSStackView()
        lockScreenStack.orientation = .vertical
        lockScreenStack.alignment = .leading
        lockScreenStack.spacing = 10
        lockScreenStack.translatesAutoresizingMaskIntoConstraints = false

        lockScreenEnabledToggle = createCheck("Enable Lock Screen Sync", action: #selector(togLockScreenSyncEnabled))
        autoIdleSyncToggle = createCheck("Auto Sync Lock Screen Wallpaper", action: #selector(togAutoIdleSync))
        restoreOnQuitToggle = createCheck("Restore Wallpaper on Quit", action: #selector(togRestoreOnQuit))
        idleSyncButton = createPillButton("Sync Current to Lock Screen", icon: "arrow.triangle.2.circlepath", action: #selector(syncIdleWallpaper))
        restoreWallpaperButton = createPillButton("Restore macOS Wallpaper", icon: "arrow.counterclockwise", action: #selector(restoreDefaultWallpaper))
        idleSyncStatusLabel = NSTextField.liquidLabel("Lock screen ready.", size: 11, weight: .medium, color: .white.withAlphaComponent(0.72))
        idleSyncStatusLabel.maximumNumberOfLines = 2
        idleSyncStatusLabel.lineBreakMode = .byWordWrapping
        let lockScreenTitle = createSectionTitleRow(title: "Lock Screen Settings", showsProBadge: false)

        [lockScreenTitle, lockScreenEnabledToggle!, autoIdleSyncToggle!, restoreOnQuitToggle!, idleSyncButton!, restoreWallpaperButton!, idleSyncStatusLabel!].forEach {
            lockScreenStack.addArrangedSubview($0)
        }
        idleSyncButton.widthAnchor.constraint(equalTo: lockScreenStack.widthAnchor).isActive = true
        restoreWallpaperButton.widthAnchor.constraint(equalTo: lockScreenStack.widthAnchor).isActive = true
        lockScreenCard.contentView.addSubview(lockScreenStack)

        rootStack.addArrangedSubview(smartCard)
        rootStack.addArrangedSubview(lockScreenCard)
        smartCard.widthAnchor.constraint(equalToConstant: detailWidth - 36).isActive = true
        lockScreenCard.widthAnchor.constraint(equalToConstant: detailWidth - 36).isActive = true
        settingsDetailView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: settingsDetailView.topAnchor, constant: 0),
            rootStack.centerXAnchor.constraint(equalTo: settingsDetailView.centerXAnchor),
            rootStack.leadingAnchor.constraint(greaterThanOrEqualTo: settingsDetailView.leadingAnchor),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: settingsDetailView.trailingAnchor),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: settingsDetailView.bottomAnchor, constant: -6)
        ])
        constrainEdges(of: smartStack, to: smartCard.contentView, inset: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        constrainEdges(of: lockScreenStack, to: lockScreenCard.contentView, inset: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
    }

    private func buildAppDetail() {
        let contentView = DismissibleContentView()
        contentView.onBackgroundClick = { [weak self] in self?.hideDetail() }
        appDetailView = contentView
        appDetailView.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = DismissibleStackView()
        rootStack.onBackgroundClick = { [weak self] in self?.hideDetail() }
        rootStack.orientation = .vertical
        rootStack.alignment = .centerX
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = createInlineDetailHeader(title: "CineWall", subtitle: "App info, updates, and startup behavior.")

        let infoCard = nestedGroupCard()
        let infoStack = NSStackView()
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 8
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField.liquidLabel("Version Details", size: 14, weight: .semibold)
        appVersionLabel = NSTextField.liquidLabel("Version 2.0", size: 12, weight: .semibold, color: .white.withAlphaComponent(0.82))
        appStatusLabel = NSTextField.liquidLabel("Free plan.", size: 11, weight: .medium, color: .white.withAlphaComponent(0.66))
        appStatusLabel.maximumNumberOfLines = 2
        appStatusLabel.lineBreakMode = .byWordWrapping
        let taglineLabel = NSTextField.liquidLabel("The ultimate local video wallpaper utility for macOS.", size: 11, weight: .medium, color: .white.withAlphaComponent(0.60))
        taglineLabel.maximumNumberOfLines = 2
        taglineLabel.lineBreakMode = .byWordWrapping

        [titleLabel, appVersionLabel!, appStatusLabel!, taglineLabel].forEach { infoStack.addArrangedSubview($0) }
        infoCard.contentView.addSubview(infoStack)

        let startupCard = nestedGroupCard()
        let startupStack = NSStackView()
        startupStack.orientation = .vertical
        startupStack.alignment = .leading
        startupStack.spacing = 8
        startupStack.translatesAutoresizingMaskIntoConstraints = false

        loginToggle = createCheck("Start at Login", action: #selector(togLogin))
        let startupTitle = NSTextField.liquidLabel("Startup Settings", size: 14, weight: .semibold)
        [startupTitle, loginToggle!].forEach { startupStack.addArrangedSubview($0) }
        startupCard.contentView.addSubview(startupStack)

        let updatesCard = nestedGroupCard()
        let updatesStack = NSStackView()
        updatesStack.orientation = .vertical
        updatesStack.alignment = .leading
        updatesStack.spacing = 8
        updatesStack.translatesAutoresizingMaskIntoConstraints = false

        let updatesTitle = NSTextField.liquidLabel("Updates", size: 14, weight: .semibold)
        let updatesButton = createPillButton("Check for Updates", icon: "arrow.down.circle", action: #selector(checkForUpdatesAction))
        updatesStatusLabel = NSTextField.liquidLabel("Automatic app updates are not configured yet.", size: 11, weight: .medium, color: .white.withAlphaComponent(0.66))
        updatesStatusLabel.maximumNumberOfLines = 2
        updatesStatusLabel.lineBreakMode = .byWordWrapping
        [updatesTitle, updatesButton, updatesStatusLabel!].forEach { updatesStack.addArrangedSubview($0) }
        updatesCard.contentView.addSubview(updatesStack)

        rootStack.addArrangedSubview(headerRow)
        [infoCard, startupCard, updatesCard].forEach {
            rootStack.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalToConstant: detailWidth - 36).isActive = true
        }
        appDetailView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: appDetailView.topAnchor, constant: 8),
            rootStack.centerXAnchor.constraint(equalTo: appDetailView.centerXAnchor),
            rootStack.leadingAnchor.constraint(greaterThanOrEqualTo: appDetailView.leadingAnchor),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: appDetailView.trailingAnchor),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: appDetailView.bottomAnchor, constant: -6)
        ])
        constrainEdges(of: infoStack, to: infoCard.contentView, inset: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        constrainEdges(of: startupStack, to: startupCard.contentView, inset: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        constrainEdges(of: updatesStack, to: updatesCard.contentView, inset: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
    }

    private func buildProDetail() {
        let contentView = DismissibleContentView()
        contentView.onBackgroundClick = { [weak self] in self?.hideDetail() }
        proDetailView = contentView
        proDetailView.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = DismissibleStackView()
        rootStack.onBackgroundClick = { [weak self] in self?.hideDetail() }
        rootStack.orientation = .vertical
        rootStack.alignment = .centerX
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = createInlineDetailHeader(title: "About CineWall", subtitle: "v3.0 Tahoe Edition • Free & Open Source")

        // Overview Card
        let overviewCard = nestedGroupCard()
        overviewCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 86).isActive = true
        let overviewTitle = NSTextField.liquidLabel("CineWall v3.0 (Tahoe Edition)", size: 14, weight: .semibold)
        let overviewDesc = NSTextField.liquidLabel("The native video wallpaper engine for macOS with Liquid Glass UI, lock screen sync, playlist support, and zero-space favorites.", size: 11, weight: .medium, color: .white.withAlphaComponent(0.72))
        overviewDesc.maximumNumberOfLines = 3
        overviewDesc.lineBreakMode = .byWordWrapping
        let licenseBadge = NSTextField.liquidLabel("MIT License • All Features Unlocked", size: 11, weight: .semibold, color: NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.55, alpha: 1.0))
        
        let overviewStack = NSStackView(views: [overviewTitle, overviewDesc, licenseBadge])
        overviewStack.orientation = .vertical
        overviewStack.alignment = .leading
        overviewStack.spacing = 6
        overviewStack.translatesAutoresizingMaskIntoConstraints = false
        overviewCard.contentView.addSubview(overviewStack)

        // Community & GitHub Card
        let communityCard = nestedGroupCard()
        communityCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let communityTitle = NSTextField.liquidLabel("Community & Links", size: 14, weight: .semibold)
        
        let gitHubButton = createPillButton("Star on GitHub", icon: "star.fill", action: #selector(openGitHubAction))
        let issuesButton = createPillButton("Report Issue", icon: "bubble.left.and.exclamationmark.bubble.right.fill", action: #selector(openIssuesAction))
        let releasesButton = createPillButton("Releases", icon: "sparkles", action: #selector(openReleasesAction))
        let updatesButton = createPillButton("Check Updates", icon: "arrow.triangle.2.circlepath", action: #selector(checkForUpdatesAction))

        [gitHubButton, issuesButton, releasesButton, updatesButton].forEach {
            $0.font = NSFont.systemFont(ofSize: 10.0, weight: .semibold)
        }

        let row1 = NSStackView(views: [gitHubButton, issuesButton])
        row1.distribution = .fillEqually
        row1.spacing = 8
        row1.translatesAutoresizingMaskIntoConstraints = false

        let row2 = NSStackView(views: [releasesButton, updatesButton])
        row2.distribution = .fillEqually
        row2.spacing = 8
        row2.translatesAutoresizingMaskIntoConstraints = false

        let communityStack = NSStackView(views: [communityTitle, row1, row2])
        communityStack.orientation = .vertical
        communityStack.alignment = .leading
        communityStack.spacing = 10
        communityStack.translatesAutoresizingMaskIntoConstraints = false
        communityCard.contentView.addSubview(communityStack)

        rootStack.addArrangedSubview(headerRow)
        [overviewCard, communityCard].forEach {
            rootStack.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalToConstant: detailWidth - 36).isActive = true
        }
        headerRow.widthAnchor.constraint(equalToConstant: detailWidth - 36).isActive = true
        proDetailView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: proDetailView.topAnchor, constant: 0),
            rootStack.centerXAnchor.constraint(equalTo: proDetailView.centerXAnchor),
            rootStack.leadingAnchor.constraint(greaterThanOrEqualTo: proDetailView.leadingAnchor),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: proDetailView.trailingAnchor),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: proDetailView.bottomAnchor, constant: -6)
        ])
        constrainEdges(of: overviewStack, to: overviewCard.contentView, inset: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        constrainEdges(of: communityStack, to: communityCard.contentView, inset: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
    }

    private func createSummaryCard(title: String, action: Selector, showsProBadge: Bool = false) -> (card: LiquidGlassCardView, subtitleLabel: NSTextField) {
        let card = LiquidGlassCardView(cornerRadius: 24, tintAlpha: 0.025)
        card.configureNeutralGlass(tintAlpha: 0.05, glowOpacity: 0.0, refractionOpacity: 0.10)
        card.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let icon = createSectionTitleRow(title: title, showsProBadge: showsProBadge)
        let subtitle = NSTextField.liquidLabel(" ", size: 11, weight: .medium, color: .white.withAlphaComponent(0.68))

        let labelStack = NSStackView(views: [icon, subtitle])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 4
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        let chevron = NSTextField.liquidLabel("›", size: 24, weight: .light, color: .white.withAlphaComponent(0.82))
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let overlayButton = NSButton(title: "", target: self, action: action)
        overlayButton.isBordered = false
        overlayButton.translatesAutoresizingMaskIntoConstraints = false

        card.contentView.addSubview(labelStack)
        card.contentView.addSubview(chevron)
        card.contentView.addSubview(overlayButton)

        NSLayoutConstraint.activate([
            labelStack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 16),
            labelStack.centerYAnchor.constraint(equalTo: card.contentView.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: card.contentView.centerYAnchor),
            overlayButton.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            overlayButton.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            overlayButton.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            overlayButton.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor)
        ])

        return (card, subtitle)
    }

    private func createInlineDetailHeader(title: String, subtitle: String) -> NSStackView {
        let backButton = createCircleButton(icon: "chevron.left", size: 14, action: #selector(hideDetailAction), diameter: 30)
        backButton.toolTip = "Back"
        backButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleLabel = NSTextField.liquidLabel(title, size: 15, weight: .bold)
        let subtitleLabel = NSTextField.liquidLabel(subtitle, size: 10, weight: .medium, color: .white.withAlphaComponent(0.72))
        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [backButton, textStack, NSView()])
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        return headerRow
    }

    private func createSectionTitleRow(title: String, showsProBadge: Bool = false) -> NSStackView {
        let titleLabel = NSTextField.liquidLabel(title, size: 14, weight: .semibold, color: .white)
        let row = NSStackView(views: [titleLabel])
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func createProBadge() -> NSTextField {
        let badge = NSTextField(labelWithString: "")
        badge.identifier = NSUserInterfaceItemIdentifier("proBadge")
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 0).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 0).isActive = true
        return badge
    }

    private func requireProAccess(_ feature: ProFeature) -> Bool {
        appDelegate?.requireProAccess(for: feature) ?? false
    }

    private func updateProVisibility() {
        guard let app = appDelegate else { return }
        let title: String
        proFooterButton?.title = "★ CineWall v3.0"
        proFooterButton?.contentTintColor = .white
        proStatusLabel?.stringValue = "Open Source Edition"
        proDescriptionLabel?.stringValue = "All features are permanently unlocked under the MIT License."
        proTrialButton?.isHidden = app.proManager.hasActivatedLicense
        proTrialButton?.isEnabled = !app.proManager.hasUsedTrial && !app.proManager.isTrialActive
        proTrialButton?.alphaValue = proTrialButton.isEnabled ? 1.0 : 0.55
        proLicenseField?.isEnabled = !app.proManager.hasActivatedLicense
        proLicenseField?.alphaValue = proLicenseField.isEnabled ? 1.0 : 0.7
        proPasteButton?.isEnabled = !app.proManager.hasActivatedLicense
        proPasteButton?.alphaValue = proPasteButton.isEnabled ? 1.0 : 0.75
        proActivateButton?.title = app.proManager.hasActivatedLicense ? "Pro Active" : "Activate Key"
        proActivateButton?.isEnabled = !app.proManager.hasActivatedLicense
        proActivateButton?.alphaValue = proActivateButton.isEnabled ? 1.0 : 0.75
        #if DEBUG
        if let proDeveloperButton {
            let isDevUnlocked = app.proManager.isDeveloperUnlocked
            proDeveloperButton.title = isDevUnlocked ? "Disable Dev Pro" : "Enable Dev Pro"
            proDeveloperButton.isHidden = app.proManager.licenseKey != nil
            proDeveloperButton.alphaValue = 0.9
        }
        proResetDebugButton?.alphaValue = 0.9
        #endif

        let isPlaylistPro = app.proManager.canUse(.playlists)
        let isTimerPro = app.proManager.canUse(.timer)
        let isLockScreenPro = app.proManager.canUse(.lockScreenSync)
        let isSmartPro = app.proManager.canUse(.smartSettings)
        let isLockScreenEnabled = app.lockScreenSyncEnabled && isLockScreenPro
        updateProBadgeVisibility(isHidden: true)

        playlistToggleButton?.alphaValue = 1.0
        addToPlaylistButton?.toolTip = "Playlists"
        addToPlaylistButton?.alphaValue = 1.0
        lockScreenEnabledToggle?.alphaValue = isLockScreenPro ? 1.0 : 0.6
        autoIdleSyncToggle?.alphaValue = isLockScreenEnabled ? 1.0 : 0.6
        autoIdleSyncToggle?.isEnabled = isLockScreenEnabled
        restoreOnQuitToggle?.alphaValue = isLockScreenPro ? 1.0 : 0.6
        restoreOnQuitToggle?.isEnabled = isLockScreenPro
        idleSyncButton?.alphaValue = isLockScreenEnabled ? 1.0 : 0.72
        idleSyncButton?.isEnabled = isLockScreenEnabled && !(app.idleWallpaperSyncInProgress)
        restoreWallpaperButton?.alphaValue = 1.0
        restoreWallpaperButton?.isEnabled = !(app.idleWallpaperSyncInProgress)
        smartPauseToggle?.alphaValue = isSmartPro ? 1.0 : 0.6
        batterySaverToggle?.alphaValue = isSmartPro ? 1.0 : 0.6
        focusPauseToggle?.alphaValue = isSmartPro ? 1.0 : 0.6
        focusMuteToggle?.alphaValue = isSmartPro ? 1.0 : 0.6
        timerHoursField?.alphaValue = isTimerPro ? 1.0 : 0.7
        timerMinutesField?.alphaValue = isTimerPro ? 1.0 : 0.7
        timerSecondsField?.alphaValue = isTimerPro ? 1.0 : 0.7
        timerLabel?.textColor = isTimerPro ? .white.withAlphaComponent(0.72) : .white.withAlphaComponent(0.5)
    }

    private func updateProBadgeVisibility(isHidden: Bool) {
        func apply(to view: NSView) {
            if view.identifier?.rawValue == "proBadge" {
                view.isHidden = isHidden
            }
            view.subviews.forEach(apply(to:))
        }

        apply(to: view)
    }

    private func nestedGroupCard() -> LiquidGlassCardView {
        let card = LiquidGlassCardView(cornerRadius: 22, tintAlpha: 0.025)
        card.configureNeutralGlass(tintAlpha: 0.05, glowOpacity: 0.0, refractionOpacity: 0.10)
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    private func constrainEdges(of child: NSView,
                                to parent: NSView,
                                inset: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset.top),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset.bottom),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset.left),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset.right)
        ])
    }

    private func createCircleButton(icon: String,
                                    size: CGFloat,
                                    action: Selector,
                                    diameter: CGFloat = 34) -> NSButton {
        let button = LiquidGlassButton(title: "", icon: nil, cornerRadius: diameter / 2, target: self, action: action)
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        button.image = button.image?.withSymbolConfiguration(config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: diameter),
            button.heightAnchor.constraint(equalToConstant: diameter)
        ])
        return button
    }

    private func createPillButton(_ title: String, icon: String, action: Selector) -> NSButton {
        let button = LiquidGlassButton(title: title, icon: icon, cornerRadius: 18, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return button
    }

    private func createCompactPillButton(_ title: String, action: Selector) -> NSButton {
        let button = LiquidGlassButton(title: title, icon: nil, cornerRadius: 16, target: self, action: action)
        button.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func createTimerPresetButton(_ title: String, seconds: Int) -> NSButton {
        let button = createCompactPillButton(title, action: #selector(applyTimerPreset(_:)))
        button.tag = seconds
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.contentTintColor = .white.withAlphaComponent(0.95)
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    private func createTimerInputControl(placeholder: String, action: Selector) -> (container: NSView, field: NSTextField) {
        let container = LiquidGlassCardView(cornerRadius: 12, tintAlpha: 0.03)
        container.configureNeutralGlass(tintAlpha: 0.05, glowOpacity: 0.0, refractionOpacity: 0.10)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 36).isActive = true
        container.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let field = NSTextField()
        field.placeholderString = placeholder
        field.alignment = .center
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        field.textColor = .white
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = action
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        container.contentView.addSubview(field)

        NSLayoutConstraint.activate([
            field.centerXAnchor.constraint(equalTo: container.contentView.centerXAnchor),
            field.centerYAnchor.constraint(equalTo: container.contentView.centerYAnchor),
            field.widthAnchor.constraint(equalTo: container.contentView.widthAnchor, constant: -6),
            field.heightAnchor.constraint(equalToConstant: 18)
        ])

        return (container, field)
    }

    private func createWideTextInputControl(placeholder: String) -> (container: NSView, field: NSTextField) {
        let container = LiquidGlassCardView(cornerRadius: 12, tintAlpha: 0.03)
        container.configureNeutralGlass(tintAlpha: 0.05, glowOpacity: 0.0, refractionOpacity: 0.10)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        field.textColor = .white
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        container.contentView.addSubview(field)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: container.contentView.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 18)
        ])

        return (container, field)
    }

    private func createCheck(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        button.contentTintColor = .white
        return button
    }

    private func scalingName(for tag: Int) -> String {
        switch tag {
        case 1: return "Fill"
        case 2: return "Fit"
        case 3: return "Stretch"
        default: return "Fill"
        }
    }

    private func formattedTimerText(totalSeconds: Int) -> String {
        guard totalSeconds > 0 else { return "Off" }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02dhr %02dmin %02dsec", hours, minutes, seconds)
    }

    private func compactTimerSummaryText(totalSeconds: Int) -> String {
        guard totalSeconds > 0 else { return "Timer off" }
        if totalSeconds < 60 { return "\(totalSeconds)s timer" }
        if totalSeconds % 3600 == 0 { return "\(totalSeconds / 3600)h timer" }
        if totalSeconds % 60 == 0 { return "\(totalSeconds / 60)m timer" }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes)m \(seconds)s timer"
    }

    private func updateSummaryLabels() {
        guard let app = appDelegate else { return }
        let totalSeconds = Int(app.autoChangeInterval)
        let timerText = compactTimerSummaryText(totalSeconds: totalSeconds)
        displaySummaryLabel.stringValue = "\(scalingName(for: app.scalingTag)) • \(timerText)"

        let folderText: String
        if let lastFolderPath = app.lastFolderPath {
            folderText = URL(fileURLWithPath: lastFolderPath).lastPathComponent
        } else {
            folderText = "No folder"
        }
        let playlistState = app.isPlaylistFilterEnabled ? "On" : "Off"
        playlistSummaryLabel.stringValue = "\(playlistState) • \(app.selectedPlaylistName) (\(app.orderedPlaylistNames().count) playlists)"
        librarySummaryLabel.stringValue = playlistSummaryLabel.stringValue
        libraryPlaylistNameLabel?.stringValue = "Playlists"
        libraryPlaylistHintLabel?.stringValue = ""
        libraryPlaylistHintLabel?.isHidden = true
        libraryVideosTitleLabel?.stringValue = app.selectedPlaylistName
        playlistSelectionHintLabel?.stringValue = app.isPlaylistFilterEnabled
            ? "Playlist mode is on for \(app.selectedPlaylistName)."
            : "Playlist mode is off. \(app.selectedPlaylistName) is ready."

        var settingFlags: [String] = []
        if app.smartPauseEnabled { settingFlags.append("Smart Pause") }
        if !app.lockScreenSyncEnabled {
            settingFlags.append("Lock Sync Off")
        } else if app.autoSyncIdleWallpaper {
            settingFlags.append("Auto Lock Sync")
        } else {
            settingFlags.append("Lock Sync On")
        }
        settingsSummaryLabel.stringValue = settingFlags.isEmpty ? "Smart rules and lock screen" : settingFlags.joined(separator: " • ")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let cpuText = String(format: "%.1f", app.getAppCPU())
        let ramText = app.getAppRAM()
        appHeaderSubtitleLabel?.stringValue = "CPU \(cpuText)% • RAM \(ramText)"
        appVersionLabel?.stringValue = "Version \(version) (\(build))"
        appStatusLabel?.stringValue = app.currentAccessDescription()
    }

    private func updateDetailContent(for section: DetailSection) {
        detailTitleLabel.stringValue = section.title
        detailSubtitleLabel.stringValue = section.subtitle
        detailHeaderView.isHidden = (section == .app || section == .player || section == .playlist || section == .library || section == .pro)

        // Switch body top constraint: for player, pin to card top; otherwise below header
        if section == .app || section == .player || section == .playlist || section == .library || section == .pro {
            bodyTopToHeaderConstraint.isActive = false
            bodyTopToCardConstraint.isActive = true
            bodyTopToCardConstraint.constant = section == .player ? 14 : 18
        } else {
            bodyTopToCardConstraint.isActive = false
            bodyTopToHeaderConstraint.isActive = true
            switch section {
            case .settings:
                bodyTopToHeaderConstraint.constant = 18
            case .display:
                bodyTopToHeaderConstraint.constant = 18
            default:
                bodyTopToHeaderConstraint.constant = 20
            }
        }

        for sub in detailBodyHost.subviews {
            sub.removeFromSuperview()
        }
        let activeBodyView: NSView
        switch section {
        case .player: activeBodyView = playerDetailView
        case .app: activeBodyView = appDetailView
        case .playlist: activeBodyView = playlistDetailView
        case .display: activeBodyView = displayDetailView
        case .library: activeBodyView = libraryDetailView
        case .settings: activeBodyView = settingsDetailView
        case .pro: activeBodyView = proDetailView
        }
        activeBodyView.translatesAutoresizingMaskIntoConstraints = false
        activeBodyView.isHidden = false
        detailBodyHost.addSubview(activeBodyView)
        NSLayoutConstraint.activate([
            activeBodyView.topAnchor.constraint(equalTo: detailBodyHost.topAnchor),
            activeBodyView.bottomAnchor.constraint(equalTo: detailBodyHost.bottomAnchor),
            activeBodyView.leadingAnchor.constraint(equalTo: detailBodyHost.leadingAnchor),
            activeBodyView.trailingAnchor.constraint(equalTo: detailBodyHost.trailingAnchor)
        ])

        if section == .player {
            let displayImg = currentTrackThumbnail ?? NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            expandedArtworkView?.thumbnailImage = displayImg
            let title = compactTrackMarquee?.stringValue ?? trackTitle.stringValue
            expandedTrackTitle?.stringValue = title.isEmpty ? "Not Playing" : title
            updateSubtitle()
            let isFav = appDelegate?.currentQueue.isEmpty == false && appDelegate?.containsVideo(path: appDelegate!.currentQueue[appDelegate!.queueIndex].path, inPlaylist: "Favorites") == true
            expandedFavButton?.image = NSImage(systemSymbolName: isFav ? "heart.fill" : "heart", accessibilityDescription: nil)
            expandedFavButton?.contentTintColor = isFav ? .systemRed : .white
            expandedFavButton?.isHidden = !isFav
            
            let isPaused = appDelegate?.isManualPaused ?? false
            let playConfig = NSImage.SymbolConfiguration(pointSize: 22, weight: .bold)
            expandedPlayButton?.image = NSImage(systemSymbolName: isPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil)?.withSymbolConfiguration(playConfig)
        }
        if section == .playlist {
            playlistTableView.reloadData()
        }
        if section == .library {
            libraryPlaylistTableView.reloadData()
            playlistItemsTableView.reloadData()
        }
    }

    private func detailTargetHeight(for section: DetailSection) -> CGFloat {
        let bodyView: NSView
        let minimumHeight: CGFloat
        switch section {
        case .app:
            bodyView = appDetailView
            minimumHeight = 328
        case .player:
            bodyView = playerDetailView
            minimumHeight = 120
        case .playlist:
            bodyView = playlistDetailView
            minimumHeight = 294
        case .display:
            bodyView = displayDetailView
            minimumHeight = (NSScreen.screens.count > 1) ? 432 : 408
        case .library:
            bodyView = libraryDetailView
            minimumHeight = 454
        case .settings:
            bodyView = settingsDetailView
            minimumHeight = 440
        case .pro:
            bodyView = proDetailView
            minimumHeight = 360
        }

        let bodyHeight = max(bodyView.fittingSize.height, minimumHeight)
        // Player: body pins to card top (14) + bottom (18) = 32
        // Others: chrome = top(18) + header(~34) + gap(14) + bottom(18) = 84
        let chromeHeight: CGFloat = (section == .player) ? 32 : 86
        let paddedHeight = bodyHeight + chromeHeight
        return min(max(paddedHeight, 140), view.bounds.height - 16)
    }

    private func detailTargetFrame(for section: DetailSection) -> NSRect {
        let frame = view.bounds.insetBy(dx: 6, dy: 8)
        let height = min(detailTargetHeight(for: section), frame.height)
        let y = max(frame.minY, frame.maxY - height)
        return NSRect(x: frame.minX, y: y, width: frame.width, height: height)
    }

    private func setDetailContentVisible(_ visible: Bool) {
        let alpha: CGFloat = visible ? 1 : 0
        detailHeaderView.animator().alphaValue = alpha
        detailBodyHost.animator().alphaValue = alpha
    }

    func showLibraryDetail() {
        guard requireProAccess(.playlists) else { return }
        showDetail(.library, from: libraryCard)
    }

    func showProSettings(for feature: ProFeature? = nil) {
        if let feature {
            proFeatureFocusLabel?.stringValue = "\(feature.title) is part of Pro. \(feature.explanation)"
        } else {
            proFeatureFocusLabel?.stringValue = "Unlock playlists, timers, lock screen sync, and smart rules."
        }
        showDetail(.pro, from: proFooterCardView ?? settingsCard)
    }

    private func resolveDetailSourceView(sender: Any?, fallback: NSView) -> NSView {
        var currentView = sender as? NSView
        while let view = currentView {
            if view is LiquidGlassCardView {
                return view
            }
            currentView = view.superview
        }
        return fallback
    }

    @objc func showPlaylistLibraryDetail(_ sender: Any?) {
        guard requireProAccess(.playlists) else { return }
        showDetail(.library, from: resolveDetailSourceView(sender: sender, fallback: playlistCard))
    }

    @objc private func showPlaylistDetail(_ sender: Any?) {
        guard requireProAccess(.playlists) else { return }
        showDetail(.library, from: resolveDetailSourceView(sender: sender, fallback: playlistCard))
    }

    @objc private func showAppDetail(_ sender: Any?) {
        showDetail(.app, from: resolveDetailSourceView(sender: sender, fallback: appHeaderCard ?? settingsCard))
    }

    @objc private func showPlayerDetail(_ sender: Any?) {
        showDetail(.player, from: resolveDetailSourceView(sender: sender, fallback: playerCardView))
    }

    func showPlayerDetailTest(completion: (() -> Void)? = nil) {
        showDetail(.player, from: playerCardView) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.dumpAndCapturePlayerDetail()
                completion?()
            }
        }
    }

    func showDisplayDetailTest(completion: (() -> Void)? = nil) {
        showDetail(.display, from: displayCard) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.dumpAndCapturePlayerDetail()
                completion?()
            }
        }
    }

    func showSettingsDetailTest(completion: (() -> Void)? = nil) {
        showDetail(.settings, from: settingsCard) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.dumpAndCapturePlayerDetail()
                completion?()
            }
        }
    }

    func showLibraryDetailTest(completion: (() -> Void)? = nil) {
        showDetail(.library, from: libraryCard) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.dumpAndCapturePlayerDetail()
                completion?()
            }
        }
    }

    func showProDetailTest(completion: (() -> Void)? = nil) {
        showDetail(.pro, from: proFooterCardView ?? settingsCard) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.dumpAndCapturePlayerDetail()
                completion?()
            }
        }
    }

    func showAppDetailTest(completion: (() -> Void)? = nil) {
        showDetail(.app, from: appHeaderCard ?? settingsCard) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.dumpAndCapturePlayerDetail()
                completion?()
            }
        }
    }

    func dumpAndCapturePlayerDetail() {
        var log = "=== PLAYER DETAIL DUMP ===\n"
        log += "detailCard frame: \(detailCard.frame), isHidden: \(detailCard.isHidden), alpha: \(detailCard.alphaValue)\n"
        log += "detailBodyHost frame: \(detailBodyHost.frame), isHidden: \(detailBodyHost.isHidden), alpha: \(detailBodyHost.alphaValue)\n"
        log += "playerDetailView frame: \(playerDetailView.frame), isHidden: \(playerDetailView.isHidden), alpha: \(playerDetailView.alphaValue)\n"
        
        for (idx, sub) in view.subviews.enumerated() {
            log += "  rootSub[\(idx)] (\(type(of: sub))) frame: \(sub.frame), isHidden: \(sub.isHidden), alpha: \(sub.alphaValue)\n"
        }
        
        for (idx, sub) in detailBodyHost.subviews.enumerated() {
            log += "  activeBody[\(idx)] (\(type(of: sub))) frame: \(sub.frame), isHidden: \(sub.isHidden), alpha: \(sub.alphaValue)\n"
            if let contentView = sub as? DismissibleContentView {
                for (cIdx, child) in contentView.subviews.enumerated() {
                    log += "    contentChild[\(cIdx)] (\(type(of: child))) frame: \(child.frame)\n"
                    if let stack = child as? NSStackView {
                        for (rIdx, row) in stack.arrangedSubviews.enumerated() {
                            log += "      arrangedRow[\(rIdx)] (\(type(of: row))) frame: \(row.frame)\n"
                        }
                    }
                }
            }
        }
        try? log.write(to: URL(fileURLWithPath: "/tmp/cinewall_debug.log"), atomically: true, encoding: .utf8)
        NSLog("[CineWall] Debug log saved to /tmp/cinewall_debug.log")

        detailCard.layoutSubtreeIfNeeded()
        let cardBounds = detailCard.bounds
        if cardBounds.width > 0 && cardBounds.height > 0 {
            if let rep = detailCard.bitmapImageRepForCachingDisplay(in: cardBounds) {
                detailCard.cacheDisplay(in: cardBounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/cinewall_card.png"))
                    NSLog("[CineWall] Saved /tmp/cinewall_card.png via cacheDisplay (%dx%d)", Int(cardBounds.width), Int(cardBounds.height))
                }
            }
            if !FileManager.default.fileExists(atPath: "/tmp/cinewall_card.png") {
                let image = NSImage(size: cardBounds.size)
                image.lockFocus()
                if let ctx = NSGraphicsContext.current?.cgContext {
                    detailCard.layer?.render(in: ctx)
                }
                image.unlockFocus()
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/cinewall_card.png"))
                    NSLog("[CineWall] Saved /tmp/cinewall_card.png via layer render (%dx%d)", Int(cardBounds.width), Int(cardBounds.height))
                }
            }
        }

        let viewBounds = view.bounds
        if viewBounds.width > 0 && viewBounds.height > 0 {
            if let rep = view.bitmapImageRepForCachingDisplay(in: viewBounds) {
                view.cacheDisplay(in: viewBounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/cinewall_verify.png"))
                    NSLog("[CineWall] Saved /tmp/cinewall_verify.png via cacheDisplay (%dx%d)", Int(viewBounds.width), Int(viewBounds.height))
                }
            }
            if !FileManager.default.fileExists(atPath: "/tmp/cinewall_verify.png") {
                let image = NSImage(size: viewBounds.size)
                image.lockFocus()
                if let ctx = NSGraphicsContext.current?.cgContext {
                    view.layer?.render(in: ctx)
                }
                image.unlockFocus()
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/cinewall_verify.png"))
                    NSLog("[CineWall] Saved /tmp/cinewall_verify.png via layer render (%dx%d)", Int(viewBounds.width), Int(viewBounds.height))
                }
            }
        }
    }

    func dumpAndCaptureMainMenu() {
        view.layoutSubtreeIfNeeded()
        let viewBounds = view.bounds
        if viewBounds.width > 0 && viewBounds.height > 0 {
            if let rep = view.bitmapImageRepForCachingDisplay(in: viewBounds) {
                view.cacheDisplay(in: viewBounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/cinewall_main_menu.png"))
                    NSLog("[CineWall] Saved /tmp/cinewall_main_menu.png via cacheDisplay (%dx%d)", Int(viewBounds.width), Int(viewBounds.height))
                }
            }
            if !FileManager.default.fileExists(atPath: "/tmp/cinewall_main_menu.png") {
                let image = NSImage(size: viewBounds.size)
                image.lockFocus()
                if let ctx = NSGraphicsContext.current?.cgContext {
                    view.layer?.render(in: ctx)
                }
                image.unlockFocus()
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/cinewall_main_menu.png"))
                    NSLog("[CineWall] Saved /tmp/cinewall_main_menu.png via layer render (%dx%d)", Int(viewBounds.width), Int(viewBounds.height))
                }
            }
        }
    }

    private func animateCardExpansion(from startFrame: NSRect, to targetFrame: NSRect, completion: (() -> Void)? = nil) {
        detailAnimationTimer?.invalidate()
        detailAnimationTimer = nil
        
        let spring = VorssaintMotion.codenotchUnfold
        let startTime = CACurrentMediaTime()
        let duration = VorssaintMotion.settlingTime(spring: spring)
        
        let initialRadius: CGFloat = (startFrame.height < 100) ? 26.0 : 24.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        detailCard.frame = startFrame
        detailCard.updateCornerRadius(initialRadius)
        detailHeaderView.alphaValue = 0.0
        detailBodyHost.alphaValue = 0.0
        detailCard.layoutSubtreeIfNeeded()
        CATransaction.commit()
        
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self = self else {
                t.invalidate()
                return
            }
            let elapsed = CACurrentMediaTime() - startTime
            if elapsed >= duration {
                t.invalidate()
                self.detailAnimationTimer = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.detailCard.frame = targetFrame
                self.detailCard.updateCornerRadius(30.0)
                self.detailHeaderView.alphaValue = 1.0
                self.detailBodyHost.alphaValue = 1.0
                self.mainStack.alphaValue = 0.0
                self.mainStack.isHidden = true
                self.detailCard.layoutSubtreeIfNeeded()
                CATransaction.commit()
                completion?()
            } else {
                let p = spring.progress(at: elapsed)
                let currentFrame = VorssaintMotion.interpolateRectUnified(from: startFrame, to: targetFrame, progress: p)
                
                // Corner radius interpolates smoothly from source card to target submenu
                let startRadius: CGFloat = (startFrame.height < 100) ? 26.0 : 24.0
                let targetRadius: CGFloat = 30.0
                let currentRadius = startRadius + (targetRadius - startRadius) * CGFloat(max(0.0, min(1.0, p)))
                
                // Main menu dissolves smoothly in lockstep as the card expands
                let mainAlpha = CGFloat(max(0.0, 1.0 - p / 0.45))
                
                // Header (back button and title) unfurls once the card is underway (p > 0.22)
                let headerAlpha = CGFloat(max(0.0, min(1.0, (p - 0.22) / 0.38)))
                
                // Submenu body controls unfurl as card nears full size (p > 0.38)
                let bodyAlpha = CGFloat(max(0.0, min(1.0, (p - 0.38) / 0.45)))
                
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.detailCard.frame = currentFrame
                self.detailCard.updateCornerRadius(currentRadius)
                self.detailHeaderView.alphaValue = headerAlpha
                self.detailBodyHost.alphaValue = bodyAlpha
                self.mainStack.alphaValue = mainAlpha
                self.detailCard.layoutSubtreeIfNeeded()
                CATransaction.commit()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        detailAnimationTimer = timer
    }

    private func animateCardCollapse(from startFrame: NSRect, to targetFrame: NSRect, completion: (() -> Void)? = nil) {
        detailAnimationTimer?.invalidate()
        detailAnimationTimer = nil
        
        let spring = VorssaintMotion.codenotchFold
        let startTime = CACurrentMediaTime()
        let duration = VorssaintMotion.settlingTime(spring: spring)
        
        self.mainStack.isHidden = false
        
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self = self else {
                t.invalidate()
                return
            }
            let elapsed = CACurrentMediaTime() - startTime
            if elapsed >= duration {
                t.invalidate()
                self.detailAnimationTimer = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.detailCard.frame = targetFrame
                let finalRadius: CGFloat = (targetFrame.height < 100) ? 26.0 : 24.0
                self.detailCard.updateCornerRadius(finalRadius)
                self.detailHeaderView.alphaValue = 0.0
                self.detailBodyHost.alphaValue = 0.0
                self.mainStack.alphaValue = 1.0
                self.detailCard.layoutSubtreeIfNeeded()
                CATransaction.commit()
                completion?()
            } else {
                let p = spring.progress(at: elapsed)
                let currentFrame = VorssaintMotion.interpolateRectUnified(from: startFrame, to: targetFrame, progress: p)
                
                // Corner radius contracts back to source card radius
                let startRadius: CGFloat = 30.0
                let targetRadius: CGFloat = (targetFrame.height < 100) ? 26.0 : 24.0
                let currentRadius = startRadius + (targetRadius - startRadius) * CGFloat(max(0.0, min(1.0, p)))
                
                // Controls dissolve quickly in the first 28% of collapse
                let contentAlpha = CGFloat(max(0.0, 1.0 - p / 0.28))
                
                // Main menu emerges smoothly in lockstep to catch the contracting card
                let mainAlpha = CGFloat(max(0.0, min(1.0, (p - 0.18) / 0.65)))
                
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.detailCard.frame = currentFrame
                self.detailCard.updateCornerRadius(currentRadius)
                self.detailHeaderView.alphaValue = contentAlpha
                self.detailBodyHost.alphaValue = contentAlpha
                self.mainStack.alphaValue = mainAlpha
                self.detailCard.layoutSubtreeIfNeeded()
                CATransaction.commit()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        detailAnimationTimer = timer
    }

    private func showDetail(_ section: DetailSection, from sourceView: NSView, completion: (() -> Void)? = nil) {
        updateDetailContent(for: section)
        activeDetail = section
        view.layoutSubtreeIfNeeded()
        sourceView.superview?.layoutSubtreeIfNeeded()
        detailOverlay.layoutSubtreeIfNeeded()
        let convertedSourceFrame = detailOverlay.convert(sourceView.bounds, from: sourceView)
        let overlayBounds = detailOverlay.bounds.insetBy(dx: -40, dy: -40)
        if sourceView.window == view.window,
           !convertedSourceFrame.isEmpty,
           convertedSourceFrame.intersects(overlayBounds) {
            detailSourceFrame = convertedSourceFrame
        } else {
            detailSourceFrame = detailTargetFrame(for: section)
        }
        detailOverlay.isHidden = false
        detailOverlay.alphaValue = 1
        
        detailCard.layer?.removeAllAnimations()
        detailBodyHost.layer?.removeAllAnimations()
        
        let initialRadius: CGFloat = (detailSourceFrame.height < 100) ? 26.0 : 24.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        detailCard.frame = detailSourceFrame
        detailCard.alphaValue = 1
        detailCard.updateCornerRadius(initialRadius)
        detailHeaderView.alphaValue = 0
        detailBodyHost.alphaValue = 0
        detailCard.layoutSubtreeIfNeeded()
        detailBodyHost.layoutSubtreeIfNeeded()
        CATransaction.commit()
        
        let targetFrame = detailTargetFrame(for: section)
        
        // Hide the main menu window background for all submenus so only the active submenu card is visible
        if let root = self.view as? LiquidView {
            root.setGlassOpacity(0.0)
        }
        detailCard.applyUserTintStrength(CGFloat(appDelegate?.menuDarkTintStrength ?? 0.0))

        animateCardExpansion(from: detailSourceFrame, to: targetFrame, completion: completion)
    }

    @objc private func hideDetailAction() {
        hideDetail()
    }

    private func hideDetail() {
        guard let activeDetail, !detailOverlay.isHidden else { return }

        let target = detailSourceFrame == .zero ? detailTargetFrame(for: activeDetail) : detailSourceFrame
        
        if let root = self.view as? LiquidView {
            root.setGlassOpacity(1.0)
        }

        let startFrame = self.detailCard.frame
        animateCardCollapse(from: startFrame, to: target) { [weak self] in
            self?.finishHideDetail()
        }
    }

    private func finishHideDetail() {
        detailAnimationTimer?.invalidate()
        detailAnimationTimer = nil
        self.detailOverlay.isHidden = true
        self.detailCard.alphaValue = 1
        self.activeDetail = nil
        self.detailSourceFrame = .zero
        self.mainStack.isHidden = false
        self.mainStack.alphaValue = 1.0
        if let root = self.view as? LiquidView {
            root.setGlassOpacity(1.0)
        }
        self.setDetailContentVisible(true)
        if let current = currentTrackThumbnail {
            self.thumbnailView.thumbnailImage = current
        }
    }
    
    func resetToMainMenu() {
        detailAnimationTimer?.invalidate()
        detailAnimationTimer = nil
        if !detailOverlay.isHidden {
            detailOverlay.isHidden = true
            detailCard.alphaValue = 1
            activeDetail = nil
            detailSourceFrame = .zero
            setDetailContentVisible(true)
            mainStack.isHidden = false
            mainStack.alphaValue = 1
            if let root = view as? LiquidView { root.setGlassOpacity(1.0) }
            if let current = currentTrackThumbnail {
                thumbnailView.thumbnailImage = current
            }
        }
    }

    func updateTrackInfo(title: String, image: NSImage?, isFav: Bool) {
        currentTrackThumbnail = image
        trackTitle.stringValue = title
        compactTrackMarquee?.stringValue = title
        let displayImg = image ?? NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        thumbnailView.thumbnailImage = displayImg
        expandedTrackTitle?.stringValue = title.isEmpty ? "Not Playing" : title
        expandedArtworkView?.thumbnailImage = displayImg
        updateSubtitle()
        updateFavIcon(isFav)
        updateSummaryLabels()
    }

    func updateSubtitle() {
        guard let app = appDelegate else {
            expandedTrackSubtitle?.stringValue = "Not Playing"
            return
        }
        if app.currentQueue.isEmpty {
            expandedTrackSubtitle?.stringValue = "Not Playing"
        } else if app.isPlaylistFilterEnabled {
            expandedTrackSubtitle?.stringValue = app.selectedPlaylistName
        } else {
            expandedTrackSubtitle?.stringValue = "CineWall"
        }
    }
    
    func updateTimeLabels(elapsed: Double, duration: Double) {
        if elapsed.isNaN || duration.isNaN { return }
        let eMin = Int(elapsed) / 60
        let eSec = Int(elapsed) % 60
        let rem = max(0, duration - elapsed)
        let rMin = Int(rem) / 60
        let rSec = Int(rem) % 60
        
        playerElapsedLabel?.stringValue = String(format: "%d:%02d", eMin, eSec)
        playerRemainingLabel?.stringValue = String(format: "-%d:%02d", rMin, rSec)
    }

    func updateFavIcon(_ isFav: Bool) {
        favButton.image = NSImage(systemSymbolName: isFav ? "heart.fill" : "heart", accessibilityDescription: nil)
        favButton.contentTintColor = isFav ? .systemRed : .white
        expandedFavButton?.image = NSImage(systemSymbolName: isFav ? "heart.fill" : "heart", accessibilityDescription: nil)
        expandedFavButton?.contentTintColor = isFav ? .systemRed : .white
        expandedFavButton?.isHidden = !isFav
    }

    func refreshUI() {
        guard let app = appDelegate else { return }

        if let current = currentTrackThumbnail {
            thumbnailView.thumbnailImage = current
            expandedArtworkView?.thumbnailImage = current
        }

        let isPaused = app.isManualPaused
        playButton.image = NSImage(systemSymbolName: isPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        let playConfig = NSImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        expandedPlayButton?.image = NSImage(systemSymbolName: isPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil)?.withSymbolConfiguration(playConfig)
        updateSubtitle()

        let vol = app.volumeLevel
        let iconName: String
        if app.isMuted || vol == 0 {
            iconName = "speaker.slash.fill"
        } else if vol < 0.3 {
            iconName = "speaker.wave.1.fill"
        } else if vol < 0.7 {
            iconName = "speaker.wave.2.fill"
        } else {
            iconName = "speaker.wave.3.fill"
        }

        volButton.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        volSlider.floatValue = vol

        shuffleBtn?.contentTintColor = app.isShuffle ? .systemBlue : .white
        loopBtn?.contentTintColor = app.isLoopingCurrent ? .systemBlue : .white
        playlistToggleButton?.contentTintColor = app.isPlaylistFilterEnabled ? .systemBlue : .white

        pinButton.image = NSImage(systemSymbolName: app.isPinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        pinButton.contentTintColor = app.isPinned ? .systemBlue : .white.withAlphaComponent(0.75)

        let totalSeconds = max(0, Int(app.autoChangeInterval))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        timerHoursField?.stringValue = String(format: "%02d", hours)
        timerMinutesField?.stringValue = String(format: "%02d", minutes)
        timerSecondsField?.stringValue = String(format: "%02d", seconds)
        timerLabel.stringValue = totalSeconds == 0 ? "Off" : formattedTimerText(totalSeconds: totalSeconds)
        scalingSeg.selectedSegment = app.scalingTag - 1

        smartPauseToggle.state = app.smartPauseEnabled ? .on : .off
        batterySaverToggle.state = app.batterySaverEnabled ? .on : .off
        focusPauseToggle.state = app.focusPauseEnabled ? .on : .off
        focusMuteToggle.state = app.focusMuteEnabled ? .on : .off
        hideIconsToggle.state = app.hideDesktopIcons ? .on : .off
        allSpacesToggle.state = app.showOnAllSpaces ? .on : .off
        loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
        lockScreenEnabledToggle.state = app.lockScreenSyncEnabled ? .on : .off
        autoIdleSyncToggle.state = app.autoSyncIdleWallpaper ? .on : .off
        restoreOnQuitToggle?.state = app.restoreWallpaperOnQuit ? .on : .off
        let isSyncing = app.idleWallpaperSyncInProgress
        idleSyncButton.title = isSyncing ? "Syncing Lock Screen..." : "Sync Current to Lock Screen"
        idleSyncButton.isEnabled = !isSyncing
        restoreWallpaperButton?.isEnabled = !isSyncing
        idleSyncStatusLabel?.stringValue = app.lockScreenSyncEnabled
            ? (isSyncing ? "Syncing lock screen across all displays..." : "Lock screen synced across all displays.")
            : "Lock screen sync is turned off."
        menuTintSlider?.doubleValue = app.menuDarkTintStrength
        menuTintValueLabel?.stringValue = "\(Int((app.menuDarkTintStrength * 100).rounded()))%"
        ambientGlowToggle?.state = app.ambientTintEnabled ? .on : .off
        spanDisplaysToggle?.state = app.spanDisplaysEnabled ? .on : .off
        updatesStatusLabel?.stringValue = app.currentUpdateDescription()
        applyMenuTintStrength(CGFloat(app.menuDarkTintStrength))
        applyAmbientColors(primary: app.currentAmbientPrimary, secondary: app.currentAmbientSecondary)

        playlistTableView?.reloadData()
        libraryPlaylistTableView?.reloadData()
        playlistItemsTableView?.reloadData()
        if let selectedIndex = app.orderedPlaylistNames().firstIndex(of: app.selectedPlaylistName) {
            playlistTableView?.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            libraryPlaylistTableView?.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }
        updatePlaylistSelectionUI()
        updateSummaryLabels()
        updateProVisibility()
    }

    func updateStats() {
        guard let app = appDelegate else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0"
        let cpuText = String(format: "%.1f", app.getAppCPU())
        let ramText = app.getAppRAM()
        appHeaderSubtitleLabel?.stringValue = "CPU \(cpuText)% • RAM \(ramText)"
        cpuLabel?.stringValue = "CPU \(cpuText)%"
        ramLabel?.stringValue = "RAM \(ramText)"
    }

    private func updatePillButton(_ button: NSButton, active: Bool) {
        if let glassBtn = button as? LiquidGlassButton {
            glassBtn.setActive(active)
            return
        }
        button.layer?.backgroundColor = (active ? NSColor.systemBlue.withAlphaComponent(0.28) : NSColor.black.withAlphaComponent(0.08)).cgColor
        button.layer?.borderColor = (active ? NSColor.white.withAlphaComponent(0.18) : NSColor.white.withAlphaComponent(0.10)).cgColor
        button.contentTintColor = .white
    }

    private func applyMenuTintStrength(_ strength: CGFloat) {
        if let root = view as? LiquidView {
            root.applyUserTintStrength(strength)
        }
        applyMenuTintStrengthRecursively(in: view, strength: strength)
    }

    private func applyMenuTintStrengthRecursively(in view: NSView, strength: CGFloat) {
        if let card = view as? LiquidGlassCardView {
            card.applyUserTintStrength(strength)
        }
        for subview in view.subviews {
            applyMenuTintStrengthRecursively(in: subview, strength: strength)
        }
    }

    private func updateCircleButtonSymbol(_ button: NSButton?, icon: String, pointSize: CGFloat = 12) {
        guard let button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        button.title = ""
        button.imagePosition = .imageOnly
    }

    private func updatePlaylistSelectionUI() {
        playlistItemsTableView?.allowsMultipleSelection = isSelectingPlaylistVideos
        updateCircleButtonSymbol(librarySelectVideosButton, icon: isSelectingPlaylistVideos ? "checkmark" : "checklist")
        librarySelectVideosButton?.toolTip = isSelectingPlaylistVideos ? "Done selecting videos" : "Select videos"
        updatePillButton(librarySelectVideosButton, active: isSelectingPlaylistVideos)
        let hasSelection = playlistItemsTableView?.selectedRowIndexes.isEmpty == false
        libraryRemoveSelectedButton?.isHidden = !isSelectingPlaylistVideos
        libraryRemoveSelectedButton?.isEnabled = hasSelection
        libraryRemoveSelectedButton?.toolTip = hasSelection ? "Remove selected videos" : "Select videos to remove"
        libraryRemoveSelectedButton?.alphaValue = hasSelection ? 1 : 0.55
    }

    @objc func togglePlay() { appDelegate?.isManualPaused.toggle(); appDelegate?.saveSettings(); appDelegate?.updatePlaybackState() }
    @objc func togglePin() { appDelegate?.togglePin(); refreshUI() }
    @objc func doNext() { appDelegate?.nextFile() }
    @objc func doPrev() { appDelegate?.prevFile() }
    @objc func seekVideo() { appDelegate?.seekTo(percentage: progressSlider.doubleValue) }
    @objc func toggleFav() { appDelegate?.toggleFavorite() }
    @objc func togglePlaylistMode() {
        guard requireProAccess(.playlists) else { return }
        appDelegate?.toggleSelectedPlaylistFilter()
    }
    @objc func volumeChanged() { appDelegate?.volumeLevel = volSlider.floatValue; appDelegate?.isMuted = volSlider.floatValue == 0; appDelegate?.saveSettings(); appDelegate?.updatePlaybackState(); refreshUI() }
    @objc func toggleMute() { appDelegate?.toggleMuteState() }
    @objc func toggleShuffle() { appDelegate?.isShuffle.toggle(); appDelegate?.saveSettings(); appDelegate?.refreshQueue(); refreshUI() }
    @objc func toggleLoop() { appDelegate?.isLoopingCurrent.toggle(); appDelegate?.saveSettings(); appDelegate?.resetPlaylistTimer(); refreshUI() }
    @objc func pickFolder() { appDelegate?.selectFolder() }
    @objc func pickFile() { appDelegate?.selectSingleVideo() }
    @objc func createPlaylist() {
        guard requireProAccess(.playlists) else { return }
        appDelegate?.promptForNewPlaylist()
    }
    @objc func toggleCreatePlaylistEditor() {
        guard requireProAccess(.playlists) else { return }
        let shouldShow = libraryCreatePlaylistRow?.isHidden ?? true
        libraryCreatePlaylistRow?.isHidden = !shouldShow
        if shouldShow {
            libraryCreatePlaylistField?.stringValue = ""
            libraryCreatePlaylistField?.placeholderString = "Playlist name"
            view.window?.makeFirstResponder(libraryCreatePlaylistField)
        }
    }
    @objc func confirmCreatePlaylist() {
        guard requireProAccess(.playlists) else { return }
        guard let app = appDelegate,
              let name = libraryCreatePlaylistField?.stringValue else { return }
        guard app.createPlaylist(named: name) else {
            libraryCreatePlaylistField?.stringValue = ""
            libraryCreatePlaylistField?.placeholderString = "Use a unique name"
            view.window?.makeFirstResponder(libraryCreatePlaylistField)
            return
        }
        libraryCreatePlaylistRow?.isHidden = true
    }
    @objc func cancelCreatePlaylist() {
        libraryCreatePlaylistRow?.isHidden = true
        libraryCreatePlaylistField?.stringValue = ""
    }
    @objc func addVideosToPlaylist() {
        guard requireProAccess(.playlists) else { return }
        appDelegate?.importVideosToSelectedPlaylist()
    }
    @objc func deletePlaylist() {
        guard requireProAccess(.playlists) else { return }
        guard let app = appDelegate, app.selectedPlaylistName != AppDelegate.favoritesPlaylistName else { return }
        app.deletePlaylist(named: app.selectedPlaylistName)
    }
    @objc func clearPlaylist() {
        guard requireProAccess(.playlists) else { return }
        appDelegate?.clearPlaylist(named: appDelegate?.selectedPlaylistName ?? AppDelegate.favoritesPlaylistName)
    }
    @objc func deleteOrClearPlaylist() {
        guard requireProAccess(.playlists) else { return }
        guard let app = appDelegate else { return }
        if app.selectedPlaylistName == AppDelegate.favoritesPlaylistName {
            app.clearPlaylist(named: app.selectedPlaylistName)
        } else {
            app.deletePlaylist(named: app.selectedPlaylistName)
        }
    }
    @objc func toggleVideoSelectionMode() {
        guard requireProAccess(.playlists) else { return }
        isSelectingPlaylistVideos.toggle()
        playlistItemsTableView?.allowsMultipleSelection = isSelectingPlaylistVideos
        if !isSelectingPlaylistVideos {
            playlistItemsTableView?.deselectAll(nil)
        }
        updatePlaylistSelectionUI()
    }
    @objc func removeSelectedPlaylistVideos() {
        guard requireProAccess(.playlists) else { return }
        guard isSelectingPlaylistVideos, let app = appDelegate else { return }
        let entries = app.playlistEntries(named: app.selectedPlaylistName)
        let indexes = playlistItemsTableView.selectedRowIndexes
        guard !indexes.isEmpty else { return }
        for index in indexes.reversed() where index < entries.count {
            let path = entries[index]
            if app.selectedPlaylistName == AppDelegate.favoritesPlaylistName {
                app.removeFavorite(path: path)
            } else {
                app.removeVideo(path: path, fromPlaylist: app.selectedPlaylistName)
            }
        }
        app.saveSettings()
        if app.isPlaylistFilterEnabled {
            app.refreshQueue()
            app.startPlayback()
        } else {
            app.liquidController?.refreshUI()
        }
        playlistItemsTableView.deselectAll(nil)
        updatePlaylistSelectionUI()
    }
    @objc func showList(_ sender: Any?) {
        guard requireProAccess(.playlists) else { return }
        showDetail(.library, from: resolveDetailSourceView(sender: sender, fallback: libraryCard))
    }
    @objc func showDisplayDetail(_ sender: Any?) { showDetail(.display, from: resolveDetailSourceView(sender: sender, fallback: displayCard)) }
    @objc func showSettingsDetail(_ sender: Any?) { showDetail(.settings, from: resolveDetailSourceView(sender: sender, fallback: settingsCard)) }
    @objc func showProSettingsAction() { showProSettings() }
    @objc func openGitHubAction() {
        if let url = URL(string: "https://github.com/saivinay1805/CineWall") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func openIssuesAction() {
        if let url = URL(string: "https://github.com/saivinay1805/CineWall/issues") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func openReleasesAction() {
        if let url = URL(string: "https://github.com/saivinay1805/CineWall/releases") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func checkForUpdatesAction() { appDelegate?.checkForUpdates() }
    @objc func openWebsiteAction() { appDelegate?.openProCheckout() }
    @objc func doBring() { appDelegate?.bringToCurrentDesktop() }
    @objc func doQuit() { appDelegate?.terminateApp() }
    @objc func syncIdleWallpaper() {
        guard requireProAccess(.lockScreenSync) else { return }
        appDelegate?.syncCurrentVideoToIdleWallpaper()
    }
    @objc func restoreDefaultWallpaper() {
        appDelegate?.restoreSystemWallpaperFromLockScreen()
    }
    @objc func revealFile() { appDelegate?.revealCurrentInFinder() }
    @objc func selectPlaylistFromTable(_ sender: Any?) {
        guard requireProAccess(.playlists) else { return }
        let tableView = (sender as? NSTableView) ?? (NSApp.keyWindow?.firstResponder as? NSTableView)
        let row = tableView?.clickedRow ?? -1
        let resolvedRow = row >= 0 ? row : (tableView?.selectedRow ?? -1)
        guard resolvedRow >= 0, let app = appDelegate else { return }
        let names = app.orderedPlaylistNames()
        guard resolvedRow < names.count else { return }
        app.setSelectedPlaylist(names[resolvedRow])
    }
    @objc func showAddToPlaylistMenu(_ sender: NSButton) {
        guard requireProAccess(.playlists) else { return }
        guard let app = appDelegate, !app.currentQueue.isEmpty else { return }
        let currentPath = app.currentQueue[app.queueIndex].path
        let menu = NSMenu()
        for name in app.orderedPlaylistNames() {
            let item = NSMenuItem(title: name, action: #selector(toggleCurrentVideoPlaylist(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = app.containsVideo(path: currentPath, inPlaylist: name) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }
    @objc func toggleCurrentVideoPlaylist(_ sender: NSMenuItem) {
        guard requireProAccess(.playlists) else { return }
        guard let name = sender.representedObject as? String,
              let app = appDelegate,
              !app.currentQueue.isEmpty else { return }
        let currentPath = app.currentQueue[app.queueIndex].path
        app.toggleVideo(path: currentPath, inPlaylist: name)
    }

    @objc func showPlayerMoreMenu(_ sender: NSButton) {
        guard let app = appDelegate else { return }
        let menu = NSMenu()
        
        let hasVideo = !app.currentQueue.isEmpty
        let currentPath = hasVideo ? app.currentQueue[app.queueIndex].path : nil
        let isFav = currentPath != nil && app.containsVideo(path: currentPath!, inPlaylist: "Favorites")
        
        let favItem = NSMenuItem(
            title: isFav ? "Remove from Favorites" : "Add to Favorites",
            action: #selector(toggleFav),
            keyEquivalent: ""
        )
        favItem.image = NSImage(systemSymbolName: isFav ? "heart.fill" : "heart", accessibilityDescription: nil)
        favItem.target = self
        menu.addItem(favItem)
        
        let playlistItem = NSMenuItem(
            title: "Add to Playlist...",
            action: #selector(showAddToPlaylistFromMore),
            keyEquivalent: ""
        )
        playlistItem.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil)
        playlistItem.target = self
        menu.addItem(playlistItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let revealItem = NSMenuItem(
            title: "Reveal in Finder",
            action: #selector(revealFile),
            keyEquivalent: ""
        )
        revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        revealItem.target = self
        revealItem.isEnabled = hasVideo
        menu.addItem(revealItem)
        
        let copyItem = NSMenuItem(
            title: "Copy Video Path",
            action: #selector(copyCurrentVideoPath),
            keyEquivalent: ""
        )
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyItem.target = self
        copyItem.isEnabled = hasVideo
        menu.addItem(copyItem)
        
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func showAddToPlaylistFromMore() {
        showAddToPlaylistMenu(expandedMoreButton ?? addToPlaylistButton)
    }

    @objc func copyCurrentVideoPath() {
        guard let app = appDelegate, !app.currentQueue.isEmpty else { return }
        let path = app.currentQueue[app.queueIndex].path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "CineWall v3.0 (Tahoe Edition)"
        alert.informativeText = "Version 3.0 • Open Source\n\nThe native video wallpaper engine for macOS.\n\nFree and open source under the MIT License.\n\nhttps://github.com/saivinay1805/CineWall"
        alert.icon = NSImage(named: "AppIcon")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Star on GitHub (24★)")
        if alert.runModal() == .alertSecondButtonReturn {
            openGitHubAction()
        }
    }
    @objc func startTrialAction() {
        guard let app = appDelegate else { return }
        proFeatureFocusLabel?.stringValue = "Checking trial availability…"
        app.startProTrial { [weak self] success, message in
            self?.proFeatureFocusLabel?.stringValue = message
            if success == false {
                self?.refreshUI()
            }
        }
        refreshUI()
    }
    @objc func activateLicenseFromField() {
        let key = proLicenseField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            proLicenseField?.placeholderString = "Enter a valid license key"
            return
        }
        appDelegate?.activateLicenseKey(key)
    }

    @objc func pasteLicenseFromClipboard() {
        let key = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            proLicenseField?.placeholderString = "Clipboard does not contain a license key"
            return
        }
        proLicenseField?.stringValue = key
        view.window?.makeFirstResponder(proLicenseField)
    }
    #if DEBUG
    @objc func toggleDeveloperProAction() {
        appDelegate?.toggleDeveloperProUnlock()
        if appDelegate?.proManager.isDeveloperUnlocked == true {
            proFeatureFocusLabel?.stringValue = "Developer unlock is active for this local build."
        } else {
            proFeatureFocusLabel?.stringValue = "Developer unlock was turned off."
        }
        refreshUI()
    }

    @objc func resetDebugProTrialAction() {
        proFeatureFocusLabel?.stringValue = "Resetting local Debug Pro/trial state…"
        appDelegate?.resetDebugProTrialState { [weak self] success, message in
            if success {
                self?.proLicenseField?.stringValue = ""
            }
            self?.proFeatureFocusLabel?.stringValue = message
            self?.refreshUI()
        }
    }
    #endif

    @objc func timerChanged() {
        let hours = max(0, Int(timerHoursField?.stringValue ?? "") ?? 0)
        let minutes = max(0, min(59, Int(timerMinutesField?.stringValue ?? "") ?? 0))
        let seconds = max(0, min(59, Int(timerSecondsField?.stringValue ?? "") ?? 0))
        let totalSeconds = (hours * 3600) + (minutes * 60) + seconds
        if totalSeconds > 0 && !requireProAccess(.timer) {
            timerHoursField?.stringValue = "00"
            timerMinutesField?.stringValue = "00"
            timerSecondsField?.stringValue = "00"
            timerLabel.stringValue = "Off"
            return
        }

        timerHoursField?.stringValue = String(format: "%02d", hours)
        timerMinutesField?.stringValue = String(format: "%02d", minutes)
        timerSecondsField?.stringValue = String(format: "%02d", seconds)
        timerLabel.stringValue = totalSeconds == 0 ? "Off" : formattedTimerText(totalSeconds: totalSeconds)

        appDelegate?.autoChangeInterval = Double(totalSeconds)
        appDelegate?.saveSettings()
        appDelegate?.resetPlaylistTimer()
        updateSummaryLabels()
    }

    @objc func applyTimerPreset(_ sender: NSButton) {
        let totalSeconds = max(0, sender.tag)
        if totalSeconds > 0 && !requireProAccess(.timer) {
            return
        }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        timerHoursField?.stringValue = String(format: "%02d", hours)
        timerMinutesField?.stringValue = String(format: "%02d", minutes)
        timerSecondsField?.stringValue = String(format: "%02d", seconds)
        timerChanged()
    }

    @objc func scaleChanged() {
        appDelegate?.scalingTag = scalingSeg.selectedSegment + 1
        appDelegate?.saveSettings()
        appDelegate?.updateScalingMode()
        updateSummaryLabels()
    }

    @objc func togSmart() {
        guard requireProAccess(.smartSettings) else { refreshUI(); return }
        appDelegate?.smartPauseEnabled.toggle(); saveUp()
    }
    @objc func togBattery() {
        guard requireProAccess(.smartSettings) else { refreshUI(); return }
        appDelegate?.batterySaverEnabled.toggle(); saveUp()
    }
    @objc func togFocusP() {
        guard requireProAccess(.smartSettings) else { refreshUI(); return }
        appDelegate?.focusPauseEnabled.toggle(); saveUp()
    }
    @objc func togFocusM() {
        guard requireProAccess(.smartSettings) else { refreshUI(); return }
        appDelegate?.focusMuteEnabled.toggle(); saveUp()
    }
    @objc func togIcons() { appDelegate?.hideDesktopIcons.toggle(); appDelegate?.applyWindowLevel(); saveUp() }
    @objc func togAmbientTint() {
        guard let app = appDelegate else { return }
        app.ambientTintEnabled.toggle()
        app.saveSettings()
        applyAmbientColors(primary: app.currentAmbientPrimary, secondary: app.currentAmbientSecondary)
        refreshUI()
    }
    @objc func togSpanDisplays() {
        guard let app = appDelegate else { return }
        app.spanDisplaysEnabled.toggle()
        app.saveSettings()
        app.updateDisplaySpanLayout()
        refreshUI()
    }

    func applyAmbientColors(primary: NSColor?, secondary: NSColor?) {
        let enabled = appDelegate?.ambientTintEnabled ?? true
        detailCard?.applyAmbientColor(primary: primary, secondary: secondary, enabled: enabled)
        func updateCards(in view: NSView) {
            if let card = view as? LiquidGlassCardView {
                card.applyAmbientColor(primary: primary, secondary: secondary, enabled: enabled)
            }
            for sub in view.subviews {
                updateCards(in: sub)
            }
        }
        if let mainStack = mainStack {
            updateCards(in: mainStack)
        }
    }
    @objc func togSpaces() {
        appDelegate?.showOnAllSpaces.toggle()
        appDelegate?.saveSettings()
        appDelegate?.wallpaperWindows.forEach { $0.collectionBehavior = (appDelegate?.showOnAllSpaces ?? false) ? [.canJoinAllSpaces, .stationary, .ignoresCycle] : [.stationary, .ignoresCycle] }
        appDelegate?.updatePlaybackState()
        updateSummaryLabels()
    }
    @objc func togLogin() {
        let service = SMAppService.mainApp
        try? (service.status == .enabled ? service.unregister() : service.register())
        loginToggle.state = service.status == .enabled ? .on : .off
    }
    @objc func togLockScreenSyncEnabled() {
        guard requireProAccess(.lockScreenSync) else { refreshUI(); return }
        appDelegate?.lockScreenSyncEnabled.toggle()
        if appDelegate?.lockScreenSyncEnabled == false {
            appDelegate?.autoSyncIdleWallpaper = false
        }
        appDelegate?.saveSettings()
        appDelegate?.scheduleIdleWallpaperSyncIfNeeded()
        refreshUI()
    }
    @objc func togAutoIdleSync() {
        guard requireProAccess(.lockScreenSync) else { refreshUI(); return }
        appDelegate?.autoSyncIdleWallpaper.toggle(); appDelegate?.saveSettings(); appDelegate?.scheduleIdleWallpaperSyncIfNeeded(); refreshUI()
    }
    @objc func togRestoreOnQuit() {
        guard let app = appDelegate else { return }
        app.restoreWallpaperOnQuit.toggle()
        app.saveSettings()
        refreshUI()
    }
    @objc func menuTintChanged() {
        let value = menuTintSlider.doubleValue
        appDelegate?.menuDarkTintStrength = value
        appDelegate?.saveSettings()
        menuTintValueLabel?.stringValue = "\(Int((value * 100).rounded()))%"
        applyMenuTintStrength(CGFloat(value))
    }

    func saveUp() {
        appDelegate?.saveSettings()
        appDelegate?.updatePlaybackState()
        refreshUI()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let app = appDelegate else { return 0 }
        if tableView == playlistTableView || tableView == libraryPlaylistTableView {
            return app.orderedPlaylistNames().count
        }
        return app.playlistEntries(named: app.selectedPlaylistName).count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        30
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LiquidTableRowView()
    }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        guard tableView == playlistItemsTableView, isSelectingPlaylistVideos else {
            return proposedSelectionIndexes
        }
        var next = tableView.selectedRowIndexes
        for index in proposedSelectionIndexes {
            if next.contains(index) {
                next.remove(index)
            } else {
                next.insert(index)
            }
        }
        return next
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView == playlistItemsTableView {
            updatePlaylistSelectionUI()
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let app = appDelegate else { return nil }

        let cell = NSTableCellView()
        let text: String
        let isSelectedPlaylistRow: Bool
        if tableView == playlistTableView || tableView == libraryPlaylistTableView {
            let names = app.orderedPlaylistNames()
            guard row < names.count else { return nil }
            let name = names[row]
            let count = app.playlistEntries(named: name).count
            text = name == app.selectedPlaylistName ? "\(name) • \(count) videos • Selected" : "\(name) • \(count) videos"
            isSelectedPlaylistRow = (name == app.selectedPlaylistName)
        } else {
            let entries = app.playlistEntries(named: app.selectedPlaylistName)
            guard row < entries.count else { return nil }
            text = URL(fileURLWithPath: entries[row]).lastPathComponent
            isSelectedPlaylistRow = false
        }

        let label = NSTextField(labelWithString: text)
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 12.5, weight: isSelectedPlaylistRow ? .semibold : .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    @objc func itemDoubleClicked() {
        guard requireProAccess(.playlists) else { return }
        guard !isSelectingPlaylistVideos else { return }
        let row = playlistItemsTableView.clickedRow >= 0 ? playlistItemsTableView.clickedRow : playlistItemsTableView.selectedRow
        guard row >= 0 else { return }
        appDelegate?.playPlaylistItem(at: row)
    }

    @objc func deleteItem() {
        guard requireProAccess(.playlists) else { return }
        let row = playlistItemsTableView.clickedRow >= 0 ? playlistItemsTableView.clickedRow : playlistItemsTableView.selectedRow
        guard row >= 0, let app = appDelegate else { return }
        let entries = app.playlistEntries(named: app.selectedPlaylistName)
        guard row < entries.count else { return }
        let path = entries[row]
        if app.selectedPlaylistName == AppDelegate.favoritesPlaylistName {
            app.removeFavorite(path: path)
        } else {
            app.removeVideo(path: path, fromPlaylist: app.selectedPlaylistName)
            app.saveSettings()
            app.liquidController?.refreshUI()
            if app.isPlaylistFilterEnabled {
                app.refreshQueue()
                app.startPlayback()
            }
        }
    }
}
