import Cocoa
import AVFoundation
import CryptoKit
import VideoToolbox

// MARK: - macOS Lock Screen & Aerial Sync
extension AppDelegate {
    @objc func sessionUnlocked() {
        guard proManager.canUse(.lockScreenSync), lockScreenSyncEnabled else { return }
        guard idleWallpaperSyncMode == .fast else { return }

        let refreshURL: URL?
        if autoSyncIdleWallpaper, currentQueue.indices.contains(queueIndex) {
            refreshURL = currentQueue[queueIndex]
        } else if let lastPath = lastAutoSyncedMediaPath {
            refreshURL = URL(fileURLWithPath: lastPath)
        } else {
            refreshURL = nil
        }

        guard let sourceURL = refreshURL else { return }
        syncCurrentVideoToIdleWallpaper(showAlerts: false, sourceURL: sourceURL)
    }

    func scheduleFastModeLaunchRefreshIfNeeded() {
        guard proManager.canUse(.lockScreenSync), lockScreenSyncEnabled else { return }
        guard idleWallpaperSyncMode == .fast else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            guard self.proManager.canUse(.lockScreenSync), self.lockScreenSyncEnabled else { return }

            let refreshURL: URL?
            if self.currentQueue.indices.contains(self.queueIndex) {
                refreshURL = self.currentQueue[self.queueIndex]
            } else if let lastPath = self.lastAutoSyncedMediaPath {
                refreshURL = URL(fileURLWithPath: lastPath)
            } else {
                refreshURL = nil
            }

            guard let sourceURL = refreshURL else { return }
            self.syncCurrentVideoToIdleWallpaper(showAlerts: false, sourceURL: sourceURL)
        }
    }

    func syncCurrentVideoToIdleWallpaper(showAlerts: Bool = true, sourceURL: URL? = nil) {
        guard requireProAccess(for: .lockScreenSync) else { return }
        guard lockScreenSyncEnabled else {
            if showAlerts {
                showAlert(title: "Lock Screen Sync Off", message: "Turn on Lock Screen Sync in Settings first.")
            }
            return
        }
        let selectedURL = sourceURL ?? ((currentQueue.indices.contains(queueIndex)) ? currentQueue[queueIndex] : nil)
        guard let sourceURL = selectedURL else {
            if showAlerts {
                showAlert(title: "No Media Selected", message: "Play a video first, then sync it to the idle wallpaper system.")
            }
            return
        }

        let ext = sourceURL.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else {
            if showAlerts {
                showAlert(title: "Video Required", message: "The modern wallpaper system only accepts video assets. GIF sync is not implemented.")
            }
            return
        }

        let sourceTitle = sourceURL.deletingPathExtension().lastPathComponent
        let syncRequestID = beginIdleWallpaperSyncRequest()
        setIdleWallpaperSyncInProgress(true)
        idleWallpaperSyncQueue.async {
            do {
                try self.throwIfIdleWallpaperSyncCancelled(syncRequestID)
                self.lastCompatibleSyncDebugSummary = nil
                let assetID = try self.stableAerialAssetID(for: sourceURL)
                try self.registerVideoWithWallpaperSystem(sourceURL: sourceURL, assetID: assetID, displayName: sourceTitle, syncRequestID: syncRequestID)
                try self.throwIfIdleWallpaperSyncCancelled(syncRequestID)
                self.syncedAerialAssetID = assetID
                self.lastAutoSyncedMediaPath = sourceURL.path
                self.saveSettings()
                self.restartWallpaperAgent()
                self.setIdleWallpaperSyncInProgress(false, requestID: syncRequestID)
                guard showAlerts else { return }
                DispatchQueue.main.async {
                    let debugSummary = self.lastCompatibleSyncDebugSummary.map { "\n\n\($0)" } ?? ""
                    self.showAlert(title: "Idle Wallpaper Updated", message: "\"\(sourceTitle)\" was registered with the macOS wallpaper system.\(debugSummary)")
                }
            } catch {
                self.setIdleWallpaperSyncInProgress(false, requestID: syncRequestID)
                guard !self.isIdleWallpaperSyncCancellation(error), self.isIdleWallpaperSyncRequestCurrent(syncRequestID) else { return }
                guard showAlerts else { return }
                DispatchQueue.main.async {
                    let debugSummary = self.lastCompatibleSyncDebugSummary.map { "\n\n\($0)" } ?? ""
                    self.showAlert(title: "Sync Failed", message: "\(error.localizedDescription)\(debugSummary)")
                }
            }
        }
    }
    func scheduleIdleWallpaperSyncIfNeeded() {
        idleSyncWorkItem?.cancel()
        guard proManager.canUse(.lockScreenSync) else { return }
        guard lockScreenSyncEnabled else { return }
        guard autoSyncIdleWallpaper, currentQueue.indices.contains(queueIndex) else { return }
        let sourceURL = currentQueue[queueIndex]
        let ext = sourceURL.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext), lastAutoSyncedMediaPath != sourceURL.path else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.syncCurrentVideoToIdleWallpaper(showAlerts: false, sourceURL: sourceURL)
        }
        idleSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: workItem)
    }


    func registerVideoWithWallpaperSystem(sourceURL: URL, assetID: String, displayName: String, syncRequestID: Int) throws {
        let fileManager = FileManager.default
        let wallpaperRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper", isDirectory: true)
        let aerialsRoot = wallpaperRoot.appendingPathComponent("aerials", isDirectory: true)
        let manifestURL = aerialsRoot.appendingPathComponent("manifest/entries.json")
        let storeURL = wallpaperRoot.appendingPathComponent("Store/Index.plist")
        let videosDir = aerialsRoot.appendingPathComponent("videos", isDirectory: true)
        let thumbnailsDir = aerialsRoot.appendingPathComponent("thumbnails", isDirectory: true)

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw NSError(domain: "CineWall", code: 1001, userInfo: [NSLocalizedDescriptionKey: "The system aerial manifest was not found at \(manifestURL.path)."])
        }
        guard fileManager.fileExists(atPath: storeURL.path) else {
            throw NSError(domain: "CineWall", code: 1002, userInfo: [NSLocalizedDescriptionKey: "The wallpaper store index was not found at \(storeURL.path)."])
        }

        try backupWallpaperStoreIfNeeded(storeURL: storeURL, manifestURL: manifestURL)

        try fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true, attributes: nil)

        let title = displayName.isEmpty ? "CineWall" : displayName
        let videoURL: URL
        switch idleWallpaperSyncMode {
        case .fast:
            videoURL = videosDir.appendingPathComponent("\(assetID).mov")
        case .compatible:
            videoURL = videosDir.appendingPathComponent("\(assetID).mov")
        }
        let thumbnailURL = thumbnailsDir.appendingPathComponent("\(assetID).png")

        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        try cleanupCineWallEntries(from: manifestURL)
        if let previousAssetID = syncedAerialAssetID {
            try cleanupLocalCineWallFiles(assetID: previousAssetID, videosDir: videosDir, thumbnailsDir: thumbnailsDir)
        }

        if fileManager.fileExists(atPath: videoURL.path) { try fileManager.removeItem(at: videoURL) }
        try prepareAerialVideo(sourceURL: sourceURL, destinationURL: videoURL, syncRequestID: syncRequestID)
        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        try writeThumbnail(for: sourceURL, destinationURL: thumbnailURL)
        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: videoURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: thumbnailURL.path)
        try updateAerialManifest(manifestURL: manifestURL, assetID: assetID, title: title, videoURL: videoURL, thumbnailURL: thumbnailURL)
        try updateWallpaperStore(storeURL: storeURL, assetID: assetID)
    }

    func cleanupCineWallEntries(from manifestURL: URL) throws {
        let data = try Data(contentsOf: manifestURL)
        guard var root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              var categories = root["categories"] as? [[String: Any]],
              var assets = root["assets"] as? [[String: Any]] else {
            throw NSError(domain: "CineWall", code: 1003, userInfo: [NSLocalizedDescriptionKey: "The aerial manifest has an unexpected format."])
        }

        let fileManager = FileManager.default
        let staleAssets = assets.filter { asset in
            let categoryIDs = asset["categories"] as? [String] ?? []
            let subcategoryIDs = asset["subcategories"] as? [String] ?? []
            return categoryIDs.contains(cineWallAerialCategoryID) || subcategoryIDs.contains(cineWallAerialSubcategoryID)
        }

        for asset in staleAssets {
            for key in ["url-4K-SDR-240FPS", "previewImage"] {
                guard let value = asset[key] as? String, value.hasPrefix("file://"), let url = URL(string: value), fileManager.fileExists(atPath: url.path) else { continue }
                try? fileManager.removeItem(at: url)
            }
        }

        assets.removeAll { asset in
            let categoryIDs = asset["categories"] as? [String] ?? []
            let subcategoryIDs = asset["subcategories"] as? [String] ?? []
            return categoryIDs.contains(cineWallAerialCategoryID) || subcategoryIDs.contains(cineWallAerialSubcategoryID)
        }
        categories.removeAll { ($0["id"] as? String) == cineWallAerialCategoryID }

        root["categories"] = categories
        root["assets"] = assets
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: manifestURL, options: .atomic)
    }

    func cleanupLocalCineWallFiles(assetID: String, videosDir: URL, thumbnailsDir: URL) throws {
        let fileManager = FileManager.default
        for ext in ["mov", "mp4", "m4v"] {
            let url = videosDir.appendingPathComponent("\(assetID).\(ext)")
            if fileManager.fileExists(atPath: url.path) { try? fileManager.removeItem(at: url) }
        }
        let pngURL = thumbnailsDir.appendingPathComponent("\(assetID).png")
        if fileManager.fileExists(atPath: pngURL.path) { try? fileManager.removeItem(at: pngURL) }
    }

    func writeThumbnail(for sourceURL: URL, destinationURL: URL) throws {
        let asset = AVAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let duration = asset.duration.seconds
        let requestedTime = CMTime(seconds: duration.isFinite && duration > 1.0 ? 1.0 : 0.0, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: requestedTime, actualTime: nil)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CineWall", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Failed to create a PNG thumbnail for the selected video."])
        }
        try data.write(to: destinationURL, options: .atomic)
    }

    func setDesktopWallpaperSnapshotForCurrentMedia() throws {
        guard currentQueue.indices.contains(queueIndex) else { return }
        let sourceURL = currentQueue[queueIndex]
        guard ["mp4", "mov", "m4v"].contains(sourceURL.pathExtension.lowercased()) else { return }

        let fileManager = FileManager.default
        let snapshotDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CineWall/DesktopSnapshot", isDirectory: true)
        try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true, attributes: nil)

        let snapshotURL = snapshotDirectory.appendingPathComponent("last-fast-mode-wallpaper.jpg")
        try writeDesktopWallpaperSnapshot(for: sourceURL, destinationURL: snapshotURL)

        let workspace = NSWorkspace.shared
        let options = workspace.desktopImageOptions(for: NSScreen.main ?? NSScreen.screens.first!) ?? [:]
        for screen in NSScreen.screens {
            try? workspace.setDesktopImageURL(snapshotURL, for: screen, options: options)
        }
    }

    func writeDesktopWallpaperSnapshot(for sourceURL: URL, destinationURL: URL) throws {
        let asset = AVAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let activePlayer = (activePlayerIndex == 0) ? playerA : playerB
        let currentTime = activePlayer?.currentTime() ?? .zero
        let duration = asset.duration
        let requestedTime: CMTime
        if currentTime.isValid, currentTime.seconds.isFinite, currentTime.seconds > 0 {
            let safeSeconds = min(currentTime.seconds, max(duration.seconds - 0.05, 0))
            requestedTime = CMTime(seconds: safeSeconds, preferredTimescale: 600)
        } else {
            requestedTime = CMTime(seconds: duration.seconds.isFinite && duration.seconds > 1.0 ? 1.0 : 0.0, preferredTimescale: 600)
        }

        let cgImage = try generator.copyCGImage(at: requestedTime, actualTime: nil)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw NSError(domain: "CineWall", code: 1091, userInfo: [NSLocalizedDescriptionKey: "Failed to create a desktop wallpaper snapshot from the current video."])
        }
        try data.write(to: destinationURL, options: .atomic)
    }

    func clearIdleWallpaperStateForFastModeQuit() throws {
        let fileManager = FileManager.default
        let wallpaperRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper", isDirectory: true)
        let aerialsRoot = wallpaperRoot.appendingPathComponent("aerials", isDirectory: true)
        let manifestURL = aerialsRoot.appendingPathComponent("manifest/entries.json")
        let storeURL = wallpaperRoot.appendingPathComponent("Store/Index.plist")
        let videosDir = aerialsRoot.appendingPathComponent("videos", isDirectory: true)
        let thumbnailsDir = aerialsRoot.appendingPathComponent("thumbnails", isDirectory: true)

        guard fileManager.fileExists(atPath: manifestURL.path), fileManager.fileExists(atPath: storeURL.path) else { return }

        let fallbackAssetID = try firstNonCineWallAssetID(from: manifestURL)
        try cleanupCineWallEntries(from: manifestURL)
        if let previousAssetID = syncedAerialAssetID {
            try cleanupLocalCineWallFiles(assetID: previousAssetID, videosDir: videosDir, thumbnailsDir: thumbnailsDir)
        }
        if try restorePreviousWallpaperStoreIfAvailable(storeURL: storeURL) {
            syncedAerialAssetID = nil
            restartWallpaperAgent()
            return
        }
        if let fallbackAssetID {
            try updateWallpaperStore(storeURL: storeURL, assetID: fallbackAssetID)
        }
        syncedAerialAssetID = nil
        restartWallpaperAgent()
    }

    func cineWallBackupDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CineWall/WallpaperBackup", isDirectory: true)
    }

    func cineWallWallpaperStoreBackupURL() -> URL {
        cineWallBackupDirectoryURL().appendingPathComponent(cineWallWallpaperStoreBackupFileName)
    }

    func backupWallpaperStoreIfNeeded(storeURL: URL, manifestURL: URL) throws {
        let backupURL = cineWallWallpaperStoreBackupURL()
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: backupURL.path) {
            return
        }

        if let currentAssetID = try currentWallpaperStoreAssetID(storeURL: storeURL),
           try isCineWallAssetID(currentAssetID, manifestURL: manifestURL) {
            return
        }

        try fileManager.createDirectory(at: cineWallBackupDirectoryURL(), withIntermediateDirectories: true, attributes: nil)
        try fileManager.copyItem(at: storeURL, to: backupURL)
    }

    func restorePreviousWallpaperStoreIfAvailable(storeURL: URL) throws -> Bool {
        let backupURL = cineWallWallpaperStoreBackupURL()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupURL.path) else { return false }

        if fileManager.fileExists(atPath: storeURL.path) {
            try fileManager.removeItem(at: storeURL)
        }
        try fileManager.copyItem(at: backupURL, to: storeURL)
        try? fileManager.removeItem(at: backupURL)
        return true
    }

    func currentWallpaperStoreAssetID(storeURL: URL) throws -> String? {
        let data = try Data(contentsOf: storeURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any],
              let systemDefault = root["SystemDefault"] as? [String: Any],
              let linked = systemDefault["Linked"] as? [String: Any],
              let content = linked["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first,
              let configurationData = choice["Configuration"] as? Data,
              let configuration = try PropertyListSerialization.propertyList(from: configurationData, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        return configuration["assetID"] as? String
    }

    func isCineWallAssetID(_ assetID: String, manifestURL: URL) throws -> Bool {
        if syncedAerialAssetID == assetID {
            return true
        }

        let data = try Data(contentsOf: manifestURL)
        guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else {
            return false
        }

        return assets.contains { asset in
            guard (asset["id"] as? String) == assetID else { return false }
            let categoryIDs = asset["categories"] as? [String] ?? []
            let subcategoryIDs = asset["subcategories"] as? [String] ?? []
            return categoryIDs.contains(cineWallAerialCategoryID) || subcategoryIDs.contains(cineWallAerialSubcategoryID)
        }
    }

    func firstNonCineWallAssetID(from manifestURL: URL) throws -> String? {
        let data = try Data(contentsOf: manifestURL)
        guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else {
            throw NSError(domain: "CineWall", code: 1092, userInfo: [NSLocalizedDescriptionKey: "The aerial manifest has an unexpected format."])
        }

        for asset in assets {
            let categoryIDs = asset["categories"] as? [String] ?? []
            let subcategoryIDs = asset["subcategories"] as? [String] ?? []
            if categoryIDs.contains(cineWallAerialCategoryID) || subcategoryIDs.contains(cineWallAerialSubcategoryID) {
                continue
            }
            if let assetID = asset["id"] as? String, !assetID.isEmpty {
                return assetID
            }
        }

        return nil
    }

    func prepareAerialVideo(sourceURL: URL, destinationURL: URL, syncRequestID: Int) throws {
        switch idleWallpaperSyncMode {
        case .fast:
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        case .compatible:
            try exportCompatibleVideoToAerialMovie(sourceURL: sourceURL, destinationURL: destinationURL, syncRequestID: syncRequestID)
        }
    }

    func exportCompatibleVideoToAerialMovie(sourceURL: URL, destinationURL: URL, syncRequestID: Int) throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent("CineWallCompatibleExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let candidateURL = temporaryDirectory.appendingPathComponent("candidate.mov")
        let hybridURL = temporaryDirectory.appendingPathComponent("hybrid.mov")
        let templateURL = try selectBackdropTemplate(for: sourceURL)
        lastCompatibleSyncDebugSummary = "Compatible mode used Backdrop-template hybrid export.\nTemplate: \(templateURL.lastPathComponent)"

        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        try exportCandidateVideoForBackdropHybrid(sourceURL: sourceURL, destinationURL: candidateURL, syncRequestID: syncRequestID)
        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        try runBackdropHybridizer(templateURL: templateURL, candidateURL: candidateURL, destinationURL: hybridURL, syncRequestID: syncRequestID)
        try throwIfIdleWallpaperSyncCancelled(syncRequestID)

        guard fileManager.fileExists(atPath: hybridURL.path) else {
            throw NSError(domain: "CineWall", code: 1016, userInfo: [NSLocalizedDescriptionKey: "The Backdrop-compatible hybrid export did not produce an output file."])
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: hybridURL, to: destinationURL)
    }

    func createMain10PixelBufferPool(renderSize: CGSize) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: renderSize.width,
            kCVPixelBufferHeightKey as String: renderSize.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(domain: "CineWall", code: 1017, userInfo: [NSLocalizedDescriptionKey: "Failed to create a 10-bit full-range pixel buffer pool."])
        }
        return pool
    }

    func makeMain10PixelBuffer(from sourcePixelBuffer: CVPixelBuffer, using pool: CVPixelBufferPool, transferSession: VTPixelTransferSession) -> CVPixelBuffer? {
        var destinationPixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationPixelBuffer)
        guard createStatus == kCVReturnSuccess, let destinationPixelBuffer else { return nil }

        applyRec709Metadata(to: sourcePixelBuffer)
        applyRec709Metadata(to: destinationPixelBuffer)

        let transferStatus = VTPixelTransferSessionTransferImage(transferSession, from: sourcePixelBuffer, to: destinationPixelBuffer)
        guard transferStatus == noErr else { return nil }
        return destinationPixelBuffer
    }

    func applyRec709Metadata(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    func preferredFrameDuration(for track: AVAssetTrack) -> CMTime {
        if track.minFrameDuration.isValid, track.minFrameDuration.seconds > 0 {
            return track.minFrameDuration
        }

        let nominalFrameRate = track.nominalFrameRate
        if nominalFrameRate > 0 {
            let timescale = max(Int32((nominalFrameRate * 1000).rounded()), 600)
            let value = max(Int64((Double(timescale) / Double(nominalFrameRate)).rounded()), 1)
            return CMTime(value: value, timescale: timescale)
        }

        return CMTime(value: 1, timescale: 30)
    }

    func preferredFrameRate(for track: AVAssetTrack, frameDuration: CMTime) -> Double {
        let nominalFrameRate = Double(track.nominalFrameRate)
        if nominalFrameRate > 0 {
            return nominalFrameRate
        }

        let durationSeconds = frameDuration.seconds
        if durationSeconds.isFinite, durationSeconds > 0 {
            return 1.0 / durationSeconds
        }

        return 30
    }

    func preferredAverageBitRate(for track: AVAssetTrack, renderSize: CGSize) -> Int {
        let estimatedDataRate = Int(track.estimatedDataRate.rounded())
        if estimatedDataRate > 0 {
            return max(estimatedDataRate, 2_000_000)
        }

        return max(Int(renderSize.width * renderSize.height), 2_000_000)
    }

    func sampleBufferDuration(_ sampleBuffer: CMSampleBuffer, fallback: CMTime) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.seconds > 0 {
            return duration
        }

        return fallback
    }

    func selectBackdropTemplate(for sourceURL: URL) throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "CineWall", code: 1023, userInfo: [NSLocalizedDescriptionKey: "The selected file does not contain a video track."])
        }

        let transformedSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let renderSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
        let sourceFrameRate = max(preferredFrameRate(for: videoTrack, frameDuration: preferredFrameDuration(for: videoTrack)), 1)

        let backdropCacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BackdropWallpaper/.cache", isDirectory: true)
        let templateURLs = try FileManager.default.contentsOfDirectory(at: backdropCacheURL, includingPropertiesForKeys: nil)
            .filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }

        guard !templateURLs.isEmpty else {
            throw NSError(domain: "CineWall", code: 1024, userInfo: [NSLocalizedDescriptionKey: "Backdrop-compatible mode needs local Backdrop templates, but none were found in \(backdropCacheURL.path). Open Backdrop once so it generates its cached wallpapers, then try again."])
        }

        var bestURL: URL?
        var bestScore = Double.greatestFiniteMagnitude

        for templateURL in templateURLs {
            let templateAsset = AVURLAsset(url: templateURL)
            guard let templateVideoTrack = templateAsset.tracks(withMediaType: .video).first else { continue }
            let templateSize = CGSize(width: templateVideoTrack.naturalSize.width, height: templateVideoTrack.naturalSize.height)
            let templateFrameRate = max(Double(templateVideoTrack.nominalFrameRate), 1)

            let sizeScore = abs(Double(renderSize.width - templateSize.width)) + abs(Double(renderSize.height - templateSize.height))
            let aspectRatio = max(renderSize.width, 1) / max(renderSize.height, 1)
            let templateAspectRatio = max(templateSize.width, 1) / max(templateSize.height, 1)
            let aspectScore = abs(Double(aspectRatio - templateAspectRatio)) * 10_000
            let frameRateScore = abs(sourceFrameRate - templateFrameRate) * 100
            let score = sizeScore * 10 + aspectScore + frameRateScore

            if score < bestScore {
                bestScore = score
                bestURL = templateURL
            }
        }

        guard let bestURL else {
            throw NSError(domain: "CineWall", code: 1025, userInfo: [NSLocalizedDescriptionKey: "Failed to find a usable Backdrop template in \(backdropCacheURL.path)."])
        }
        return bestURL
    }

    func exportCandidateVideoForBackdropHybrid(sourceURL: URL, destinationURL: URL, syncRequestID: Int) throws {
        let ffmpegURL = try locateFFmpegBinary()
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "CineWall", code: 1030, userInfo: [NSLocalizedDescriptionKey: "The selected file does not contain a video track."])
        }
        let transformedSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let renderSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
        let frameRate = max(preferredFrameRate(for: videoTrack, frameDuration: preferredFrameDuration(for: videoTrack)), 1)
        let keyframeInterval = max(Int(frameRate.rounded()) * 2, 1)
        let bitRateKbps = preferredHybridBitRateKbps(for: videoTrack, renderSize: renderSize)

        let hardwareArguments = backdropHybridCandidateArguments(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            bitRateKbps: bitRateKbps,
            keyframeInterval: keyframeInterval,
            useHardwareHEVC: true
        )

        do {
            try runExternalProcess(executableURL: ffmpegURL, arguments: hardwareArguments, failureCode: 1026, failurePrefix: "Failed to create the Backdrop-compatible candidate video with hardware HEVC", syncRequestID: syncRequestID)
        } catch {
            try throwIfIdleWallpaperSyncCancelled(syncRequestID)
            let softwareArguments = backdropHybridCandidateArguments(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                bitRateKbps: bitRateKbps,
                keyframeInterval: keyframeInterval,
                useHardwareHEVC: false
            )
            try runExternalProcess(executableURL: ffmpegURL, arguments: softwareArguments, failureCode: 1031, failurePrefix: "Failed to create the Backdrop-compatible candidate video with software HEVC after hardware fallback", syncRequestID: syncRequestID)
        }
    }

    func preferredHybridBitRateKbps(for track: AVAssetTrack, renderSize: CGSize) -> Int {
        let estimatedKbps = Int(track.estimatedDataRate / 1000.0)
        let pixelCount = Int(renderSize.width * renderSize.height)

        if pixelCount >= 3_840 * 2_160 {
            return max(estimatedKbps, 12_000)
        }
        return max(estimatedKbps, 4_500)
    }

    func backdropHybridCandidateArguments(sourceURL: URL, destinationURL: URL, bitRateKbps: Int, keyframeInterval: Int, useHardwareHEVC: Bool) -> [String] {
        if useHardwareHEVC {
            return [
                "-y",
                "-loglevel", "error",
                "-i", sourceURL.path,
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-c:v", "hevc_videotoolbox",
                "-allow_sw", "1",
                "-profile:v", "main10",
                "-pix_fmt", "p010le",
                "-bf", "0",
                "-b:v", "\(bitRateKbps)k",
                "-maxrate", "\(Int(Double(bitRateKbps) * 1.35))k",
                "-bufsize", "\(bitRateKbps * 2)k",
                "-g", "\(keyframeInterval)",
                "-tag:v", "hvc1",
                "-video_track_timescale", "600",
                "-fps_mode", "passthrough",
                "-c:a", "pcm_s16le",
                "-ar", "48000",
                "-ac", "2",
                destinationURL.path
            ]
        }

        return [
            "-y",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-c:v", "libx265",
            "-pix_fmt", "yuv420p10le",
            "-preset", "veryfast",
            "-tag:v", "hvc1",
            "-bf", "0",
            "-x265-params", "keyint=\(keyframeInterval):min-keyint=\(keyframeInterval):open-gop=0:bframes=0:no-b-adapt=1:repeat-headers=1:pools=4",
            "-video_track_timescale", "600",
            "-fps_mode", "passthrough",
            "-c:a", "pcm_s16le",
            "-ar", "48000",
            "-ac", "2",
            destinationURL.path
        ]
    }

    func runBackdropHybridizer(templateURL: URL, candidateURL: URL, destinationURL: URL, syncRequestID: Int) throws {
        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        do {
            try BackdropHybridizer.buildHybridMovie(templateURL: templateURL, candidateURL: candidateURL, destinationURL: destinationURL)
        } catch {
            let message = error.localizedDescription.isEmpty ? "Failed to build the Backdrop-compatible hybrid movie." : "Failed to build the Backdrop-compatible hybrid movie.\n\(error.localizedDescription)"
            throw NSError(domain: "CineWall", code: 1028, userInfo: [NSLocalizedDescriptionKey: message])
        }
        try throwIfIdleWallpaperSyncCancelled(syncRequestID)
    }

    func locateFFmpegBinary() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]

        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        throw NSError(domain: "CineWall", code: 1029, userInfo: [NSLocalizedDescriptionKey: "Compatible mode now depends on ffmpeg with HEVC/x265 support, but ffmpeg was not found in a standard location."])
    }

    func runExternalProcess(executableURL: URL, arguments: [String], failureCode: Int, failurePrefix: String, syncRequestID: Int? = nil) throws {
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        if let syncRequestID {
            try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        }
        try task.run()
        if let syncRequestID {
            registerActiveIdleWallpaperProcess(task, requestID: syncRequestID)
        }
        task.waitUntilExit()
        if let syncRequestID {
            clearActiveIdleWallpaperProcess(task, requestID: syncRequestID)
            try throwIfIdleWallpaperSyncCancelled(syncRequestID)
        }

        guard task.terminationStatus == 0 else {
            let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            let combined = [stderrText, stdoutText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let message = combined.isEmpty ? failurePrefix : "\(failurePrefix).\n\(combined)"
            throw NSError(domain: "CineWall", code: failureCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func beginIdleWallpaperSyncRequest() -> Int {
        idleWallpaperSyncStateQueue.sync {
            idleWallpaperSyncRequestCounter += 1
            latestIdleWallpaperSyncRequestID = idleWallpaperSyncRequestCounter
            if let activeIdleWallpaperProcess, activeIdleWallpaperProcess.isRunning {
                activeIdleWallpaperProcess.terminate()
            }
            return latestIdleWallpaperSyncRequestID
        }
    }

    func cancelActiveIdleWallpaperSync() {
        idleSyncWorkItem?.cancel()
        idleWallpaperSyncStateQueue.sync {
            idleWallpaperSyncRequestCounter += 1
            latestIdleWallpaperSyncRequestID = idleWallpaperSyncRequestCounter
            if let activeIdleWallpaperProcess, activeIdleWallpaperProcess.isRunning {
                activeIdleWallpaperProcess.terminate()
            }
            activeIdleWallpaperProcess = nil
        }
        setIdleWallpaperSyncInProgress(false)
    }

    func isIdleWallpaperSyncRequestCurrent(_ requestID: Int) -> Bool {
        idleWallpaperSyncStateQueue.sync { latestIdleWallpaperSyncRequestID == requestID }
    }

    func registerActiveIdleWallpaperProcess(_ process: Process, requestID: Int) {
        idleWallpaperSyncStateQueue.sync {
            guard latestIdleWallpaperSyncRequestID == requestID else {
                if process.isRunning {
                    process.terminate()
                }
                return
            }
            activeIdleWallpaperProcess = process
        }
    }

    func clearActiveIdleWallpaperProcess(_ process: Process, requestID: Int) {
        idleWallpaperSyncStateQueue.sync {
            guard latestIdleWallpaperSyncRequestID == requestID, activeIdleWallpaperProcess === process else { return }
            activeIdleWallpaperProcess = nil
        }
    }

    func setIdleWallpaperSyncInProgress(_ inProgress: Bool, requestID: Int? = nil) {
        var shouldRefreshUI = false
        idleWallpaperSyncStateQueue.sync {
            if let requestID, latestIdleWallpaperSyncRequestID != requestID {
                return
            }
            guard idleWallpaperSyncInProgress != inProgress else { return }
            idleWallpaperSyncInProgress = inProgress
            shouldRefreshUI = true
        }
        guard shouldRefreshUI else { return }
        DispatchQueue.main.async { [weak self] in
            self?.liquidController?.refreshUI()
        }
    }

    func idleWallpaperSyncCancelledError() -> NSError {
        NSError(domain: "CineWall", code: 1090, userInfo: [NSLocalizedDescriptionKey: "Idle wallpaper sync was superseded by a newer video selection."])
    }

    func isIdleWallpaperSyncCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "CineWall" && nsError.code == 1090
    }

    func throwIfIdleWallpaperSyncCancelled(_ requestID: Int) throws {
        guard isIdleWallpaperSyncRequestCurrent(requestID) else {
            throw idleWallpaperSyncCancelledError()
        }
    }

    func stableAerialAssetID(for sourceURL: URL) throws -> String {
        let resolvedURL = sourceURL.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let payload = "cinewall|\(idleWallpaperSyncMode.rawValue)|\(resolvedURL.path)|\(fileSize)|\(Int64(modified * 1000))"
        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        return "\(hexSegment(hex, 0, 8))-\(hexSegment(hex, 8, 12))-\(hexSegment(hex, 12, 16))-\(hexSegment(hex, 16, 20))-\(hexSegment(hex, 20, 32))"
    }

    func hexSegment(_ value: String, _ start: Int, _ end: Int) -> String {
        let startIndex = value.index(value.startIndex, offsetBy: start)
        let endIndex = value.index(value.startIndex, offsetBy: end)
        return String(value[startIndex..<endIndex])
    }

    func updateAerialManifest(manifestURL: URL, assetID: String, title: String, videoURL: URL, thumbnailURL: URL) throws {
        let data = try Data(contentsOf: manifestURL)
        guard var root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              var categories = root["categories"] as? [[String: Any]],
              var assets = root["assets"] as? [[String: Any]] else {
            throw NSError(domain: "CineWall", code: 1005, userInfo: [NSLocalizedDescriptionKey: "The aerial manifest has an unexpected format."])
        }

        let categoryEntry: [String: Any] = [
            "id": cineWallAerialCategoryID,
            "localizedDescriptionKey": "Use CineWall to change custom wallpapers",
            "localizedNameKey": "CineWall",
            "preferredOrder": 0,
            "previewImage": thumbnailURL.absoluteString,
            "representativeAssetID": assetID,
            "subcategories": [[
                "id": cineWallAerialSubcategoryID,
                "localizedDescriptionKey": "Use CineWall to change custom wallpapers",
                "localizedNameKey": "CineWall",
                "preferredOrder": 0,
                "previewImage": thumbnailURL.absoluteString,
                "representativeAssetID": assetID
            ]]
        ]

        let shotID = "CINEWALL_\(assetID.prefix(8))"
        let assetEntry: [String: Any] = [
            "accessibilityLabel": title,
            "categories": [cineWallAerialCategoryID],
            "id": assetID,
            "includeInShuffle": true,
            "localizedNameKey": title,
            "pointsOfInterest": ["0": "\(shotID)_0"],
            "preferredOrder": 0,
            "previewImage": thumbnailURL.absoluteString,
            "shotID": shotID,
            "showInTopLevel": true,
            "subcategories": [cineWallAerialSubcategoryID],
            "url-4K-SDR-240FPS": videoURL.absoluteString
        ]

        categories.append(categoryEntry)
        assets.append(assetEntry)
        root["categories"] = categories
        root["assets"] = assets

        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: manifestURL, options: .atomic)
    }

    struct DisplayInfo {
        let displayID: UInt32
        let name: String
    }

    func resolveDisplayMap() -> [String: DisplayInfo] {
        var map: [String: DisplayInfo] = [:]
        
        if let configClass = NSClassFromString("NSCGSDisplayConfiguration") as? NSObject.Type,
           let config = configClass.perform(NSSelectorFromString("currentConfiguration"))?.takeUnretainedValue() as? NSObject,
           let displays = config.value(forKey: "uniqueDisplays") as? [NSObject] {
            for display in displays {
                guard let uuid = display.value(forKey: "UUID") as? NSUUID else { continue }
                let uuidString = uuid.uuidString
                let displayID = (display.value(forKey: "displayID") as? UInt32) ?? 0
                let screenName = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID
                })?.localizedName ?? "Display"
                map[uuidString] = DisplayInfo(displayID: displayID, name: screenName)
            }
        }
        
        if map.isEmpty {
            for screen in NSScreen.screens {
                guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { continue }
                if let uuid = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeRetainedValue() {
                    let uuidStr = CFUUIDCreateString(nil, uuid) as String
                    map[uuidStr] = DisplayInfo(displayID: screenNumber, name: screen.localizedName)
                } else {
                    map["fallback-\(screenNumber)"] = DisplayInfo(displayID: screenNumber, name: screen.localizedName)
                }
            }
        }
        return map
    }

    func makeAerialLinkedRecord(assetID: String, now: Date = Date()) throws -> [String: Any] {
        let config = try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        let choice: [String: Any] = [
            "Configuration": config,
            "Files": [] as [Any],
            "Provider": "com.apple.wallpaper.choice.aerials"
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

    func makeAerialIndividualRecord(assetID: String, now: Date = Date()) throws -> [String: Any] {
        let config = try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        let choice: [String: Any] = [
            "Configuration": config,
            "Files": [] as [Any],
            "Provider": "com.apple.wallpaper.choice.aerials"
        ]
        let emptyOptionValues = (try? PropertyListSerialization.data(fromPropertyList: ["values": [String: Any]()], format: .binary, options: 0)) ?? Data()
        let content: [String: Any] = [
            "Choices": [choice],
            "EncodedOptionValues": emptyOptionValues,
            "Shuffle": "$null"
        ]
        let side: [String: Any] = [
            "Content": content,
            "LastSet": now,
            "LastUse": now
        ]
        return [
            "Type": "individual",
            "Desktop": side,
            "Idle": side
        ]
    }

    func updateWallpaperStore(storeURL: URL, assetID: String) throws {
        let data = try Data(contentsOf: storeURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var root = try PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: &format) as? [String: Any] else {
            throw NSError(domain: "CineWall", code: 1006, userInfo: [NSLocalizedDescriptionKey: "The wallpaper store has an unexpected format."])
        }

        let now = Date()
        let defaultLinked = try makeAerialLinkedRecord(assetID: assetID, now: now)
        let defaultIndividual = try makeAerialIndividualRecord(assetID: assetID, now: now)

        // 1. AllSpacesAndDisplays: Critical on macOS 26/27 (Tahoe/Golden Gate) for global lock screen & screensaver
        root["AllSpacesAndDisplays"] = defaultLinked
        root["SystemDefault"] = defaultLinked

        // 2. Displays: Resolve all connected display UUIDs and update per-display choices
        var displays = (root["Displays"] as? [String: Any]) ?? [:]
        let displayMap = resolveDisplayMap()
        for (dispUUID, _) in displayMap {
            if dispUUID.hasPrefix("fallback-") { continue }
            displays[dispUUID] = defaultLinked
        }
        for key in displays.keys {
            displays[key] = defaultLinked
        }
        root["Displays"] = displays

        // 3. Spaces: Update individual spaces so space overrides don't take precedence
        if var spaces = root["Spaces"] as? [String: Any] {
            for (sKey, sVal) in spaces {
                if var spaceDict = sVal as? [String: Any] {
                    var spaceDisplays = (spaceDict["Displays"] as? [String: Any]) ?? [:]
                    for dKey in displays.keys {
                        spaceDisplays[dKey] = defaultLinked
                    }
                    spaceDict["Displays"] = spaceDisplays
                    spaceDict["Default"] = defaultLinked
                    spaces[sKey] = spaceDict
                }
            }
            root["Spaces"] = spaces
        }

        let updated = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        try updated.write(to: storeURL, options: .atomic)
    }

    func restartWallpaperAgent() {
        // 1. Post Darwin notification so WallpaperAgent & Aerial extensions detect choice change
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.apple.wallpaper.choice.changed" as CFString),
            nil,
            nil,
            true
        )

        // 2. Signal WallpaperAgent to restart clean with -TERM
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["-TERM", "WallpaperAgent"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()

        // 3. Signal WallpaperAerialsExtension to invalidate in-memory cache on modern macOS
        let taskExt = Process()
        taskExt.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        taskExt.arguments = ["-TERM", "WallpaperAerialsExtension"]
        taskExt.standardOutput = Pipe()
        taskExt.standardError = Pipe()
        try? taskExt.run()
        taskExt.waitUntilExit()
    }
}

private final class CineWallEncodedSampleWriter {
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private let finishSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var firstPTS: CMTime?
    private var storedError: Error?

    init(destinationURL: URL) throws {
        writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
        writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw NSError(domain: "CineWall", code: 1018, userInfo: [NSLocalizedDescriptionKey: "Failed to create a movie writer input for encoded HEVC samples."])
        }
        writer.add(writerInput)
    }

    func appendEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard storedError == nil else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            storedError = NSError(domain: "CineWall", code: 1019, userInfo: [NSLocalizedDescriptionKey: "The HEVC encoder produced a sample that was not ready."])
            return
        }

        if writer.status == .unknown {
            firstPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard writer.startWriting() else {
                storedError = writer.error ?? NSError(domain: "CineWall", code: 1020, userInfo: [NSLocalizedDescriptionKey: "Failed to start the movie writer for encoded HEVC samples."])
                return
            }
            writer.startSession(atSourceTime: firstPTS ?? .zero)
        }

        while !writerInput.isReadyForMoreMediaData {
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.001)
            lock.lock()
            guard storedError == nil else { return }
        }

        if !writerInput.append(sampleBuffer) {
            storedError = writer.error ?? NSError(domain: "CineWall", code: 1021, userInfo: [NSLocalizedDescriptionKey: "Failed to append an encoded HEVC sample to the movie writer."])
        }
    }

    func fail(status: OSStatus) {
        lock.lock()
        defer { lock.unlock() }
        guard storedError == nil else { return }
        storedError = NSError(domain: "CineWall", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "VTCompressionSession produced an error. Status: \(status)"])
    }

    func finishWriting() throws {
        lock.lock()
        if let storedError {
            lock.unlock()
            throw storedError
        }
        lock.unlock()

        writerInput.markAsFinished()
        writer.finishWriting { [finishSemaphore] in
            finishSemaphore.signal()
        }
        finishSemaphore.wait()

        if let error = storedError {
            throw error
        }
        if let error = writer.error {
            throw error
        }
        guard writer.status == .completed else {
            throw NSError(domain: "CineWall", code: 1022, userInfo: [NSLocalizedDescriptionKey: "The encoded HEVC writer did not complete successfully. Status: \(writer.status.rawValue)"])
        }
    }
}

private func cineWallCompressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) -> Void {
    guard let outputCallbackRefCon else { return }
    let writer = Unmanaged<CineWallEncodedSampleWriter>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    guard status == noErr, let sampleBuffer else {
        writer.fail(status: status)
        return
    }
    if infoFlags.contains(.frameDropped) { return }
    writer.appendEncodedSampleBuffer(sampleBuffer)
}


