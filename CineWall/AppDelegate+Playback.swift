import Cocoa
import AVFoundation
import QuartzCore

// MARK: - Video & GIF Playback Engine
extension AppDelegate {
    // MARK: - PLAYBACK ENGINE
    func startPlayback() {
        cancelActiveIdleWallpaperSync()
        stopAllPlayers()
        gifViews.forEach { $0.isHidden = true }
        layersA.forEach { $0.isHidden = true }
        layersB.forEach { $0.isHidden = true }
        
        if currentQueue.isEmpty {
            liquidController?.updateTrackInfo(title: "No Media", image: nil, isFav: false)
            return
        }
        
        if queueIndex >= currentQueue.count { queueIndex = 0 }
        let currentFile = currentQueue[queueIndex]
        let isFav = containsVideo(path: currentFile.path, inPlaylist: Self.favoritesPlaylistName)
        
        // Save current file for restart
        lastPlayedFile = currentFile.path
        saveSettings()
        
        generateThumbnail(for: currentFile) { [weak self] img in
            self?.liquidController?.updateTrackInfo(title: currentFile.lastPathComponent, image: img, isFav: isFav)
        }
        
        if currentFile.pathExtension.lowercased() == "gif" {
            playGIF(url: currentFile)
        } else {
            playVideo(at: queueIndex)
        }
        
        resetPlaylistTimer(); updatePlaybackState(); liquidController?.refreshUI(); scheduleIdleWallpaperSyncIfNeeded()
    }
    
