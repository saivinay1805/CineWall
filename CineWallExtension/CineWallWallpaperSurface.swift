//
//  CineWallWallpaperSurface.swift
//  CineWallExtension
//
//  Compositor Surface & Hardware Video Presentation for Lock Screen.
//

import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import QuartzCore

@MainActor
public final class CineWallWallpaperSurface: LockScreenSurfaceLifecycle {
    public let context: CAContext
    public let root: CALayer
    public private(set) var scene: LockScreenScene
    public let displayID: UInt32?
    public private(set) var size: CGSize
    public private(set) var scale: CGFloat
    public let preview: Bool
    public var presentation: String = "active"
    public var activity: String = "active"
    public var continuousPreviewRequested: Bool = false

    private var video: LockScreenVideoPlaying?
    private var nativeStart: Task<Void, Never>?
    private var contentError: Error?
    public private(set) var heldNotice: String?

    private var firstFrameReply: ((Error?) -> Void)?
    private var readyWaiters: [(Error?) -> Void] = []
    private var deadline: Task<Void, Never>?
    private var snapshotWaiters: [(Any?, Error?) -> Void] = []
    private var snapshotDeadline: Task<Void, Never>?
    private var latestSnapshot: IOSurface?
    private var stopped: Bool = false
    private var rendererPaused: Bool = false
    private var presentingSince: ContinuousClock.Instant?
    private var previewExpiry: Task<Void, Never>?
    public let generation: UInt64

    private let exchangeDirectory: URL
    public var isReusable: Bool { !stopped && contentError == nil }
    public var hasContent: Bool { video != nil || heldNotice != nil }

    public init(
        scene: LockScreenScene,
        displayID: UInt32?,
        size: CGSize,
        scale: CGFloat,
        preview: Bool = false,
        generation: UInt64 = 0,
        exchangeDirectory: URL? = nil
    ) throws {
        try Self.validate(size: size, scale: scale)
        self.exchangeDirectory = exchangeDirectory ?? CineWallWallpaperRuntime.exchange
        self.scene = scene
        self.displayID = displayID
        self.size = size
        self.scale = scale
        self.preview = preview
        self.generation = generation

        self.context = try CineWallWallpaperRuntime.context(displayID: displayID)
        self.root = CALayer()
        self.root.frame = CGRect(origin: .zero, size: size)
        self.root.contentsScale = scale
        self.context.layer = self.root
        CATransaction.flush()
    }

    private static func validate(size: CGSize, scale: CGFloat) throws {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0,
              size.width * scale <= 16_384, size.height * scale <= 16_384,
              size.width * size.height * scale * scale <= 32 * 1024 * 1024
        else { throw CineWallWallpaperRuntime.failure("Invalid wallpaper surface dimensions.") }
    }

    public func start(completion: @escaping (Error?) -> Void) {
        guard !stopped, video == nil else {
            completion(CineWallWallpaperRuntime.failure("Wallpaper surface is not available."))
            return
        }
        contentError = nil
        startVideo(completion: completion)
    }

    private func startVideo(completion: @escaping (Error?) -> Void) {
        firstFrameReply = completion
        armDeadline()
        nativeStart = Task { [weak self] in
            guard let self else { return }
            do {
                let (player, firstFrame) = try await self.attemptVideo(scene: self.scene)
                guard !Task.isCancelled, !self.stopped else {
                    player.stop()
                    return
                }
                if let snapshot = try? Self.snapshot(firstFrame) {
                    try? LockScreenFrameBacking.install(snapshot, on: self.root)
                    self.latestSnapshot = snapshot
                }
                self.contentFrameReady()
                self.finishSnapshots(error: nil)
                player.onFailure = { [weak self] detail in
                    MainActor.assumeIsolated { self?.videoDidFail(detail) }
                }
            } catch {
                guard !Task.isCancelled, !self.stopped, self.firstFrameReply != nil else { return }
                self.video?.stop()
                self.video = nil
                self.holdVideo(error.localizedDescription)
            }
        }
    }

