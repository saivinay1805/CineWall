//
//  LockScreenWallpaperService.swift
//  CineWall
//
//  ThemeEngine Fast Engine (Apple Native Aerial Synchronization)
//  Syncs video wallpapers directly to macOS Lock Screen, Screensaver, and System Settings
//  via direct Apple Aerial manifest and com.apple.wallpaper Store injection.
//  Multi-display UUID mapping, atomic transactional journaling, and zero-black-screen reliability.
//

import AppKit
import AVFoundation
import Combine
import CryptoKit
import Darwin
import Foundation

@MainActor
public final class LockScreenWallpaperService: ObservableObject {
    public static let shared = LockScreenWallpaperService()

    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var isBusy: Bool = false
    @Published public private(set) var status: String = "Ready"
    @Published public private(set) var errorMessage: String? = nil
    @Published public private(set) var syncedAssetID: String? = nil

    private let fileManager = FileManager.default
    private let aerialCategoryID = "91F55C9A-8E4B-4C1D-9A8C-2B759F17A001"
    private let aerialSubcategoryID = "91F55C9A-8E4B-4C1D-9A8C-2B759F17A002"
    private let aerialProvider = "com.apple.wallpaper.choice.aerials"
    private let wallpaperStoreBackupName = "Index.plist.backup"

