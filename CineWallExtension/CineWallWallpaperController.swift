//
//  CineWallWallpaperController.swift
//  CineWallExtension
//
//  Extension Controller Managing Surfaces, Configuration & Host Coordination.
//

import AppKit
import Foundation

@MainActor
public final class CineWallWallpaperController {
    public static let shared = CineWallWallpaperController()

    private let surfaces = LockScreenSurfaceRegistry<CineWallWallpaperSurface>()
    public private(set) var configuration: LockScreenConfiguration?
    private var observers: [NSObjectProtocol] = []
    public let displayPower = FastDisplayPowerProbe.system

    private lazy var reevaluation = FastLockScreenReevaluationBurst(perform: { [weak self] in
        self?.surfaces.values.forEach { $0.applyPolicy() }
    })
    private var started = false

    public var surfaceCount: Int { surfaces.values.count }

    public func start() {
        guard !started else { return }
        started = true
        try? CineWallWallpaperRuntime.load()
        reload()

        let workspace = NSWorkspace.shared.notificationCenter
        for (name, cause) in [
            (NSWorkspace.screensDidSleepNotification, "display sleep"),
            (NSWorkspace.screensDidWakeNotification, "display wake"),
            (NSWorkspace.willSleepNotification, "system sleep"),
            (NSWorkspace.didWakeNotification, "system wake"),
            (NSWorkspace.sessionDidResignActiveNotification, "session switched away"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session active"),
        ] {
            observers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.presentationEnvironmentChanged(cause: cause) }
                }
            )
        }

        for (name, cause) in [
            ("com.apple.screenIsLocked", "screen locked"),
            ("com.apple.screenIsUnlocked", "screen unlocked"),
        ] {
            observers.append(
                DistributedNotificationCenter.default().addObserver(
                    forName: .init(name), object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.presentationEnvironmentChanged(cause: cause) }
                }
            )
        }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<CineWallWallpaperController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { controller.reload() }
            },
            LockScreenConfiguration.changedNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func presentationEnvironmentChanged(cause: String) {
        CineWallWallpaperRuntime.log("Re-checking presentation (\(cause)) surfaces=\(surfaces.values.count)")
        reevaluation.trigger()
    }

    public func reload() {
        let exchange = CineWallWallpaperRuntime.exchange
        let configURL = exchange.appendingPathComponent(LockScreenConfiguration.fileName)
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(LockScreenConfiguration.self, from: data) else {
            CineWallWallpaperRuntime.log("Configuration unavailable or missing at \(configURL.path)")
            configuration = nil
            surfaces.values.forEach { $0.clear() }
            return
        }

        guard config != configuration else { return }
        self.configuration = config
        CineWallWallpaperRuntime.log("Loaded configuration revision=\(config.revision) scenes=\(config.scenes.count)")

        if !config.lockScreenEnabled && !config.screenSaverEnabled && config.scenes.isEmpty {
            surfaces.values.forEach { $0.clear() }
            Self.recordShutdownAcknowledgement(revision: config.revision)
            CineWallWallpaperRuntime.log("Extension acknowledged shutdown (revision=\(config.revision)) and cleared all surfaces")
            return
        }

        for surface in Array(surfaces.values) {
            guard let scene = selectScene(displayID: surface.displayID) else {
                surface.clear()
                continue
            }
            if surface.hasContent && surface.scene.sharesRenderer(with: scene) {
                CineWallWallpaperRuntime.log("Surface on display \(surface.displayID.map { String($0) } ?? "nil") shares renderer; updating scene '\(scene.title)'")
                surface.update(scene: scene)
                acknowledge(surface: surface)
            } else {
                CineWallWallpaperRuntime.log("Surface on display \(surface.displayID.map { String($0) } ?? "nil") replacing scene with '\(scene.title)' (project=\(scene.projectPath))")
                surface.replace(scene: scene, size: surface.size, scale: surface.scale) { [weak self, weak surface] error in
                    guard let self, let surface else { return }
                    self.acknowledge(surface: surface, error: error)
                    if let error {
                        CineWallWallpaperRuntime.log("Replacement failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    public func acknowledge(surface: CineWallWallpaperSurface, error: Error? = nil) {
        guard !surface.preview, let configuration,
              configuration.scenes.contains(surface.scene),
              surfaces.values.contains(where: { $0 === surface })
        else { return }
        let scene = surface.scene
        surface.whenReady { [weak self, weak surface] readyError in
            guard let self, let surface, self.configuration == configuration,
                  surface.scene == scene, self.surfaces.values.contains(where: { $0 === surface }),
                  !(readyError is CancellationError) || error != nil
            else { return }
            let ackDisplayID = surface.displayID ?? scene.displayID
            CineWallWallpaperRuntime.log("Surface on display \(ackDisplayID) acknowledged readiness for revision=\(configuration.revision)")
            Self.record(
                LockScreenReadiness(
                    revision: configuration.revision, displayID: ackDisplayID,
                    error: (error ?? readyError)?.localizedDescription, held: surface.heldNotice
                )
            )
            if ackDisplayID != scene.displayID {
                Self.record(
                    LockScreenReadiness(
                        revision: configuration.revision, displayID: scene.displayID,
                        error: (error ?? readyError)?.localizedDescription, held: surface.heldNotice
                    )
                )
            }
        }
    }

    private static func record(_ readiness: LockScreenReadiness) {
        var readiness = readiness
        readiness.processID = getpid()
        do {
            let data = try JSONEncoder().encode(readiness)
            let exchange = CineWallWallpaperRuntime.exchange
            let readyFile = exchange.appendingPathComponent("ready-\(readiness.displayID).json")
            try data.write(to: readyFile, options: .atomic)
            CineWallWallpaperRuntime.log(
                "Recorded readiness displayID=\(readiness.displayID) revision=\(readiness.revision) pid=\(readiness.processID ?? 0) error=\(readiness.error ?? "none")"
            )
        } catch {
            CineWallWallpaperRuntime.log("Readiness acknowledgement failed displayID=\(readiness.displayID): \(error.localizedDescription)")
        }
    }

    private static func recordShutdownAcknowledgement(revision: String) {
        let exchange = CineWallWallpaperRuntime.exchange
        let pid = getpid()
        let ack = LockScreenShutdownAck(revision: revision, processID: pid)
        let ackFile = exchange.appendingPathComponent(LockScreenShutdownAck.fileName(forPID: pid))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? encoder.encode(ack) {
            try? data.write(to: ackFile, options: .atomic)
        }
    }

    public func selectScene(displayID: UInt32?) -> LockScreenScene? {
        let selected: LockScreenScene?
        if let displayID {
            selected = configuration?.scenes.first(where: { $0.displayID == displayID }) ?? configuration?.scenes.first
        } else {
            selected = configuration?.scenes.first
        }
        CineWallWallpaperRuntime.log(
            "selectScene requestedDisplayID=\(displayID.map { String($0) } ?? "nil") -> selectedSceneDisplayID=\(selected.map { String($0.displayID) } ?? "nil") path=\(selected?.projectPath ?? "none")"
        )
        return selected
    }

    public func acquire(id value: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
        start()
        let started = ContinuousClock.now
        CineWallWallpaperRuntime.logRequestShape("acquire", request)
        do {
            guard let request else {
                throw CineWallWallpaperRuntime.failure("Nil acquire request.")
            }
            let id = CineWallWallpaperRuntime.identifier(value) ?? UUID()
            var destSize: CGSize = NSScreen.main?.frame.size ?? CGSize(width: 2560, height: 1440)
            var scaleFactor: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
            var isPreview = false
            var directDisplayID: UInt32?

            if let destination = CineWallWallpaperRuntime.field("destination", in: request) {
                if let size = (CineWallWallpaperRuntime.field("size", in: destination) as? CGSize) ??
                              ((CineWallWallpaperRuntime.field("size", in: destination) as? NSValue)?.sizeValue) {
                    destSize = size
                }
                if let scale = (CineWallWallpaperRuntime.field("scaleFactor", in: destination) as? CGFloat) ??
                               ((CineWallWallpaperRuntime.field("scaleFactor", in: destination) as? NSNumber).map { CGFloat($0.doubleValue) }) {
                    scaleFactor = scale
                }
                if let did = (CineWallWallpaperRuntime.field("directDisplayID", in: destination) as? UInt32) ??
                             ((CineWallWallpaperRuntime.field("directDisplayID", in: destination) as? NSNumber)?.uint32Value) {
                    directDisplayID = did
                }
            }
            if let preview = CineWallWallpaperRuntime.field("isPreview", in: request) as? Bool {
                isPreview = preview
            }

            reload()
            guard let scene = selectScene(displayID: directDisplayID) else {
                CineWallWallpaperRuntime.log(
                    "acquire rejected: no scene for displayID=\(directDisplayID.map { String($0) } ?? "nil") (available scenes: \(configuration?.scenes.map { "\($0.displayID):\($0.projectPath)" }.joined(separator: ", ") ?? "none"))"
                )
                throw CineWallWallpaperRuntime.failure(
                    "No applied wallpaper is available for this display. Enable Lock Screen Sync in CineWall."
                )
            }
            CineWallWallpaperRuntime.log(
                "acquire accepted: id=\(id) directDisplayID=\(directDisplayID.map { String($0) } ?? "nil") sceneDisplayID=\(scene.displayID) scenePath=\(scene.projectPath) isPreview=\(isPreview) size=\(destSize) scale=\(scaleFactor)"
            )
            let acquisition = try surfaces.acquire(
                id: id, matches: { $0.displayID == directDisplayID && $0.preview == isPreview }
            ) { generation in
                try CineWallWallpaperSurface(
                    scene: scene, displayID: directDisplayID, size: destSize, scale: scaleFactor, preview: isPreview,
                    generation: generation
                )
            }
            let surface = acquisition.surface
            let generation = acquisition.generation
            if let mode = CineWallWallpaperRuntime.field("presentationMode", in: request) {
                surface.presentation = CineWallWallpaperRuntime.enumCase(mode)
            }
            if let activity = CineWallWallpaperRuntime.field("activityState", in: request) {
                surface.activity = CineWallWallpaperRuntime.enumCase(activity)
            }
            let ready: (Error?) -> Void = { [weak self, weak surface] error in
                guard let self, let surface,
                      self.surfaces.isCurrent(id: id, surface: surface, generation: generation)
                else {
                    reply(nil, CancellationError())
                    return
                }
                do {
                    if let error { throw error }
                    let contextReply = try CineWallWallpaperRuntime.contextReply(surface.context.contextId)
                    self.acknowledge(surface: surface)
                    CineWallWallpaperRuntime.log(
                        "acquire ready: id=\(id) displayID=\(scene.displayID) contextId=\(surface.context.contextId) elapsed=\(ContinuousClock.now - started)"
                    )
                    reply(contextReply, nil)
                } catch {
                    let errStr = "Acquire failed display=\(scene.displayID): \(error) localized=\(error.localizedDescription)"
                    try? errStr.write(to: CineWallWallpaperRuntime.exchange.appendingPathComponent("acquire-error.txt"), atomically: true, encoding: .utf8)
                    if !(error is CancellationError) {
                        CineWallWallpaperRuntime.log(errStr)
                        self.acknowledge(surface: surface, error: error)
                    }
                    reply(nil, error)
                }
            }
            if acquisition.isNew {
                surface.start(completion: ready)
            } else {
                surface.whenReady(completion: ready)
            }
        } catch {
            let errStr = "acquire top error: \(error) localized=\(error.localizedDescription)"
            try? errStr.write(to: CineWallWallpaperRuntime.exchange.appendingPathComponent("acquire-error.txt"), atomically: true, encoding: .utf8)
            CineWallWallpaperRuntime.log(errStr)
            reply(nil, error)
        }
    }

    public func update(id value: Any?, request: Any?) throws {
        guard let id = CineWallWallpaperRuntime.identifier(value), let surface = surfaces[id] ?? surfaces.values.first else {
            throw CineWallWallpaperRuntime.failure("Unknown native wallpaper surface.")
        }
        if let request {
            if let mode = CineWallWallpaperRuntime.field("presentationMode", in: request) {
                surface.presentation = CineWallWallpaperRuntime.enumCase(mode)
            }
            if let activity = CineWallWallpaperRuntime.field("activityState", in: request) {
                surface.activity = CineWallWallpaperRuntime.enumCase(activity)
            }
        }
        surface.applyPolicy()
    }

    public func invalidate(id value: Any?) {
        guard let id = CineWallWallpaperRuntime.identifier(value) else { return }
        CineWallWallpaperRuntime.log("Invalidate id=\(id)")
        surfaces.remove(id)
    }

    public func snapshot(id value: Any?, reply: @escaping (Any?, Error?) -> Void) {
        guard let surface = (CineWallWallpaperRuntime.identifier(value).flatMap { surfaces[$0] }) ?? surfaces.values.first else {
            reply(nil, CineWallWallpaperRuntime.failure("Unknown native wallpaper surface."))
            return
        }
        surface.snapshot(reply: reply)
    }
}