    private func attemptVideo(scene: LockScreenScene) async throws -> (LockScreenVideoPlaying, CGImage) {
        let exchange = exchangeDirectory
        let framing = scene.effectiveFraming
        let mode = NativeVideoScalingMode(rawValue: scene.scalingMode) ?? .fill
        let pan = NativeVideoLayout.Pan(x: framing.panX, y: framing.panY)
        let factor = scene.scalingFactor > 0 ? scene.scalingFactor : 1.0

        let videoURL: URL
        if let nativeFile = scene.nativeVideoFile {
            videoURL = exchange.appendingPathComponent(scene.projectPath).deletingLastPathComponent().appendingPathComponent(nativeFile)
        } else if let projectData = try? Data(contentsOf: exchange.appendingPathComponent(scene.projectPath)),
                  let projectDict = try? JSONSerialization.jsonObject(with: projectData) as? [String: Any],
                  let fileName = projectDict["file"] as? String {
            videoURL = exchange.appendingPathComponent(scene.projectPath).deletingLastPathComponent().appendingPathComponent(fileName)
        } else {
            videoURL = exchange.appendingPathComponent(scene.assetsPath).appendingPathComponent("video.mp4")
        }

        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw CineWallWallpaperRuntime.failure("Video file not found at \(videoURL.path)")
        }

        let player = LockScreenVideoPlayer(
            url: videoURL,
            mode: mode,
            factor: factor,
            pan: pan,
            viewport: size,
            backingScale: scale
        )

        self.video = player
        player.attach(to: root)

        guard let first = try await player.prepare() else {
            player.stop()
            if self.video === player { self.video = nil }
            throw CineWallWallpaperRuntime.failure("No frame could be read from video clip.")
        }

