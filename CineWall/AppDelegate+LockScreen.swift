//
//  AppDelegate+LockScreen.swift
//  CineWall
//
//  Native ExtensionKit Lock Screen & Multi-Display Wallpaper Integration.
//  Direct source-level parity with WallpaperMachine/App/Services/LockScreen architecture.
//

import Cocoa
import AVFoundation

// MARK: - macOS Lock Screen & Multi-Display ExtensionKit Sync
extension AppDelegate {
    @objc func sessionUnlocked() {
        guard proManager.canUse(.lockScreenSync), lockScreenSyncEnabled else { return }
        guard autoSyncIdleWallpaper else { return }

        let refreshURL: URL?
        if currentQueue.indices.contains(queueIndex) {
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

        let selectedURL = sourceURL
            ?? ((currentQueue.indices.contains(queueIndex)) ? currentQueue[queueIndex] : nil)
            ?? (lastPlayedFile.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil })
            ?? allFiles.first(where: { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) })
        guard let validURL = selectedURL else {
            if showAlerts {
                showAlert(title: "No Media Selected", message: "Play a video first, then sync it to the Lock Screen.")
            }
            return
        }

        let ext = validURL.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else {
            if showAlerts {
                showAlert(title: "Video Required", message: "The native wallpaper extension requires a video asset (.mp4, .mov, .m4v).")
            }
            return
        }

        cancelActiveIdleWallpaperSync()
        setIdleWallpaperSyncInProgress(true)
        lastAutoSyncedMediaPath = validURL.path

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let scalingInt: Int32 = (self.scalingTag == 2) ? 2 : (self.scalingTag == 3 ? 1 : 3)
                try await LockScreenWallpaperService.shared.publish(
                    videoURL: validURL,
                    screens: NSScreen.screens,
                    scalingMode: scalingInt
                )
                self.setIdleWallpaperSyncInProgress(false)
                self.liquidController?.refreshUI()
                if showAlerts {
                    self.showAlert(
                        title: "Lock Screen Synced",
                        message: "Your current video '\(validURL.deletingPathExtension().lastPathComponent)' is now actively playing on the macOS lock screen and screensaver across all displays!"
                    )
                }
            } catch {
                self.setIdleWallpaperSyncInProgress(false)
                self.liquidController?.refreshUI()
                if showAlerts {
                    self.showAlert(
                        title: "Lock Screen Sync Failed",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    func scheduleIdleWallpaperSyncIfNeeded() {
        guard proManager.canUse(.lockScreenSync) else { return }

        if !lockScreenSyncEnabled {
            // Restore macOS system default wallpapers cleanly
            LockScreenWallpaperService.shared.restoreSystemDefault()
            return
        }

        guard autoSyncIdleWallpaper, currentQueue.indices.contains(queueIndex) else { return }
        let sourceURL = currentQueue[queueIndex]

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            guard self.lockScreenSyncEnabled, self.autoSyncIdleWallpaper else { return }
            self.syncCurrentVideoToIdleWallpaper(showAlerts: false, sourceURL: sourceURL)
        }
    }

    func clearIdleWallpaperStateForFastModeQuit() throws {
        LockScreenWallpaperService.shared.restoreSystemDefault()
    }

    func setDesktopWallpaperSnapshotForCurrentMedia() throws {
        // Handled natively by ExtensionKit
    }

    func cancelActiveIdleWallpaperSync() {
        setIdleWallpaperSyncInProgress(false)
    }

    func setIdleWallpaperSyncInProgress(_ inProgress: Bool, requestID: Int? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.idleWallpaperSyncInProgress = inProgress
            self.liquidController?.refreshUI()
        }
    }
}
