import Cocoa
import QuartzCore

// MARK: - GLASS COMPONENTS
class LiquidPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        hasShadow = false
        isMovableByWindowBackground = false
    }
}

class LiquidView: NSView {
    var onDrop: ((URL) -> Void)?

    private let strokeLayer = CALayer()
    private let tintLayer = CALayer()
    private let refractionLayer = CAGradientLayer()
    private var baseTintAlpha: CGFloat = 0.12
    private var userTintStrength: CGFloat = 0.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupGlass()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    private func setupGlass() {
        wantsLayer = true
        layer?.cornerRadius = 30
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        installGlassEffect(into: self, cornerRadius: 30, style: 1, blendWithinWindow: false)

        tintLayer.backgroundColor = NSColor.black.withAlphaComponent(baseTintAlpha).cgColor
        layer?.addSublayer(tintLayer)

        refractionLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.04).cgColor,
            NSColor.clear.cgColor,
            NSColor.cyan.withAlphaComponent(0.02).cgColor,
            NSColor.clear.cgColor
        ]
        refractionLayer.locations = [0.0, 0.4, 0.6, 0.8, 1.0]
        refractionLayer.startPoint = CGPoint(x: 0, y: 0.12)
        refractionLayer.endPoint = CGPoint(x: 1, y: 0.88)
        refractionLayer.opacity = 0.5
        layer?.addSublayer(refractionLayer)

        strokeLayer.borderWidth = 1
        strokeLayer.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        strokeLayer.shadowColor = NSColor.white.withAlphaComponent(0.18).cgColor
        strokeLayer.shadowOpacity = 0.4
        strokeLayer.shadowRadius = 12
        strokeLayer.shadowOffset = .zero
        layer?.addSublayer(strokeLayer)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        refractionLayer.frame = bounds.insetBy(dx: -26, dy: -26)
        strokeLayer.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        strokeLayer.cornerRadius = 30
        CATransaction.commit()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let item = sender.draggingPasteboard.pasteboardItems?.first,
              let str = item.string(forType: .fileURL),
              let url = URL(string: str) else {
            return false
        }
        onDrop?(url)
        return true
    }

    func setGlassOpacity(_ opacity: Float) {
        if opacity > 0 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.strokeLayer.isHidden = false
            self.tintLayer.isHidden = false
            self.refractionLayer.isHidden = false
            CATransaction.commit()
            for subview in self.subviews {
                if subview is NSVisualEffectView || String(describing: type(of: subview)).contains("Glass") {
                    subview.isHidden = false
                }
            }
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.strokeLayer.opacity = opacity
            self.tintLayer.opacity = opacity
            self.refractionLayer.opacity = opacity * 0.5
            for subview in self.subviews {
                if subview is NSVisualEffectView || String(describing: type(of: subview)).contains("Glass") {
                    subview.animator().alphaValue = CGFloat(opacity)
                }
            }
        }, completionHandler: {
            if opacity == 0 {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.strokeLayer.isHidden = true
                self.tintLayer.isHidden = true
                self.refractionLayer.isHidden = true
                CATransaction.commit()
                for subview in self.subviews {
                    if subview is NSVisualEffectView || String(describing: type(of: subview)).contains("Glass") {
                        subview.isHidden = true
                    }
                }
            }
        })
    }

    func applyUserTintStrength(_ strength: CGFloat) {
        userTintStrength = max(0, min(1, strength))
        let alpha = min(0.65, baseTintAlpha + (userTintStrength * 0.30))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
        CATransaction.commit()
    }
}

class LiquidGlassCardView: NSView {
    let contentView = NSView()

    private let strokeLayer = CALayer()
    private let tintLayer = CALayer()
    private let glowLayer = CAGradientLayer()
    private let refractionLayer = CAGradientLayer()
    private var baseTintAlpha: CGFloat = 0.05
    private var userTintStrength: CGFloat = 0.0

