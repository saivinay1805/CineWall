//
//  NativeVideoLayout.swift
//  CineWall
//
//  Video layout computation for Fill, Fit, Stretch and None scaling modes.
//

import AVFoundation
import CoreGraphics
import Foundation

public enum NativeVideoScalingMode: Int32, Equatable, Sendable, CaseIterable {
    case none = 0
    case stretch = 1
    case match = 2
    case fill = 3

    public var title: String {
        switch self {
        case .none: return "Original Size"
        case .stretch: return "Stretch to Fill"
        case .match: return "Fit (Aspect Fit)"
        case .fill: return "Fill Screen (Aspect Fill)"
        }
    }
}

public enum NativeVideoLayout {
    public struct Pan: Equatable, Sendable {
        public static let centered = Pan(x: 0.5, y: 0.5)
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        public var normalized: Pan {
            func clamp(_ value: Double) -> Double {
                value.isFinite ? min(max(value, 0), 1) : 0.5
            }
            return Pan(x: clamp(x), y: clamp(y))
        }
    }

    public struct PixelRect: Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public enum Placement: Equatable {
        case gravity(AVLayerVideoGravity)
        case frame(CGRect)
        case pending
    }

    public static func normalizedFactor(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 1
    }

    public static func pictureRect(
        mode: NativeVideoScalingMode, factor: Double, videoSize: CGSize, viewport: CGSize,
        backingScale: CGFloat, pan: Pan = .centered
    ) -> PixelRect {
        let scale = normalizedFactor(Double(backingScale))
        let sceneWidth = Double(max(1, rounded(Double(videoSize.width))))
        let sceneHeight = Double(max(1, rounded(Double(videoSize.height))))
        let deviceWidth = max(0, rounded(Double(viewport.width) * scale))
        let deviceHeight = max(0, rounded(Double(viewport.height) * scale))
        let displayWidth = Double(max(1, rounded(Double(deviceWidth) / scale)))
        let displayHeight = Double(max(1, rounded(Double(deviceHeight) / scale)))

        let ratioX = displayWidth / sceneWidth
        let ratioY = displayHeight / sceneHeight
        var scaleX = 1.0
        var scaleY = 1.0
        switch mode {
        case .none:
            break
        case .stretch:
            scaleX = ratioX
            scaleY = ratioY
        case .match:
            scaleX = min(ratioX, ratioY)
            scaleY = scaleX
        case .fill:
            scaleX = max(ratioX, ratioY)
            scaleY = scaleX
        }
        let userFactor = normalizedFactor(factor)
        scaleX *= userFactor
        scaleY *= userFactor

        let width = sceneWidth * scaleX
        let height = sceneHeight * scaleY
        let p = pan.normalized
        let x = (displayWidth - width) * p.x
        let y = (displayHeight - height) * p.y
        return PixelRect(
            x: rounded(x * scale), y: rounded(y * scale),
            width: max(1, rounded(width * scale)), height: max(1, rounded(height * scale))
        )
    }

    public static func placement(
        mode: NativeVideoScalingMode, factor: Double, videoSize: CGSize?, viewport: CGSize,
        backingScale: CGFloat, pan: Pan = .centered
    ) -> Placement {
        if normalizedFactor(factor) == 1, pan.normalized == .centered {
            switch mode {
            case .fill: return .gravity(.resizeAspectFill)
            case .match: return .gravity(.resizeAspect)
            case .stretch: return .gravity(.resize)
            case .none: break
            }
        }
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return .pending }
        let rect = pictureRect(
            mode: mode, factor: factor, videoSize: videoSize, viewport: viewport,
            backingScale: backingScale, pan: pan
        )
        let scale = CGFloat(normalizedFactor(Double(backingScale)))
        return .frame(
            CGRect(
                x: CGFloat(rect.x) / scale, y: CGFloat(rect.y) / scale,
                width: CGFloat(rect.width) / scale, height: CGFloat(rect.height) / scale
            )
        )
    }

    public static func layerFrame(_ rect: CGRect, viewportHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: viewportHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func composeFrame(
        _ image: CGImage, pixelSize: CGSize, backingScale: CGFloat, mode: NativeVideoScalingMode,
        factor: Double, pan: Pan = .centered, borderColor: CGColor? = nil
    ) -> CGImage? {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0,
              pixelSize.width <= 16_384, pixelSize.height <= 16_384 else { return nil }
        let width = Int(pixelSize.width.rounded(.up)), height = Int(pixelSize.height.rounded(.up))
        guard width * height <= 32 * 1024 * 1024,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.setFillColor((mode != .fill && mode != .stretch ? borderColor : nil) ?? CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(normalizedFactor(Double(backingScale)))
        let rect = pictureRect(
            mode: mode, factor: factor,
            videoSize: CGSize(width: image.width, height: image.height),
            viewport: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale),
            backingScale: scale, pan: pan
        )
        context.draw(
            image,
            in: CGRect(x: rect.x, y: height - rect.y - rect.height, width: rect.width, height: rect.height)
        )
        return context.makeImage()
    }

    private static func rounded(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), Double(Int32.min)), Double(Int32.max)))
    }
}