    // MARK: - GIF ENGINE (FIXED)
    func playGIF(url: URL) {
        stopAllPlayers() // Clears video players and old GIF timers
        
        guard let image = NSImage(contentsOf: url) else { nextFile(); return }
        
        gifViews.forEach {
            $0.isHidden = false
            $0.image = image
            $0.animates = true
        }
        updateScalingMode()
        
        // If Loop is OFF and Timer is OFF, we need to manually change when GIF ends
        if !isLoopingCurrent && autoChangeInterval == 0 {
            let duration = getGIFDuration(url: url)
            // Schedule next track
            gifTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.videoFinished()
            }
        }
    }
    
    // Helper to calculate GIF length
    func getGIFDuration(url: URL) -> Double {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 5.0 }
        let count = CGImageSourceGetCount(source)
        var totalDuration: Double = 0
        
        for i in 0..<count {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
               let gifInfo = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                
                var delay = gifInfo[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                            ?? gifInfo[kCGImagePropertyGIFDelayTime as String] as? Double
                            ?? 0.1
                
                if delay <= 0.01 { delay = 0.1 } // Fix for 0 delay gifs
                totalDuration += delay
            }
        }
        // Minimal fallback
        return totalDuration > 0 ? totalDuration : 5.0
    }

    // MARK: - VIDEO ENGINE
    func playVideo(at index: Int) {
        let url = currentQueue[index]; let item = AVPlayerItem(url: url)
        let activePlayer = (activePlayerIndex == 0) ? playerA : playerB

        pendingVideoReadyObservation?.invalidate()
        pendingVideoReadyObservation = nil
        pendingHiddenLayerCleanupWorkItem?.cancel()
        pendingHiddenLayerCleanupWorkItem = nil

        activePlayer?.replaceCurrentItem(with: item)
        activePlayer?.volume = isMuted ? 0 : volumeLevel
        activePlayer?.actionAtItemEnd = .none

        setupTimeObserver(for: activePlayer!)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        let activeLayers = (activePlayerIndex == 0) ? layersA : layersB
        let hiddenLayers = (activePlayerIndex == 0) ? layersB : layersA
        for l in activeLayers {
            l.isHidden = false
            l.opacity = 1.0
        }
        for l in hiddenLayers {
            l.opacity = 0.0
        }
        CATransaction.commit()

        let cleanupWorkItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let toHide = (self.activePlayerIndex == 0) ? self.layersB : self.layersA
            for l in toHide {
                l.isHidden = true
            }
            let inactivePlayer = (self.activePlayerIndex == 0) ? self.playerB : self.playerA
            inactivePlayer?.replaceCurrentItem(with: nil)
        }
        pendingHiddenLayerCleanupWorkItem = cleanupWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: cleanupWorkItem)

        if !isManualPaused { activePlayer?.play() }

        if let observer = videoEndObserver { NotificationCenter.default.removeObserver(observer) }
        videoEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in self?.videoFinished() }
    }
    
    func videoFinished() {
        if isLoopingCurrent {
            // Replay Video
            let p = (activePlayerIndex == 0) ? playerA : playerB
            p?.seek(to: .zero); p?.play()
            // Replay GIF
            if !(gifView?.isHidden ?? true) {
                // For GIFs, we just reset the timer if loop is on (though logic above handles !loop)
                // Actually, if loop is ON, we do nothing, NSImageView loops automatically.
            }
        } else {
            nextFile()
        }
    }
    
    func stopAllPlayers() {
        playerA?.pause(); playerB?.pause()
        pendingVideoReadyObservation?.invalidate(); pendingVideoReadyObservation = nil
        pendingHiddenLayerCleanupWorkItem?.cancel(); pendingHiddenLayerCleanupWorkItem = nil
        gifTimer?.invalidate(); gifTimer = nil // STOP GIF TIMER
        if let ob = timeObserver, let owner = timeObserverOwner { owner.removeTimeObserver(ob); timeObserver = nil; timeObserverOwner = nil }
    }


    @objc func nextFile() { if !currentQueue.isEmpty { queueIndex += 1; if queueIndex >= currentQueue.count { queueIndex = 0 }; startPlayback() } }
    @objc func prevFile() { if !currentQueue.isEmpty { queueIndex -= 1; if queueIndex < 0 { queueIndex = currentQueue.count - 1 }; startPlayback() } }

    func setupTimeObserver(for player: AVPlayer) {
        if let ob = timeObserver, let owner = timeObserverOwner { owner.removeTimeObserver(ob); timeObserver = nil; timeObserverOwner = nil }
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isSeeking, let duration = player.currentItem?.duration.seconds, duration > 0 else { return }
            guard self.liquidWindow?.isVisible == true else { return }
            self.liquidController?.progressSlider.doubleValue = time.seconds / duration
            self.liquidController?.updateTimeLabels(elapsed: time.seconds, duration: duration)
        }
        timeObserverOwner = player
    }

    func seekTo(percentage: Double) { let activePlayer = (activePlayerIndex == 0) ? playerA : playerB; guard let duration = activePlayer?.currentItem?.duration.seconds else { return }; isSeeking = true; activePlayer?.seek(to: CMTime(seconds: duration * percentage, preferredTimescale: 1000)) { [weak self] _ in self?.isSeeking = false } }
    func toggleMuteState() { isMuted.toggle(); saveSettings(); updateVolumeState(); liquidController?.refreshUI() }

    func updatePlaybackState() { _ = syncAccessControlledState(); if isManualPaused || (focusPauseEnabled && !isDesktopFocused()) || (smartPauseEnabled && !showOnAllSpaces && isOccluded()) || (batterySaverEnabled && isOnBattery()) { performPause(); return }; performPlay(); updateVolumeState() }

    func performPlay() { let p = (activePlayerIndex == 0) ? playerA : playerB; if p?.rate == 0 { p?.play() }; gifViews.forEach { if !$0.isHidden { $0.animates = true } } }
    func performPause() { let p = (activePlayerIndex == 0) ? playerA : playerB; if p?.rate != 0 { p?.pause() }; gifViews.forEach { if !$0.isHidden { $0.animates = false } }; gifTimer?.invalidate(); gifTimer = nil }
    func updateVolumeState() { let v = (isMuted || (focusMuteEnabled && !isDesktopFocused())) ? 0 : volumeLevel; playerA?.volume = v; playerB?.volume = v }

    func resetPlaylistTimer() { playlistTimer?.invalidate(); guard autoChangeInterval > 0, !currentQueue.isEmpty else { return }; playlistTimer = Timer.scheduledTimer(withTimeInterval: autoChangeInterval, repeats: true) { [weak self] _ in self?.nextFile() } }

}