    init(cornerRadius: CGFloat = 24, tintAlpha: CGFloat = 0.03, useGlassEffect: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        if useGlassEffect {
            installGlassEffect(into: self, cornerRadius: cornerRadius, style: 1, blendWithinWindow: true)
        }

        tintLayer.backgroundColor = NSColor.black.withAlphaComponent(baseTintAlpha).cgColor
        layer?.addSublayer(tintLayer)

        glowLayer.colors = [
            NSColor.white.withAlphaComponent(0.12).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
            NSColor.clear.cgColor
        ]
        glowLayer.locations = [0, 0.18, 0.8]
        glowLayer.opacity = 0
        layer?.addSublayer(glowLayer)

        refractionLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.10).cgColor,
            NSColor.clear.cgColor,
            NSColor.cyan.withAlphaComponent(0.05).cgColor,
            NSColor.clear.cgColor
        ]
        refractionLayer.locations = [0.0, 0.18, 0.42, 0.68, 1.0]
        refractionLayer.startPoint = CGPoint(x: 0, y: 0.15)
        refractionLayer.endPoint = CGPoint(x: 1, y: 0.85)
        refractionLayer.opacity = 0.12
        layer?.addSublayer(refractionLayer)

        strokeLayer.borderWidth = 1
        strokeLayer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        strokeLayer.shadowColor = NSColor.black.withAlphaComponent(0.12).cgColor
        strokeLayer.shadowOpacity = 0.3
        strokeLayer.shadowRadius = 8
        strokeLayer.shadowOffset = .zero
        layer?.addSublayer(strokeLayer)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        glowLayer.frame = bounds
        refractionLayer.frame = bounds.insetBy(dx: -18, dy: -18)
        strokeLayer.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        strokeLayer.cornerRadius = layer?.cornerRadius ?? 24
        CATransaction.commit()
    }

    func configureGlassAccents(glowOpacity: Float, refractionOpacity: Float, tintOpacity: Float = 1.0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.opacity = glowOpacity
        refractionLayer.opacity = refractionOpacity
        tintLayer.opacity = tintOpacity
        CATransaction.commit()
    }

    func configureNeutralGlass(tintAlpha: CGFloat = 0.06,
                               glowOpacity: Float = 0.0,
                               refractionOpacity: Float = 0.12) {
        baseTintAlpha = tintAlpha
        let effectiveAlpha = min(0.55, baseTintAlpha + (userTintStrength * 0.22))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.backgroundColor = NSColor.black.withAlphaComponent(effectiveAlpha).cgColor
        glowLayer.opacity = glowOpacity
        refractionLayer.opacity = refractionOpacity
        CATransaction.commit()
    }

    func configureAsPureGlass() {
        baseTintAlpha = 0.0
        let tintAlpha = min(0.12, userTintStrength * 0.08)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.backgroundColor = NSColor.black.withAlphaComponent(tintAlpha).cgColor
        glowLayer.opacity = 0
        refractionLayer.opacity = 0.05
        strokeLayer.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        strokeLayer.shadowColor = NSColor.black.withAlphaComponent(0.08).cgColor
        strokeLayer.shadowOpacity = 0.22
        strokeLayer.shadowRadius = 7
        CATransaction.commit()
    }

    func applyUserTintStrength(_ strength: CGFloat) {
        userTintStrength = max(0, min(1, strength))
        let effectiveAlpha = min(0.55, baseTintAlpha + (userTintStrength * 0.22))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.backgroundColor = NSColor.black.withAlphaComponent(effectiveAlpha).cgColor
        CATransaction.commit()
    }

    func updateCornerRadius(_ radius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = radius
        strokeLayer.cornerRadius = radius
        CATransaction.commit()
    }

    func applyAmbientColor(primary: NSColor?, secondary: NSColor?, enabled: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        if enabled, let primary = primary, let secondary = secondary {
            glowLayer.colors = [
                primary.withAlphaComponent(0.22).cgColor,
                secondary.withAlphaComponent(0.08).cgColor,
                NSColor.clear.cgColor
            ]
            glowLayer.opacity = 0.9
            refractionLayer.colors = [
                NSColor.clear.cgColor,
                primary.withAlphaComponent(0.14).cgColor,
                NSColor.clear.cgColor,
                secondary.withAlphaComponent(0.08).cgColor,
                NSColor.clear.cgColor
            ]
        } else {
            glowLayer.colors = [
                NSColor.white.withAlphaComponent(0.12).cgColor,
                NSColor.white.withAlphaComponent(0.02).cgColor,
                NSColor.clear.cgColor
            ]
            glowLayer.opacity = 0
            refractionLayer.colors = [
                NSColor.clear.cgColor,
                NSColor.white.withAlphaComponent(0.10).cgColor,
                NSColor.clear.cgColor,
                NSColor.cyan.withAlphaComponent(0.05).cgColor,
                NSColor.clear.cgColor
            ]
        }
        CATransaction.commit()
    }
}