        return (player, first)
    }

    private func holdVideo(_ reason: String) {
        nativeStart = nil
        guard !stopped else { return }
        heldNotice = "Video playback held: \(reason)"
        CineWallWallpaperRuntime.log("Held display=\(scene.displayID) \(reason)")
        if let reply = firstFrameReply {
            firstFrameReply = nil
            deadline?.cancel()
            reply(nil)
        }
        finishWaiters(error: nil)
        finishSnapshots(error: CineWallWallpaperRuntime.failure(reason))
    }

    private func videoDidFail(_ detail: String) {
        guard !stopped else { return }
        CineWallWallpaperRuntime.log("Video failed: \(detail)")
        holdVideo(detail)
    }

    private func contentFrameReady() {
        nativeStart = nil
        presentingSince = ContinuousClock.now
        if let reply = firstFrameReply {
            firstFrameReply = nil
            deadline?.cancel()
            reply(nil)
        }
        finishWaiters(error: nil)
        applyPolicy()
    }

    private func armDeadline() {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, !self.stopped, let reply = self.firstFrameReply else { return }
            self.firstFrameReply = nil
            self.contentError = CineWallWallpaperRuntime.failure("First frame timeout.")
            reply(self.contentError)
            self.finishWaiters(error: self.contentError)
        }
    }

    private func finishWaiters(error: Error?) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0(error) }
    }

    public func whenReady(completion: @escaping (Error?) -> Void) {
        if let contentError {
            completion(contentError)
        } else if hasContent, firstFrameReply == nil {
            completion(nil)
        } else {
            readyWaiters.append(completion)
        }
    }

    public static func snapshot(_ image: CGImage) throws -> IOSurface {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 32 * 1024 * 1024,
              let surface = IOSurface(properties: [
                .width: width, .height: height, .bytesPerElement: 4,
                .pixelFormat: kCVPixelFormatType_32BGRA,
              ])
        else { throw CocoaError(.fileReadCorruptFile) }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let target = CGContext(
            data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw CocoaError(.fileReadCorruptFile) }
        target.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return surface
    }

    public func snapshot(reply: @escaping (Any?, Error?) -> Void) {
        if let video, !rendererPaused, !stopped {
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else {
                    reply(nil, CancellationError())
                    return
                }
                if let frame = await self.video?.frame(),
                   let snapshot = try? Self.snapshot(frame) {
                    self.latestSnapshot = snapshot
                    try? LockScreenFrameBacking.install(snapshot, on: self.root)
                    do {
                        reply(try CineWallWallpaperRuntime.snapshotReply(snapshot), nil)
                        return
                    } catch {}
                }
                if let latestSnapshot = self.latestSnapshot,
                   let xpc = try? CineWallWallpaperRuntime.snapshotReply(latestSnapshot) {
                    reply(xpc, nil)
                } else {
                    reply(nil, CineWallWallpaperRuntime.failure("Snapshot failed"))
                }
            }
            return
        }

        if let latestSnapshot, let xpc = try? CineWallWallpaperRuntime.snapshotReply(latestSnapshot) {
            reply(xpc, nil)
            return
        }
        snapshotWaiters.append(reply)
        if snapshotDeadline == nil {
            snapshotDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                guard let self, !self.stopped else { return }
                self.finishSnapshots(error: CineWallWallpaperRuntime.failure("Snapshot timeout"))
            }
        }
    }

    private func finishSnapshots(error: Error?) {
        snapshotDeadline?.cancel()
        snapshotDeadline = nil
        let waiters = snapshotWaiters
        snapshotWaiters.removeAll()
        if let error {
            waiters.forEach { $0(nil, error) }
        } else if let latestSnapshot, let xpc = try? CineWallWallpaperRuntime.snapshotReply(latestSnapshot) {
            waiters.forEach { $0(xpc, nil) }
        } else {
            waiters.forEach { $0(nil, CineWallWallpaperRuntime.failure("No snapshot available.")) }
        }
    }

    public func update(scene: LockScreenScene) {
        self.scene = scene
        applyPolicy()
    }

    public func replace(scene: LockScreenScene, size: CGSize, scale: CGFloat, completion: @escaping (Error?) -> Void) {
        clear()
        self.scene = scene
        self.size = size
        self.scale = scale
        self.root.frame = CGRect(origin: .zero, size: size)
        self.root.contentsScale = scale
        CATransaction.flush()
        start(completion: completion)
    }

    public func clear() {
        nativeStart?.cancel()
        nativeStart = nil
        video?.stop()
        video = nil
        heldNotice = nil
        latestSnapshot = nil
        root.contents = nil
        finishWaiters(error: CancellationError())
        finishSnapshots(error: CancellationError())
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        deadline?.cancel()
        deadline = nil
        previewExpiry?.cancel()
        previewExpiry = nil
        clear()
        context.invalidate()
    }

    private var authorityRequest: FastWallpaperPresentationAuthority.Request {
        let session = FastWallpaperPresentationAuthority.SessionState.current()
        let isLocked = CineWallWallpaperController.shared.isScreenLocked || session.locked
        return FastWallpaperPresentationAuthority.Request(
            role: preview ? .preview : .lockScreen,
            userPaused: scene.paused,
            displaysAsleep: CineWallWallpaperController.shared.displayPower.displaysAsleep(for: displayID),
            sessionLocked: isLocked,
            sessionOnConsole: session.onConsole,
            presentationMode: presentation,
            hostActivity: activity == "suspended" ? .suspended : .active,
            presentedFor: presentingSince.map { ContinuousClock.now - $0 },
            continuousPreviewRequested: continuousPreviewRequested,
            lockScreenEnabled: CineWallWallpaperController.shared.configuration?.lockScreenEnabled ?? false,
            screenSaverEnabled: CineWallWallpaperController.shared.configuration?.screenSaverEnabled ?? false
        )
    }

    private func schedulePreviewExpiry(for request: FastWallpaperPresentationAuthority.Request) {
        previewExpiry?.cancel()
        previewExpiry = nil
        guard let remaining = FastWallpaperPresentationAuthority.nextReevaluation(for: request) else {
            return
        }
        previewExpiry = Task { [weak self] in
            do { try await Task.sleep(for: remaining) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.previewExpiry = nil
            self.applyPolicy()
        }
    }

    public func applyPolicy() {
        guard firstFrameReply == nil, !stopped, video != nil else { return }
        let request = authorityRequest
        let reasons = FastWallpaperPresentationAuthority.suspensionReasons(for: request)
        let shouldPause = !reasons.isEmpty
        schedulePreviewExpiry(for: request)
        guard shouldPause != rendererPaused else { return }
        rendererPaused = shouldPause
        video?.setPaused(shouldPause)
        if shouldPause && video != nil {
            refreshVideoFrame()
        }
        CineWallWallpaperRuntime.log(
            "Playback display=\(scene.displayID) mode=\(presentation) activity=\(activity) locked=\(request.sessionLocked) console=\(request.sessionOnConsole) paused=\(shouldPause) reasons=\(reasons.rawValue)"
        )
    }

    private func refreshVideoFrame() {
        guard let video else { return }
        Task { @MainActor [weak self, weak video] in
            guard let self, let video, self.video === video, self.rendererPaused,
                  let frame = await video.frame(), self.video === video, self.rendererPaused,
                  let snapshot = try? Self.snapshot(frame)
            else { return }
            try? LockScreenFrameBacking.install(snapshot, on: self.root)
            self.latestSnapshot = snapshot
        }
    }
}
