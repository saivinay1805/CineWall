//
//  LockScreenVideoPlayer.swift
//  CineWallExtension
//
//  Hardware-accelerated AVPlayerLayer video playback for Lock Screen & Screen Saver.
//

import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore

@MainActor
public protocol LockScreenVideoPlaying: AnyObject {
    var isPaused: Bool { get }
    var onFailure: ((String) -> Void)? { get set }
    func attach(to root: CALayer)
    func prepare() async throws -> CGImage?
    func setPaused(_ paused: Bool)
    func frame() async -> CGImage?
    func stop()
}

@MainActor
public final class LockScreenVideoPlayer: LockScreenVideoPlaying {
    public enum Failure: Error, LocalizedError, Equatable {
        case unplayable(String)
        case stopped

        public var errorDescription: String? {
            switch self {
            case .unplayable(let detail): return detail
            case .stopped: return "The player was stopped"
            }
        }
    }

    public static let stallCheckDelay = Duration.seconds(4)

    private let url: URL
    private let mode: NativeVideoScalingMode
    private let factor: Double
    private let pan: NativeVideoLayout.Pan
    private let viewport: CGSize
    private let backingScale: CGFloat
    private let player = AVQueuePlayer()
    private let layer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var observations: [NSKeyValueObservation] = []
    private var presentationSize: CGSize?
    private var preparing: CheckedContinuation<Void, Error>?
    private var stallCheck: Task<Void, Never>?
    private var stopped = false
    public private(set) var isPaused = false

    public var onFailure: ((String) -> Void)? {
        didSet { deliverPendingFailure() }
    }
    private var pendingFailure: String?
    private var failureLatched = false

    public init(
        url: URL, mode: NativeVideoScalingMode, factor: Double,
        pan: NativeVideoLayout.Pan = .centered, viewport: CGSize, backingScale: CGFloat
    ) {
        self.url = url
        self.mode = mode
        self.factor = factor
        self.pan = pan
        self.viewport = viewport
        self.backingScale = backingScale
        player.actionAtItemEnd = .advance
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        layer.player = player
        layer.videoGravity = .resizeAspectFill
    }

    public func attach(to root: CALayer) {
        root.masksToBounds = true
        root.addSublayer(layer)
        applyPlacement()
    }

    public func prepare() async throws -> CGImage? {
        let item = try await Self.videoOnlyItem(url: url)
        guard !stopped else { throw Failure.stopped }
        let looper = AVPlayerLooper(player: player, templateItem: item)
        self.looper = looper
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            preparing = continuation
            observations = [
                layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                    guard layer.isReadyForDisplay else { return }
                    Task { @MainActor [weak self] in self?.finishPreparing(nil) }
                },
                looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
                    guard looper.status == .failed else { return }
                    let detail = looper.error?.localizedDescription ?? "The player looper failed"
                    Task { @MainActor [weak self] in self?.fail(detail) }
                },
                player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                    let item = player.currentItem
                    Task { @MainActor [weak self] in self?.follow(item) }
                },
            ]
            player.play()
        }
        return await frame()
    }

    private var itemObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private weak var followed: AVPlayerItem?

    private func follow(_ item: AVPlayerItem?) {
        guard !stopped, let item, item !== followed else { return }
        followed = item
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let detail = item.error?.localizedDescription ?? "The playback item failed"
            Task { @MainActor [weak self] in self?.fail(detail) }
        }
        sizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            guard item.presentationSize.width > 0, item.presentationSize.height > 0 else { return }
            let size = item.presentationSize
            Task { @MainActor [weak self] in self?.updateSize(size) }
        }
    }

    private func updateSize(_ size: CGSize) {
        guard !stopped, size != presentationSize else { return }
        presentationSize = size
        applyPlacement()
    }

    private func finishPreparing(_ error: Error?) {
        guard let continuation = preparing else { return }
        preparing = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func fail(_ detail: String) {
        guard !stopped else { return }
        finishPreparing(Failure.unplayable(detail))
        if !failureLatched {
            failureLatched = true
            pendingFailure = detail
            stallCheck?.cancel()
            deliverPendingFailure()
        }
    }

    private func deliverPendingFailure() {
        guard !stopped, let detail = pendingFailure, let handler = onFailure else { return }
        pendingFailure = nil
        onFailure = nil
        handler(detail)
    }

    private func applyPlacement() {
        guard !stopped else { return }
        let placement = NativeVideoLayout.placement(
            mode: mode, factor: factor, videoSize: presentationSize, viewport: viewport,
            backingScale: backingScale, pan: pan
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch placement {
        case .gravity(let gravity):
            layer.videoGravity = gravity
            layer.frame = CGRect(origin: .zero, size: viewport)
        case .frame(let rect):
            layer.videoGravity = .resize
            layer.frame = NativeVideoLayout.layerFrame(rect, viewportHeight: viewport.height)
        case .pending:
            break
        }
    }

    public func setPaused(_ paused: Bool) {
        guard !stopped, paused != isPaused else { return }
        isPaused = paused
        stallCheck?.cancel()
        stallCheck = nil
        if paused {
            player.pause()
        } else {
            player.play()
            scheduleStallCheck()
        }
    }

    private func scheduleStallCheck() {
        let before = player.currentItem?.currentTime()
        stallCheck = Task { [weak self] in
            do { try await Task.sleep(for: Self.stallCheckDelay) } catch { return }
            guard let self, !self.stopped, !self.isPaused, self.preparing == nil else { return }
            let now = self.player.currentItem?.currentTime()
            guard let before, let now, CMTimeCompare(before, now) == 0 else { return }
            self.fail("Playback did not advance after it was resumed")
        }
    }

    public func frame() async -> CGImage? {
        guard !stopped else { return nil }
        let pixels = CGSize(width: viewport.width * backingScale, height: viewport.height * backingScale)
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        generator.maximumSize = CGSize(
            width: min(pixels.width * 2, 16_384), height: min(pixels.height * 2, 16_384)
        )
        let time = player.currentItem?.currentTime() ?? .zero
        guard let image = try? await generator.image(at: time.isValid ? time : .zero).image else {
            return nil
        }
        return NativeVideoLayout.composeFrame(
            image, pixelSize: pixels, backingScale: backingScale, mode: mode, factor: factor, pan: pan
        )
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        stallCheck?.cancel()
        stallCheck = nil
        pendingFailure = nil
        onFailure = nil
        observations.removeAll()
        itemObservation = nil
        sizeObservation = nil
        finishPreparing(Failure.stopped)
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        layer.player = nil
        layer.removeFromSuperlayer()
    }

    public static func videoOnlyItem(url: URL) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else {
                throw Failure.unplayable("The asset reports itself unplayable")
            }
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw Failure.unplayable("The asset has no video track")
            }
            let (range, transform) = try await video.load(.timeRange, .preferredTransform)
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw Failure.unplayable("No video track could be created")
            }
            try track.insertTimeRange(range, of: video, at: .zero)
            track.preferredTransform = transform
            return AVPlayerItem(asset: composition)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unplayable(error.localizedDescription)
        }
    }
}