final class DismissibleDetailCardView: LiquidGlassCardView {
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }
}

final class DismissibleContentView: NSView {
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }
}

final class DismissibleStackView: NSStackView {
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }
}

class LiquidGlassButton: NSButton {
    var cornerRadiusValue: CGFloat = 18 {
        didSet {
            updateCorners()
        }
    }

    private let backgroundGlassView = NSView()
    private let tintLayer = CALayer()
    private let specularLayer = CAGradientLayer()
    private let hoverLayer = CALayer()
    private let strokeLayer = CALayer()

    private let contentStack = NSStackView()
    let iconImageView = NSImageView()
    let titleLabel = NSTextField()
    private var trackingArea: NSTrackingArea?

    override var title: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            titleLabel.isHidden = newValue.isEmpty
            super.title = ""
        }
    }

    override var image: NSImage? {
        get { iconImageView.image }
        set {
            iconImageView.image = newValue
            iconImageView.isHidden = (newValue == nil)
            super.image = nil
        }
    }

    override var contentTintColor: NSColor? {
        get { iconImageView.contentTintColor }
        set {
            let color = newValue ?? .white
            iconImageView.contentTintColor = color
            titleLabel.textColor = color
            super.contentTintColor = color
        }
    }

    override var font: NSFont? {
        get { titleLabel.font }
        set {
            titleLabel.font = newValue ?? NSFont.systemFont(ofSize: 12, weight: .semibold)
            super.font = newValue
        }
    }

    override var imagePosition: NSControl.ImagePosition {
        get { super.imagePosition }
        set {
            super.imagePosition = newValue
            if newValue == .imageOnly {
                titleLabel.isHidden = true
            } else if newValue == .noImage {
                iconImageView.isHidden = true
            }
        }
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1.0 : 0.45
        }
    }

    init(title: String, icon: String? = nil, cornerRadius: CGFloat = 18, target: AnyObject?, action: Selector) {
        self.cornerRadiusValue = cornerRadius
        super.init(frame: .zero)
        self.target = target
        self.action = action
        commonInit()

        self.title = title
        if let icon = icon {
            setIcon(name: icon, pointSize: 12, weight: .semibold)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        self.isBordered = false
        self.setButtonType(.momentaryPushIn)
        self.focusRingType = .none
        super.title = ""
        super.image = nil
        wantsLayer = true

        // Background Glass View
        backgroundGlassView.wantsLayer = true
        backgroundGlassView.layer?.masksToBounds = true
        backgroundGlassView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundGlassView, positioned: .below, relativeTo: nil)

        // Install genuine liquid glass effect (same crystal-clear refractive glass as LiquidGlassCardView)
        installGlassEffect(into: backgroundGlassView, cornerRadius: cornerRadiusValue, style: 1, blendWithinWindow: true)

        // Liquid glass white sheen tint (PURE CLEAR GLASS - ZERO BLACK TINT)
        tintLayer.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        backgroundGlassView.layer?.addSublayer(tintLayer)

        // Top specular reflection (liquid glass sheen)
        specularLayer.colors = [
            NSColor.white.withAlphaComponent(0.18).cgColor,
            NSColor.white.withAlphaComponent(0.03).cgColor,
            NSColor.clear.cgColor
        ]
        specularLayer.locations = [0.0, 0.40, 1.0]
        specularLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        specularLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        backgroundGlassView.layer?.addSublayer(specularLayer)

        // Hover highlight
        hoverLayer.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        hoverLayer.opacity = 0.0
        backgroundGlassView.layer?.addSublayer(hoverLayer)

        // Specular stroke / border (crystal white refraction border, ZERO black shadow)
        strokeLayer.borderWidth = 1.0
        strokeLayer.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        strokeLayer.shadowColor = NSColor.clear.cgColor
        strokeLayer.shadowOpacity = 0.0
        strokeLayer.shadowRadius = 0
        strokeLayer.shadowOffset = .zero
        backgroundGlassView.layer?.addSublayer(strokeLayer)

        // Foreground Content - Layered strictly ABOVE glass
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 6
        contentStack.distribution = .gravityAreas
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.wantsLayer = true
        contentStack.layer?.zPosition = 100
        addSubview(contentStack, positioned: .above, relativeTo: nil)

        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.contentTintColor = .white.withAlphaComponent(0.95)
        iconImageView.setContentHuggingPriority(.required, for: .horizontal)
        iconImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconImageView.isHidden = true
        contentStack.addArrangedSubview(iconImageView)

        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.drawsBackground = false
        titleLabel.textColor = .white.withAlphaComponent(0.95)
        titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.isHidden = true
        contentStack.addArrangedSubview(titleLabel)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        iconImageView.shadow = shadow
        titleLabel.shadow = shadow

        NSLayoutConstraint.activate([
            backgroundGlassView.topAnchor.constraint(equalTo: topAnchor),
            backgroundGlassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            backgroundGlassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundGlassView.trailingAnchor.constraint(equalTo: trailingAnchor),

            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2)
        ])

        updateCorners()
    }

    func setIcon(name: String, pointSize: CGFloat = 12, weight: NSFont.Weight = .semibold) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        iconImageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        iconImageView.isHidden = (iconImageView.image == nil)
    }

    func setActive(_ active: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        if active {
            tintLayer.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor
            strokeLayer.borderColor = NSColor.systemBlue.withAlphaComponent(0.60).cgColor
        } else {
            tintLayer.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            strokeLayer.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        }
        CATransaction.commit()
    }

    override var intrinsicContentSize: NSSize {
        if !titleLabel.isHidden && !titleLabel.stringValue.isEmpty {
            let labelSize = titleLabel.intrinsicContentSize
            let iconWidth: CGFloat = (iconImageView.image != nil && !iconImageView.isHidden) ? 14 : 0
            let spacing: CGFloat = iconWidth > 0 ? contentStack.spacing : 0
            let width = labelSize.width + iconWidth + spacing + 20
            let height = max(32, cornerRadiusValue * 2)
            return NSSize(width: ceil(width), height: height)
        } else {
            let dim = cornerRadiusValue * 2
            return NSSize(width: dim, height: dim)
        }
    }

    private func updateCorners() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundGlassView.layer?.cornerRadius = cornerRadiusValue
        for sub in backgroundGlassView.subviews {
            sub.setValue(cornerRadiusValue, forKey: "cornerRadius")
            sub.layer?.cornerRadius = cornerRadiusValue
            sub.layer?.masksToBounds = true
        }
        strokeLayer.cornerRadius = cornerRadiusValue
        specularLayer.cornerRadius = cornerRadiusValue
        hoverLayer.cornerRadius = cornerRadiusValue
        tintLayer.cornerRadius = cornerRadiusValue
        // For circular icon buttons, keep specular subtle or clear
        let isCircle = bounds.width > 0 && abs(bounds.width - bounds.height) < 4
        specularLayer.opacity = isCircle ? 0.0 : 1.0
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sub in backgroundGlassView.subviews {
            sub.frame = backgroundGlassView.bounds
        }
        tintLayer.frame = backgroundGlassView.bounds
        specularLayer.frame = backgroundGlassView.bounds
        hoverLayer.frame = backgroundGlassView.bounds
        strokeLayer.frame = backgroundGlassView.bounds.insetBy(dx: 0.5, dy: 0.5)
        updateCorners()
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        if let trackingArea = trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isEnabled else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        hoverLayer.opacity = 1.0
        strokeLayer.borderColor = NSColor.white.withAlphaComponent(0.40).cgColor
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        hoverLayer.opacity = 0.0
        strokeLayer.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        contentStack.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1.0)
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        contentStack.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}

