import Cocoa
import AVFoundation
import QuartzCore

// MARK: - Video & GIF Playback Engine
extension AppDelegate {
    // MARK: - PLAYBACK ENGINE
    func startPlayback(crossfade: Bool = false) {
        cancelActiveIdleWallpaperSync()
        
        if currentQueue.isEmpty {
            stopAllPlayers()
            gifViews.forEach { $0.isHidden = true }
            layersA.forEach { $0.isHidden = true }
            layersB.forEach { $0.isHidden = true }
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
            if let img = img {
                self?.updateAmbientColors(from: img)
            }
        }
        
        if currentFile.pathExtension.lowercased() == "gif" {
            playGIF(url: currentFile)
        } else {
            playVideo(at: queueIndex, crossfade: crossfade)
        }
        
        resetPlaylistTimer()
        updatePlaybackState()
        liquidController?.refreshUI()
        scheduleIdleWallpaperSyncIfNeeded()
    }
    
    // MARK: - AMBIENT COLOR EXTRACTION
    func updateAmbientColors(from image: NSImage) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let width = 24
            let height = 24
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var rawData = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(
                data: &rawData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            
            var totalR: Double = 0
            var totalG: Double = 0
            var totalB: Double = 0
            var maxSat: Double = 0
            var satR: Double = 0.5
            var satG: Double = 0.5
            var satB: Double = 0.5
            
            let count = width * height
            for i in 0..<count {
                let r = Double(rawData[i * 4]) / 255.0
                let g = Double(rawData[i * 4 + 1]) / 255.0
                let b = Double(rawData[i * 4 + 2]) / 255.0
                
                totalR += r
                totalG += g
                totalB += b
                
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let sat = maxC > 0 ? (maxC - minC) / maxC : 0
                if sat > maxSat && maxC > 0.15 && maxC < 0.95 {
                    maxSat = sat
                    satR = r
                    satG = g
                    satB = b
                }
            }
            
            let avgColor = NSColor(red: totalR / Double(count), green: totalG / Double(count), blue: totalB / Double(count), alpha: 1.0)
            let vibrantColor = maxSat > 0.12 ? NSColor(red: satR, green: satG, blue: satB, alpha: 1.0) : avgColor
            
            DispatchQueue.main.async {
                self.currentAmbientPrimary = vibrantColor
                self.currentAmbientSecondary = avgColor
                self.liquidController?.applyAmbientColors(primary: vibrantColor, secondary: avgColor)
            }
        }
    }
    
    // MARK: - AUDIO SMOOTH FADING
    func fadeAudio(player: AVPlayer?, to targetVolume: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        audioFadeTimer?.invalidate()
        audioFadeTimer = nil
        guard let player = player else { completion?(); return }
        let startVol = player.volume
        if abs(startVol - targetVolume) < 0.01 {
            player.volume = targetVolume
            completion?()
            return
        }
        let startTime = CACurrentMediaTime()
        audioFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            let elapsed = CACurrentMediaTime() - startTime
            let progress = Float(min(1.0, elapsed / duration))
            player.volume = startVol + (targetVolume - startVol) * progress
            if progress >= 1.0 {
                t.invalidate()
                self?.audioFadeTimer = nil
                player.volume = targetVolume
                completion?()
            }
        }
    }

    // MARK: - GIF ENGINE
    func playGIF(url: URL) {
        stopAllPlayers()
        
        guard let image = NSImage(contentsOf: url) else { nextFile(); return }
        
        gifViews.forEach {
            $0.isHidden = false
            $0.image = image
            $0.animates = true
        }
        updateScalingMode()
        
        if !isLoopingCurrent && autoChangeInterval == 0 {
            let duration = getGIFDuration(url: url)
            gifTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.videoFinished()
            }
        }
    }
    
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
                
                if delay <= 0.01 { delay = 0.1 }
                totalDuration += delay
            }
        }
        return totalDuration > 0 ? totalDuration : 5.0
    }

    // MARK: - VIDEO ENGINE WITH A/B CROSSFADE
    func playVideo(at index: Int, crossfade: Bool = false) {
        guard index >= 0, index < currentQueue.count else { return }
        let url = currentQueue[index]
        let item = AVPlayerItem(url: url)

        pendingVideoReadyObservation?.invalidate()
        pendingVideoReadyObservation = nil
        pendingHiddenLayerCleanupWorkItem?.cancel()
        pendingHiddenLayerCleanupWorkItem = nil

        let currentActivePlayer = (activePlayerIndex == 0) ? playerA : playerB
        let isActivelyPlaying = (currentActivePlayer?.currentItem != nil && currentActivePlayer?.rate != 0)

        if crossfade && isActivelyPlaying {
            // A/B True Crossfade
            let nextIndex = 1 - activePlayerIndex
            let incomingPlayer = (nextIndex == 0) ? playerA : playerB
            let outgoingPlayer = (activePlayerIndex == 0) ? playerA : playerB
            let incomingLayers = (nextIndex == 0) ? layersA : layersB
            let outgoingLayers = (activePlayerIndex == 0) ? layersA : layersB

            incomingPlayer?.replaceCurrentItem(with: item)
            incomingPlayer?.actionAtItemEnd = .none
            incomingPlayer?.volume = 0.0

            let targetVol = (isMuted || (focusMuteEnabled && !isDesktopFocused())) ? 0 : volumeLevel

            for l in incomingLayers {
                l.isHidden = false
                l.opacity = 0.0
            }

            if !isManualPaused {
                incomingPlayer?.play()
            }

            // Crossfade visual layers smoothly
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.75)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            for l in incomingLayers { l.opacity = 1.0 }
            for l in outgoingLayers { l.opacity = 0.0 }
            CATransaction.commit()

            // Crossfade audio simultaneously
            fadeAudio(player: outgoingPlayer, to: 0.0, duration: 0.70)
            fadeAudio(player: incomingPlayer, to: targetVol, duration: 0.75)

            let cleanupWorkItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                for l in outgoingLayers { l.isHidden = true }
                outgoingPlayer?.pause()
                outgoingPlayer?.replaceCurrentItem(with: nil)
                self.activePlayerIndex = nextIndex
                if let incoming = incomingPlayer {
                    self.setupTimeObserver(for: incoming)
                }
            }
            pendingHiddenLayerCleanupWorkItem = cleanupWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.80, execute: cleanupWorkItem)

            if let observer = videoEndObserver { NotificationCenter.default.removeObserver(observer) }
            videoEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in self?.videoFinished() }
        } else {
            // Direct playback (no outgoing video)
            let nextIndex = activePlayerIndex
            let p = (nextIndex == 0) ? playerA : playerB
            let activeLayers = (nextIndex == 0) ? layersA : layersB
            let hiddenLayers = (nextIndex == 0) ? layersB : layersA

            p?.replaceCurrentItem(with: item)
            p?.actionAtItemEnd = .none
            p?.volume = (isMuted || (focusMuteEnabled && !isDesktopFocused())) ? 0 : volumeLevel

            if let active = p {
                setupTimeObserver(for: active)
            }

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.35)
            for l in activeLayers {
                l.isHidden = false
                l.opacity = 1.0
            }
            for l in hiddenLayers {
                l.opacity = 0.0
                l.isHidden = true
            }
            CATransaction.commit()

            if !isManualPaused { p?.play() }

            if let observer = videoEndObserver { NotificationCenter.default.removeObserver(observer) }
            videoEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in self?.videoFinished() }
        }
    }
    
    func videoFinished() {
        if isLoopingCurrent {
            let p = (activePlayerIndex == 0) ? playerA : playerB
            p?.seek(to: .zero)
            p?.play()
        } else {
            nextFile()
        }
    }
    
    func stopAllPlayers() {
        playerA?.pause()
        playerB?.pause()
        audioFadeTimer?.invalidate()
        audioFadeTimer = nil
        pendingVideoReadyObservation?.invalidate()
        pendingVideoReadyObservation = nil
        pendingHiddenLayerCleanupWorkItem?.cancel()
        pendingHiddenLayerCleanupWorkItem = nil
        gifTimer?.invalidate()
        gifTimer = nil
        if let ob = timeObserver, let owner = timeObserverOwner {
            owner.removeTimeObserver(ob)
            timeObserver = nil
            timeObserverOwner = nil
        }
    }

    @objc func nextFile() {
        if !currentQueue.isEmpty {
            queueIndex += 1
            if queueIndex >= currentQueue.count { queueIndex = 0 }
            startPlayback(crossfade: true)
        }
    }

    @objc func prevFile() {
        if !currentQueue.isEmpty {
            queueIndex -= 1
            if queueIndex < 0 { queueIndex = currentQueue.count - 1 }
            startPlayback(crossfade: true)
        }
    }

    func setupTimeObserver(for player: AVPlayer) {
        if let ob = timeObserver, let owner = timeObserverOwner {
            owner.removeTimeObserver(ob)
            timeObserver = nil
            timeObserverOwner = nil
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isSeeking, let duration = player.currentItem?.duration.seconds, duration > 0 else { return }
            guard self.liquidWindow?.isVisible == true else { return }
            self.liquidController?.progressSlider.doubleValue = time.seconds / duration
            self.liquidController?.updateTimeLabels(elapsed: time.seconds, duration: duration)
        }
        timeObserverOwner = player
    }

    func seekTo(percentage: Double) {
        let activePlayer = (activePlayerIndex == 0) ? playerA : playerB
        guard let duration = activePlayer?.currentItem?.duration.seconds else { return }
        isSeeking = true
        activePlayer?.seek(to: CMTime(seconds: duration * percentage, preferredTimescale: 1000)) { [weak self] _ in
            self?.isSeeking = false
        }
    }

    func toggleMuteState() {
        isMuted.toggle()
        saveSettings()
        updateVolumeState()
        liquidController?.refreshUI()
    }

    func updatePlaybackState() {
        _ = syncAccessControlledState()
        if isManualPaused || (focusPauseEnabled && !isDesktopFocused()) || (smartPauseEnabled && !showOnAllSpaces && isOccluded()) || (batterySaverEnabled && isOnBattery()) {
            performPause()
            return
        }
        performPlay()
        updateVolumeState()
    }

    func performPlay() {
        let p = (activePlayerIndex == 0) ? playerA : playerB
        if p?.rate == 0 {
            let targetVol = (isMuted || (focusMuteEnabled && !isDesktopFocused())) ? 0 : volumeLevel
            p?.volume = 0
            p?.play()
            fadeAudio(player: p, to: targetVol, duration: 0.25)
        }
        gifViews.forEach { if !$0.isHidden { $0.animates = true } }
    }

    func performPause() {
        let p = (activePlayerIndex == 0) ? playerA : playerB
        if p?.rate != 0 {
            if (p?.volume ?? 0) > 0 {
                fadeAudio(player: p, to: 0.0, duration: 0.20) {
                    p?.pause()
                }
            } else {
                p?.pause()
            }
        }
        gifViews.forEach { if !$0.isHidden { $0.animates = false } }
        gifTimer?.invalidate()
        gifTimer = nil
    }

    func updateVolumeState() {
        let v = (isMuted || (focusMuteEnabled && !isDesktopFocused())) ? 0 : volumeLevel
        let activePlayer = (activePlayerIndex == 0) ? playerA : playerB
        activePlayer?.volume = v
    }

    func resetPlaylistTimer() {
        playlistTimer?.invalidate()
        guard autoChangeInterval > 0, !currentQueue.isEmpty else { return }
        playlistTimer = Timer.scheduledTimer(withTimeInterval: autoChangeInterval, repeats: true) { [weak self] _ in
            self?.nextFile()
        }
    }
}
