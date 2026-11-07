//
//  LockScreenWallpaperService.swift
//  CineWall
//
//  ExtensionKit Lock Screen & Screen Saver Service.
//  Direct source-level parity with WallpaperMachine/App/Services/LockScreen/LockScreenWallpaperService.swift
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation

@MainActor
public final class LockScreenWallpaperService: ObservableObject {
    public static let shared = LockScreenWallpaperService()

    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var isBusy: Bool = false
    @Published public private(set) var status: String = "Off"
    @Published public private(set) var errorMessage: String? = nil

    private let fileManager = FileManager.default
    public let registration: LockScreenExtensionRegistration
    public let selection: LockScreenWallpaperSelection
    public let exchangeDirectory: URL

    private var activeWorkTask: Task<Void, Never>? = nil
    private var lastSyncedHash: String? = nil
    private var generation: UInt64 = 0

    public init(
        registration: LockScreenExtensionRegistration? = nil,
        selection: LockScreenWallpaperSelection? = nil,
        exchange: URL? = nil
    ) {
        let exchangeDir = exchange ?? LockScreenConfiguration.exchangeDirectory
        self.exchangeDirectory = exchangeDir
        self.registration = registration ?? LockScreenExtensionRegistration()
        self.selection = selection ?? LockScreenWallpaperSelection()

        try? fileManager.createDirectory(at: exchangeDir.appendingPathComponent("revisions"), withIntermediateDirectories: true)
    }

    // MARK: - Multi-Display UUID Resolution
    public static func resolveDisplayUUID(for displayID: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    public static func computeSHA256(for fileURL: URL) -> String? {
        guard let stream = InputStream(url: fileURL) else { return nil }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read < 0 { return nil }
            if read == 0 { break }
            hasher.update(data: Data(buffer.prefix(read)))
        }

        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Staging
    public func stageRevision(videoURL: URL) throws -> (hash: String, relProjectPath: String, relAssetsPath: String, filename: String) {
        guard let hash = Self.computeSHA256(for: videoURL) else {
            throw LockScreenFailure(message: "Failed to compute SHA-256 checksum for \(videoURL.lastPathComponent)")
        }

        let revisionRelDir = "revisions/\(hash)"
        let revisionDir = exchangeDirectory.appendingPathComponent(revisionRelDir, isDirectory: true)
        try fileManager.createDirectory(at: revisionDir, withIntermediateDirectories: true)

        let targetVideo = revisionDir.appendingPathComponent(videoURL.lastPathComponent)
        if !fileManager.fileExists(atPath: targetVideo.path) {
            do {
                try fileManager.linkItem(at: videoURL, to: targetVideo)
            } catch {
                try? fileManager.removeItem(at: targetVideo)
                try fileManager.copyItem(at: videoURL, to: targetVideo)
            }
        }

        let projectJSON = revisionDir.appendingPathComponent("project.json")
        if !fileManager.fileExists(atPath: projectJSON.path) {
            let metadata: [String: Any] = [
                "file": videoURL.lastPathComponent,
                "title": videoURL.deletingPathExtension().lastPathComponent,
                "type": "video"
            ]
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: projectJSON, options: .atomic)
        }

        return (
            hash: hash,
            relProjectPath: "\(revisionRelDir)/project.json",
            relAssetsPath: revisionRelDir,
            filename: videoURL.lastPathComponent
        )
    }

    // MARK: - Publishing to ExtensionKit
    public func publish(
        videoURL: URL,
        screens: [NSScreen] = NSScreen.screens,
        scalingMode: Int32 = 3
    ) async throws {
        isBusy = true
        errorMessage = nil
        status = "Syncing Lock Screen..."

        defer { isBusy = false }

        // 1. Prepare and stage video in exchange folder
        let staged = try stageRevision(videoURL: videoURL)
        lastSyncedHash = staged.hash

        // 2. Build multi-display scenes
        var scenes: [LockScreenScene] = []
        var displayUUIDs: Set<String> = []

        for screen in screens {
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
            guard screenNumber != 0 else { continue }
            if let uuid = Self.resolveDisplayUUID(for: screenNumber) {
                displayUUIDs.insert(uuid)
            }

            let scene = LockScreenScene(
                displayID: screenNumber,
                title: videoURL.deletingPathExtension().lastPathComponent,
                projectPath: staged.relProjectPath,
                assetsPath: staged.relAssetsPath,
                scalingMode: scalingMode,
                scalingFactor: 1.0,
                paused: false,
                framing: .centered,
                plainVideo: true,
                nativeVideoFile: staged.filename
            )
            scenes.append(scene)
        }

        if scenes.isEmpty {
            // Fallback for primary display
            let primaryScene = LockScreenScene(
                displayID: 0,
                title: videoURL.deletingPathExtension().lastPathComponent,
                projectPath: staged.relProjectPath,
                assetsPath: staged.relAssetsPath,
                scalingMode: scalingMode,
                scalingFactor: 1.0,
                paused: false,
                framing: .centered,
                plainVideo: true,
                nativeVideoFile: staged.filename
            )
            scenes.append(primaryScene)
        }

        let revision = UUID().uuidString
        let config = LockScreenConfiguration(
            revision: revision,
            scenes: scenes,
            lockScreenEnabled: true,
            screenSaverEnabled: true
        )

        // 3. Write configuration.json into exchange folder
        let configURL = exchangeDirectory.appendingPathComponent(LockScreenConfiguration.fileName)
        let configData = try JSONEncoder().encode(config)
        try configData.write(to: configURL, options: .atomic)

        // 4. Register extension with LaunchServices & pluginkit if needed
        _ = try? await registration.reconcile()

        // 5. Post Darwin notification so running extension instance wakes up
        postDarwinNotification()

        // 6. Synchronize macOS wallpaper store (Index.plist)
        try selection.synchronize(
            desktopDisplays: [],
            screenSaverDisplays: displayUUIDs,
            revision: revision
        )

        // 7. Wait briefly for extension acknowledgement
        try await awaitReadiness(for: config, timeout: .seconds(3))

        isEnabled = true
        status = "Lock Screen Synced"
    }

    private func awaitReadiness(for config: LockScreenConfiguration, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            var allReady = true
            for scene in config.scenes {
                let readyURL = exchangeDirectory.appendingPathComponent("ready-\(scene.displayID).json")
                guard fileManager.fileExists(atPath: readyURL.path),
                      let data = try? Data(contentsOf: readyURL),
                      let ack = try? JSONDecoder().decode(LockScreenReadiness.self, from: data),
                      ack.revision == config.revision else {
                    allReady = false
                    break
                }
            }
            if allReady { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    public func restoreSystemDefault() {
        isBusy = true
        defer { isBusy = false }

        // 1. Write empty shutdown config
        let emptyConfig = LockScreenConfiguration(
            revision: UUID().uuidString,
            scenes: [],
            lockScreenEnabled: false,
            screenSaverEnabled: false
        )
        let configURL = exchangeDirectory.appendingPathComponent(LockScreenConfiguration.fileName)
        if let data = try? JSONEncoder().encode(emptyConfig) {
            try? data.write(to: configURL, options: .atomic)
        }

        // 2. Revert Index.plist to original journaled entries
        try? selection.recover()

        // 3. Post Darwin notification
        postDarwinNotification()

        isEnabled = false
        status = "Off"
        lastSyncedHash = nil
    }

    private func postDarwinNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(LockScreenConfiguration.changedNotification as CFString),
            nil,
            nil,
            true
        )
    }
}