final class LiquidTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let selectionRect = bounds.insetBy(dx: 4, dy: 2)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 9, yRadius: 9)
        NSColor.systemBlue.withAlphaComponent(0.75).setFill()
        path.fill()
    }
}

final class CenteredTextFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var titleRect = super.titleRect(forBounds: rect)
        titleRect.size.height = min(titleRect.height, rect.height)
        titleRect.origin.y = rect.origin.y + floor((rect.height - titleRect.height) / 2)
        return titleRect
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        titleRect(forBounds: rect)
    }

    override func edit(withFrame rect: NSRect,
                       in controlView: NSView,
                       editor textObj: NSText,
                       delegate: Any?,
                       event: NSEvent?) {
        super.edit(withFrame: titleRect(forBounds: rect),
                   in: controlView,
                   editor: textObj,
                   delegate: delegate,
                   event: event)
    }

    override func select(withFrame rect: NSRect,
                         in controlView: NSView,
                         editor textObj: NSText,
                         delegate: Any?,
                         start selStart: Int,
                         length selLength: Int) {
        super.select(withFrame: titleRect(forBounds: rect),
                     in: controlView,
                     editor: textObj,
                     delegate: delegate,
                     start: selStart,
                     length: selLength)
    }
}

final class MarqueeLabelView: NSView {
    private let primaryLabel = NSTextField(labelWithString: "")
    private let duplicateLabel = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var offset: CGFloat = 0
    private let gap: CGFloat = 28
    private var isMenuVisible: Bool = false