    private var wallpaperDir: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper", isDirectory: true)
    }

    private var manifestURL: URL {
        wallpaperDir.appendingPathComponent("aerials/manifest/entries.json")
    }

    private var storeURL: URL {
        wallpaperDir.appendingPathComponent("Store/Index.plist")
    }

    private var videosDir: URL {
        wallpaperDir.appendingPathComponent("aerials/videos", isDirectory: true)
    }

    private var thumbnailsDir: URL {
        wallpaperDir.appendingPathComponent("aerials/thumbnails", isDirectory: true)
    }

    private var journalURL: URL {
        let appSupport = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CineWall", isDirectory: true)
        try? fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: nil)
        return appSupport.appendingPathComponent("native-selection.plist")
    }

    public init() {
        checkCurrentStatus()
    }

    public func checkCurrentStatus() {
        guard let data = try? Data(contentsOf: storeURL),
              let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let defaultEntry = (root["SystemDefault"] as? [String: Any]) ?? (root["AllSpacesAndDisplays"] as? [String: Any]),
              let linked = (defaultEntry["Linked"] as? [String: Any]) ?? (defaultEntry["Desktop"] as? [String: Any]),
              let content = linked["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              (firstChoice["Provider"] as? String) == aerialProvider,
              let configData = firstChoice["Configuration"] as? Data,
              let config = (try? PropertyListSerialization.propertyList(from: configData, options: [], format: nil)) as? [String: Any],
              let aid = config["assetID"] as? String else {
            isEnabled = false
            status = "Off"
            return
        }
        syncedAssetID = aid
        isEnabled = true
        status = "Lock screen synced"
    }

    // MARK: - Multi-Display UUID Resolution
    public static func resolveDisplayUUID(for displayID: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // MARK: - Stable Asset ID
    public static func stableAerialAssetID(for sourceURL: URL) throws -> String {
        let resolved = sourceURL.resolvingSymlinksInPath()
        let attrs = try FileManager.default.attributesOfItem(atPath: resolved.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let raw = "cinewall|fast|\(resolved.path)|\(size)|\(Int64(date * 1000))"
        let hash = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02X", $0) }.joined()

        let s1 = String(hash[hash.startIndex..<hash.index(hash.startIndex, offsetBy: 8)])
        let s2 = String(hash[hash.index(hash.startIndex, offsetBy: 8)..<hash.index(hash.startIndex, offsetBy: 12)])
        let s3 = String(hash[hash.index(hash.startIndex, offsetBy: 12)..<hash.index(hash.startIndex, offsetBy: 16)])
        let s4 = String(hash[hash.index(hash.startIndex, offsetBy: 16)..<hash.index(hash.startIndex, offsetBy: 20)])
        let s5 = String(hash[hash.index(hash.startIndex, offsetBy: 20)..<hash.index(hash.startIndex, offsetBy: 32)])
        return "\(s1)-\(s2)-\(s3)-\(s4)-\(s5)"
    }

    // MARK: - Fast Engine Publishing
    public func publish(
        videoURL: URL,
        perDisplayVideoURLs: [UInt32: URL]? = nil,
        screens: [NSScreen] = NSScreen.screens,
        scalingMode: Int32 = 3
    ) async throws {
        isBusy = true
        errorMessage = nil
        status = "Syncing Lock Screen..."
        defer { isBusy = false }

        guard fileManager.fileExists(atPath: videoURL.path) else {
            throw NSError(domain: "CineWall", code: 404, userInfo: [NSLocalizedDescriptionKey: "Video file not found at \(videoURL.path)"])
        }

        try fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true, attributes: nil)

        // 1. Resolve screen mappings & asset IDs for each screen
        var displayUUIDs: [String: String] = [:] // displayUUID -> assetID
        var activeAssetIDs = Set<String>()

        let primaryAssetID = try Self.stableAerialAssetID(for: videoURL)
        activeAssetIDs.insert(primaryAssetID)

        // Register primary video first
        try registerSingleAerialAsset(sourceURL: videoURL, assetID: primaryAssetID)

        for screen in screens {
            let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) ?? 0
            guard screenNumber != 0 else { continue }
            guard let uuid = Self.resolveDisplayUUID(for: screenNumber) else { continue }

            let screenVideoURL = perDisplayVideoURLs?[screenNumber] ?? videoURL
            let screenAssetID: String
            if screenVideoURL == videoURL {
                screenAssetID = primaryAssetID
            } else {
                screenAssetID = try Self.stableAerialAssetID(for: screenVideoURL)
                activeAssetIDs.insert(screenAssetID)
                try registerSingleAerialAsset(sourceURL: screenVideoURL, assetID: screenAssetID)
            }
            displayUUIDs[uuid] = screenAssetID
        }

        // 2. Update aerials manifest (entries.json) preserving all currently active assets
        let title = videoURL.deletingPathExtension().lastPathComponent
        try updateAerialManifest(
            primaryAssetID: primaryAssetID,
            primaryTitle: title,
            activeAssetIDs: activeAssetIDs
        )

        // 3. Update Index.plist with com.apple.wallpaper.choice.aerials for all screens and spaces
        try updateWallpaperStore(primaryAssetID: primaryAssetID, perDisplayAssetIDs: displayUUIDs)

        // 4. Notify Darwin and restart WallpaperAgent + WallpaperAerialsExtension
        restartWallpaperAgent()

        syncedAssetID = primaryAssetID
        isEnabled = true
        status = "Lock screen synced"
    }

    private func registerSingleAerialAsset(sourceURL: URL, assetID: String) throws {
        let destVideoURL = videosDir.appendingPathComponent("\(assetID).mov")
        let destThumbURL = thumbnailsDir.appendingPathComponent("\(assetID).png")

        // Prepare Video: Instant APFS clonefile or fast copy
        let needsCopy: Bool
        if fileManager.fileExists(atPath: destVideoURL.path) {
            let srcSize = (try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let dstSize = (try? fileManager.attributesOfItem(atPath: destVideoURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            needsCopy = (srcSize != dstSize || srcSize == 0)
            if needsCopy {
                try? fileManager.removeItem(at: destVideoURL)
            }
        } else {
            needsCopy = true
        }

        if needsCopy {
            if Darwin.clonefile(sourceURL.path, destVideoURL.path, 0) != 0 {
                try fileManager.copyItem(at: sourceURL, to: destVideoURL)
            }
            try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destVideoURL.path)
        }

        // Prepare Thumbnail
        if !fileManager.fileExists(atPath: destThumbURL.path) {
            let asset = AVAsset(url: sourceURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: destThumbURL, options: .atomic)
                    try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destThumbURL.path)
                }
            }
        }
    }

    private func updateAerialManifest(
        primaryAssetID: String,
        primaryTitle: String,
        activeAssetIDs: Set<String>
    ) throws {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw NSError(domain: "CineWall", code: 1001, userInfo: [NSLocalizedDescriptionKey: "System aerial manifest not found at \(manifestURL.path)"])
        }

        let data = try Data(contentsOf: manifestURL)
        guard var root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              var categories = root["categories"] as? [[String: Any]],
              var assets = root["assets"] as? [[String: Any]] else {
            throw NSError(domain: "CineWall", code: 1005, userInfo: [NSLocalizedDescriptionKey: "Invalid aerial manifest structure."])
        }

        // Clean stale CineWall categories and assets
        categories.removeAll { ($0["id"] as? String) == aerialCategoryID }
        assets.removeAll { asset in
            let id = asset["id"] as? String ?? ""
            let cats = asset["categories"] as? [String] ?? []
            if cats.contains(aerialCategoryID) {
                return !activeAssetIDs.contains(id)
            }
            return false
        }

        let primaryThumbURL = thumbnailsDir.appendingPathComponent("\(primaryAssetID).png")
        let category: [String: Any] = [
            "id": aerialCategoryID,
            "localizedDescriptionKey": "CineWall Dynamic Wallpapers",
            "localizedNameKey": "CineWall",
            "preferredOrder": -200,
            "previewImage": primaryThumbURL.absoluteString,
            "representativeAssetID": primaryAssetID,
            "subcategories": [[
                "id": aerialSubcategoryID,
                "localizedDescriptionKey": "CineWall Dynamic Wallpapers",
                "localizedNameKey": "CineWall",
                "preferredOrder": 0,
                "previewImage": primaryThumbURL.absoluteString,
                "representativeAssetID": primaryAssetID
            ]]
        ]

        for assetID in activeAssetIDs {
            let thumbURL = thumbnailsDir.appendingPathComponent("\(assetID).png")
            let videoURL = videosDir.appendingPathComponent("\(assetID).mov")
            let shotID = "CINEWALL_\(assetID.replacingOccurrences(of: "-", with: "_"))"
            let assetEntry: [String: Any] = [
                "accessibilityLabel": primaryTitle,
                "categories": [aerialCategoryID],
                "id": assetID,
                "includeInShuffle": true,
                "localizedNameKey": primaryTitle,
                "pointsOfInterest": ["0": "\(shotID)_0"],
                "preferredOrder": 0,
                "previewImage": thumbURL.absoluteString,
                "shotID": shotID,
                "showInTopLevel": true,
                "subcategories": [aerialSubcategoryID],
                "url-4K-SDR-240FPS": videoURL.absoluteString,
                "variant": [
                    "appearance": "light",
                    "orientation": "landscape"
                ],
                "videoGravity": "resize"
            ]
            assets.append(assetEntry)
        }

        categories.insert(category, at: 0)
        root["categories"] = categories
        root["assets"] = assets
        root["version"] = 2

        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: manifestURL, options: .atomic)
    }

    private func updateWallpaperStore(primaryAssetID: String, perDisplayAssetIDs: [String: String]) throws {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            throw NSError(domain: "CineWall", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Wallpaper store index not found at \(storeURL.path)"])
        }

        let data = try Data(contentsOf: storeURL)
        guard var root = try PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: nil) as? [String: Any] else {
            throw NSError(domain: "CineWall", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Cannot deserialize store Index.plist"])
        }

        try backupWallpaperStoreIfNeeded(root: root)

        let now = Date()
        let defaultLinked = try makeAerialLinkedRecord(assetID: primaryAssetID, now: now)
        root["AllSpacesAndDisplays"] = defaultLinked
        root["SystemDefault"] = defaultLinked

        var displays = (root["Displays"] as? [String: Any]) ?? [:]
        for (dispUUID, assetID) in perDisplayAssetIDs {
            displays[dispUUID] = try makeAerialLinkedRecord(assetID: assetID, now: now)
        }
        for key in displays.keys {
            if perDisplayAssetIDs[key] == nil {
                displays[key] = defaultLinked
            }
        }
        root["Displays"] = displays

        if var spaces = root["Spaces"] as? [String: Any] {
            for (sKey, sVal) in spaces {
                if var spaceDict = sVal as? [String: Any] {
                    var spaceDisplays = (spaceDict["Displays"] as? [String: Any]) ?? [:]
                    for dKey in displays.keys {
                        let targetAssetID = perDisplayAssetIDs[dKey] ?? primaryAssetID
                        spaceDisplays[dKey] = try makeAerialLinkedRecord(assetID: targetAssetID, now: now)
                    }
                    spaceDict["Displays"] = spaceDisplays
                    spaceDict["Default"] = defaultLinked
                    spaces[sKey] = spaceDict
                }
            }
            root["Spaces"] = spaces
        }

        let outData = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let parentDir = storeURL.deletingLastPathComponent()
        let tempURL = parentDir.appendingPathComponent(".Index.plist.aerial_tmp.\(UUID().uuidString)")
        try outData.write(to: tempURL, options: .atomic)
        if fileManager.fileExists(atPath: storeURL.path) {
            _ = try fileManager.replaceItemAt(storeURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: storeURL)
        }
    }

    private func makeAerialLinkedRecord(assetID: String, now: Date) throws -> [String: Any] {
        let config = try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        let choice: [String: Any] = [
            "Configuration": config,
            "Files": [] as [Any],
            "Provider": aerialProvider
        ]
        let emptyOptionValues = (try? PropertyListSerialization.data(fromPropertyList: ["values": [String: Any]()], format: .binary, options: 0)) ?? Data()
        let content: [String: Any] = [
            "Choices": [choice],
            "EncodedOptionValues": emptyOptionValues,
            "Shuffle": "$null"
        ]
        return [
            "Type": "linked",
            "Linked": [
                "Content": content,
                "LastSet": now,
                "LastUse": now
            ]
        ]
    }

    private func backupWallpaperStoreIfNeeded(root: [String: Any]) throws {
        let backupURL = storeURL.deletingLastPathComponent().appendingPathComponent(wallpaperStoreBackupName)

        if isCineWallActiveInStore(root) {
            return
        }

        if !fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.copyItem(at: storeURL, to: backupURL)
        }

        if !fileManager.fileExists(atPath: journalURL.path) {
            var journal: [String: Any] = [:]
            for key in ["AllSpacesAndDisplays", "SystemDefault", "Displays", "Spaces"] {
                if let val = root[key] {
                    journal[key] = val
                }
            }
            if let journalData = try? PropertyListSerialization.data(fromPropertyList: journal, format: .binary, options: 0) {
                try? journalData.write(to: journalURL, options: .atomic)
            }
        }
    }

    private func isCineWallActiveInStore(_ root: [String: Any]) -> Bool {
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            if let dict = root[key] as? [String: Any],
               let linked = dict["Linked"] as? [String: Any],
               let content = linked["Content"] as? [String: Any],
               let choices = content["Choices"] as? [[String: Any]] {
                for c in choices {
                    if (c["Provider"] as? String) == aerialProvider,
                       let configData = c["Configuration"] as? Data,
                       let config = (try? PropertyListSerialization.propertyList(from: configData, options: [], format: nil)) as? [String: Any],
                       let assetID = config["assetID"] as? String {
                        if assetID == syncedAssetID { return true }
                    }
                }
            }
        }
        return false
    }

    // MARK: - Restore Original Wallpaper
    public func restoreSystemDefault() {
        isBusy = true
        defer { isBusy = false }

        let backupURL = storeURL.deletingLastPathComponent().appendingPathComponent(wallpaperStoreBackupName)
        var restored = false

        if fileManager.fileExists(atPath: journalURL.path),
           let jData = try? Data(contentsOf: journalURL),
           let journal = (try? PropertyListSerialization.propertyList(from: jData, options: [], format: nil)) as? [String: Any],
           let storeData = try? Data(contentsOf: storeURL),
           var root = (try? PropertyListSerialization.propertyList(from: storeData, options: [.mutableContainersAndLeaves], format: nil)) as? [String: Any] {

            for key in ["AllSpacesAndDisplays", "SystemDefault", "Displays", "Spaces"] {
                if let saved = journal[key] {
                    root[key] = saved
                } else {
                    root.removeValue(forKey: key)
                }
            }

            if let outData = try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0) {
                try? outData.write(to: storeURL, options: .atomic)
                restored = true
            }
            try? fileManager.removeItem(at: journalURL)
        }

        if !restored && fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: storeURL)
            try? fileManager.copyItem(at: backupURL, to: storeURL)
            restored = true
        }

        if fileManager.fileExists(atPath: manifestURL.path),
           let data = try? Data(contentsOf: manifestURL),
           var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var categories = root["categories"] as? [[String: Any]],
           var assets = root["assets"] as? [[String: Any]] {

            categories.removeAll { ($0["id"] as? String) == aerialCategoryID }
            assets.removeAll { asset in
                let cats = asset["categories"] as? [String] ?? []
                return cats.contains(aerialCategoryID)
            }
            root["categories"] = categories
            root["assets"] = assets
            root["version"] = 2
            if let updated = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? updated.write(to: manifestURL, options: .atomic)
            }
        }

        Self.purgeAerialsViewModelCache()
        restartWallpaperAgent()

        syncedAssetID = nil
        isEnabled = false
        status = "Off"
    }

    // MARK: - Restart Wallpaper Agent & Invalidate Caches
    public func restartWallpaperAgent() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.apple.wallpaper.choice.changed" as CFString),
            nil, nil, true
        )

        let procAgent = Process()
        procAgent.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        procAgent.arguments = ["-TERM", "WallpaperAgent"]
        try? procAgent.run()
        procAgent.waitUntilExit()

        let procAerials = Process()
        procAerials.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        procAerials.arguments = ["-TERM", "WallpaperAerialsExtension"]
        try? procAerials.run()
        procAerials.waitUntilExit()
    }

    public static func purgeAerialsViewModelCache() {
        let fm = FileManager.default
        var candidateDirs: [URL] = []

        var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(_CS_DARWIN_USER_CACHE_DIR, &pathBuffer, Int(PATH_MAX))
        if len > 0 {
            candidateDirs.append(URL(fileURLWithPath: String(cString: pathBuffer)))
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        candidateDirs.append(tmp.deletingLastPathComponent().appendingPathComponent("C", isDirectory: true))

        let varFolders = URL(fileURLWithPath: "/private/var/folders", isDirectory: true)
        if fm.fileExists(atPath: varFolders.path),
           let subdirs = try? fm.contentsOfDirectory(at: varFolders, includingPropertiesForKeys: nil) {
            for sub in subdirs {
                if let subsub = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) {
                    for s in subsub {
                        let cDir = s.appendingPathComponent("C", isDirectory: true)
                        if fm.fileExists(atPath: cDir.path) {
                            candidateDirs.append(cDir)
                        }
                    }
                }
            }
        }

        var seen = Set<String>()
        for base in candidateDirs {
            let p = base.standardizedFileURL.resolvingSymlinksInPath().path
            guard !seen.contains(p) else { continue }
            seen.insert(p)

            let vmCacheDir = base.appendingPathComponent("com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache", isDirectory: true)
            guard fm.fileExists(atPath: vmCacheDir.path),
                  let files = try? fm.contentsOfDirectory(at: vmCacheDir, includingPropertiesForKeys: nil) else { continue }
            for f in files {
                if f.lastPathComponent.contains("extension-com.apple.wallpaper.extension.aerials") {
                    try? fm.removeItem(at: f)
                }
            }
        }
    }

    // MARK: - Testing
    public func testLockScreenNow() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY) else {
            return
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else {
            return
        }
        typealias SACLockScreenImmediateFunc = @convention(c) () -> Void
        let lockFunc = unsafeBitCast(sym, to: SACLockScreenImmediateFunc.self)
        lockFunc()
    }
}