    var stringValue: String = "" {
        didSet {
            primaryLabel.stringValue = stringValue
            duplicateLabel.stringValue = stringValue
            offset = 0
            needsLayout = true
            updateAnimationState()
        }
    }

    init(font: NSFont, color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        [primaryLabel, duplicateLabel].forEach {
            $0.font = font
            $0.textColor = color
            $0.lineBreakMode = .byClipping
            $0.translatesAutoresizingMaskIntoConstraints = true
            addSubview($0)
        }
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    deinit {
        timer?.invalidate()
    }

    override func layout() {
        super.layout()
        let labelHeight = max(18, primaryLabel.intrinsicContentSize.height)
        let availableWidth = max(bounds.width, 1)
        let textWidth = primaryLabel.intrinsicContentSize.width

        if textWidth <= availableWidth {
            primaryLabel.frame = NSRect(x: 0, y: floor((bounds.height - labelHeight) / 2), width: availableWidth, height: labelHeight)
            duplicateLabel.isHidden = true
            updateAnimationState()
            return
        }

        duplicateLabel.isHidden = false
        let travel = textWidth + gap
        let normalizedOffset = offset.truncatingRemainder(dividingBy: travel)
        let y = floor((bounds.height - labelHeight) / 2)
        primaryLabel.frame = NSRect(x: -normalizedOffset, y: y, width: textWidth, height: labelHeight)
        duplicateLabel.frame = NSRect(x: textWidth + gap - normalizedOffset, y: y, width: textWidth, height: labelHeight)
        updateAnimationState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimationState()
    }

    func setMenuVisible(_ visible: Bool) {
        guard isMenuVisible != visible else { return }
        isMenuVisible = visible
        updateAnimationState()
    }

    private func updateAnimationState() {
        let shouldAnimate = isMenuVisible && window?.isVisible == true && primaryLabel.intrinsicContentSize.width > bounds.width + 4
        if shouldAnimate {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 45.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.offset += 0.55
                self.needsLayout = true
            }
            RunLoop.main.add(timer!, forMode: .common)
        } else {
            timer?.invalidate()
            timer = nil
            offset = 0
        }
    }
}

func installGlassEffect(into host: NSView, cornerRadius: CGFloat, style: Int, blendWithinWindow: Bool = false) {
    if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
        let glassView = glassClass.init(frame: host.bounds)
        glassView.autoresizingMask = [.width, .height]
        glassView.setValue(cornerRadius, forKey: "cornerRadius")
        glassView.setValue(style, forKey: "style")
        glassView.appearance = NSAppearance(named: .vibrantDark)
        host.addSubview(glassView, positioned: .below, relativeTo: nil)
        return
    }

    let effect = NSVisualEffectView(frame: host.bounds)
    effect.autoresizingMask = [.width, .height]
    effect.material = blendWithinWindow ? .popover : .popover
    effect.blendingMode = blendWithinWindow ? .withinWindow : .behindWindow
    effect.state = .active
    effect.appearance = NSAppearance(named: .vibrantDark)
    host.addSubview(effect, positioned: .below, relativeTo: nil)
}

extension NSTextField {
    static func liquidLabel(_ string: String,
                            size: CGFloat,
                            weight: NSFont.Weight,
                            color: NSColor = .white) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

extension NSButton {
    static func liquidSymbol(symbol: String,
                             pointSize: CGFloat,
                             weight: NSFont.Weight = .semibold,
                             target: AnyObject?,
                             action: Selector) -> NSButton {
        let button = NSButton()
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .white
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}
