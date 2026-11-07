import Cocoa
import AVFoundation

// MARK: - Playlists & Media Library
extension AppDelegate {
    func deduplicatedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for path in paths where !path.isEmpty && !seen.contains(path) {
            seen.insert(path)
            ordered.append(path)
        }
        return ordered
    }

    func thumbnailCacheKey(for url: URL) -> NSString {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(url.path)|\(Int64(modified * 1000))|\(size)" as NSString
    }

    func ensurePlaylists() {
        if playlists[Self.favoritesPlaylistName] == nil {
            playlists[Self.favoritesPlaylistName] = []
        }
        playlists = playlists.reduce(into: [:]) { partial, entry in
            partial[entry.key] = deduplicatedPaths(entry.value)
        }
        if playlists[selectedPlaylistName] == nil {
            selectedPlaylistName = Self.favoritesPlaylistName
        }
    }

    func orderedPlaylistNames() -> [String] {
        let customNames = playlists.keys
            .filter { $0 != Self.favoritesPlaylistName }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return [Self.favoritesPlaylistName] + customNames
    }

    func playlistEntries(named playlistName: String) -> [String] {
        playlists[playlistName] ?? []
    }

    func containsVideo(path: String, inPlaylist playlistName: String) -> Bool {
        playlistEntries(named: playlistName).contains(path)
    }

    func addVideo(path: String, toPlaylist playlistName: String) {
        ensurePlaylists()
        var items = playlistEntries(named: playlistName)
        guard !items.contains(path) else { return }
        items.append(path)
        playlists[playlistName] = items
    }

    func removeVideo(path: String, fromPlaylist playlistName: String) {
        guard var items = playlists[playlistName] else { return }
        items.removeAll { $0 == path }
        playlists[playlistName] = items
    }

    func toggleVideo(path: String, inPlaylist playlistName: String) {
        if containsVideo(path: path, inPlaylist: playlistName) {
            removeVideo(path: path, fromPlaylist: playlistName)
        } else {
            addVideo(path: path, toPlaylist: playlistName)
        }
        saveSettings()
        liquidController?.refreshUI()
        if isPlaylistFilterEnabled && selectedPlaylistName == playlistName {
            refreshQueue()
            startPlayback()
        } else if !currentQueue.isEmpty && currentQueue[queueIndex].path == path {
            liquidController?.updateFavIcon(containsVideo(path: path, inPlaylist: Self.favoritesPlaylistName))
        }
    }

    func createPlaylist(named rawName: String) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard playlists[trimmed] == nil else { return false }
        playlists[trimmed] = []
        selectedPlaylistName = trimmed
        saveSettings()
        liquidController?.refreshUI()
        return true
    }

    func deletePlaylist(named playlistName: String) {
        guard playlistName != Self.favoritesPlaylistName else { return }
        let wasActiveFilter = isPlaylistFilterEnabled && selectedPlaylistName == playlistName
        playlists.removeValue(forKey: playlistName)
        if selectedPlaylistName == playlistName {
            selectedPlaylistName = Self.favoritesPlaylistName
        }
        if wasActiveFilter { isPlaylistFilterEnabled = false }
        saveSettings()
        liquidController?.refreshUI()
        if wasActiveFilter {
            refreshQueue()
            startPlayback()
        }
    }

    func clearPlaylist(named playlistName: String) {
        playlists[playlistName] = []
        saveSettings()
        liquidController?.refreshUI()
        if isPlaylistFilterEnabled && selectedPlaylistName == playlistName {
            refreshQueue()
            startPlayback()
        }
    }

    func setSelectedPlaylist(_ playlistName: String) {
        guard playlists[playlistName] != nil else { return }
        selectedPlaylistName = playlistName
        saveSettings()
        if isPlaylistFilterEnabled {
            refreshQueue()
            startPlayback()
        } else {
            liquidController?.refreshUI()
        }
    }

    func toggleSelectedPlaylistFilter() {
        guard requireProAccess(for: .playlists) else { return }
        ensurePlaylists()
        isPlaylistFilterEnabled.toggle()
        saveSettings()
        refreshQueue()
        startPlayback()
    }

    func importVideosToSelectedPlaylist() {
        guard requireProAccess(for: .playlists) else { return }
        ensurePlaylists()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .gif]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Add Videos"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addVideo(path: url.path, toPlaylist: selectedPlaylistName)
            if !allFiles.contains(url) {
                allFiles.append(url)
            }
        }
        allFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
        saveSettings()
        liquidController?.refreshUI()
        if isPlaylistFilterEnabled {
            refreshQueue()
            startPlayback()
        }
    }

    func promptForNewPlaylist() {
        guard requireProAccess(for: .playlists) else { return }
        let alert = NSAlert()
        alert.messageText = "Create Playlist"
        alert.informativeText = "Enter a name for the new playlist."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Playlist name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if !createPlaylist(named: field.stringValue) {
            let failure = NSAlert()
            failure.messageText = "Playlist not created"
            failure.informativeText = "Choose a unique playlist name."
            failure.runModal()
        }
    }
    
    // MARK: - SSD AUTO-CONNECT & LOAD
    func checkAndLoad(url: URL) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue {
            // Path exists (SSD is ready)
            loadFolder(folderUrl: url, autoStart: true)
        } else {
            // Path missing (SSD not ready). Wait for mount.
            print("CineWall: Path not found. Waiting for SSD mount...")
        }
    }
    
    @objc func storageMounted(_ notification: Notification) {
        // If we have a saved path but no files loaded, try loading again
        if allFiles.isEmpty, let savedPath = lastFolderPath {
            let url = URL(fileURLWithPath: savedPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue {
                print("CineWall: Drive mounted! Loading wallpaper.")
                loadFolder(folderUrl: url, autoStart: true)
            }
        }
    }


    // MARK: - SINGLE FILE & PERSISTENCE FIX
    func selectSingleVideo() {
        let d = NSOpenPanel(); d.allowedContentTypes = [.movie, .video, .gif]
        if d.runModal() == .OK, let url = d.url {
            // FIX: Save the parent folder so it reloads on restart
            lastFolderPath = url.deletingLastPathComponent().path
            saveSettings()
            
            if let index = currentQueue.firstIndex(of: url) {
                queueIndex = index
            } else {
                // If not in queue, reload folder then jump to file
                // Or just insert it
                if !allFiles.contains(url) {
                    allFiles.append(url)
                    allFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
                    refreshQueue()
                }
                if let idx = currentQueue.firstIndex(of: url) { queueIndex = idx }
            }
            startPlayback()
        }
    }

    func loadFolder(folderUrl: URL, autoStart: Bool) {
        do {
            let u = try FileManager.default.contentsOfDirectory(at: folderUrl, includingPropertiesForKeys: nil)
            allFiles = u.filter { ["mp4", "mov", "m4v", "gif"].contains($0.pathExtension.lowercased()) }
            if allFiles.isEmpty { return }
            
            lastFolderPath = folderUrl.path
            allFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
            refreshQueue()
            
            // Restore specific file if possible
            if let savedFile = lastPlayedFile, let idx = currentQueue.firstIndex(where: { $0.path == savedFile }) {
                queueIndex = idx
            } else {
                queueIndex = 0
            }
            
            saveSettings()
            if autoStart { startPlayback() }
        } catch {}
    }


    func toggleFavorite() {
        guard !currentQueue.isEmpty else { return }
        let path = currentQueue[queueIndex].path
        toggleVideo(path: path, inPlaylist: Self.favoritesPlaylistName)
    }
    func removeFavorite(path: String) {
        removeVideo(path: path, fromPlaylist: Self.favoritesPlaylistName)
        saveSettings()
        liquidController?.refreshUI()
        if !currentQueue.isEmpty && currentQueue[queueIndex].path == path {
            liquidController?.updateFavIcon(false)
        }
        if isPlaylistFilterEnabled && selectedPlaylistName == Self.favoritesPlaylistName {
            refreshQueue()
            startPlayback()
        }
    }

    func refreshQueue() {
        let currentPath = (queueIndex >= 0 && queueIndex < currentQueue.count) ? currentQueue[queueIndex].path : lastPlayedFile
        let sourceFiles: [URL]
        if isPlaylistFilterEnabled {
            let selectedSet = Set(playlistEntries(named: selectedPlaylistName))
            sourceFiles = allFiles.filter { selectedSet.contains($0.path) }
        } else {
            sourceFiles = allFiles
        }
        currentQueue = isShuffle ? sourceFiles.shuffled() : sourceFiles
        if let currentPath, let idx = currentQueue.firstIndex(where: { $0.path == currentPath }) {
            queueIndex = idx
        } else {
            queueIndex = 0
        }
    }

    func generateThumbnail(for url: URL, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = thumbnailCacheKey(for: url)

        if let cached = thumbnailCache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        if url.pathExtension.lowercased() == "gif" {
            let image = NSImage(contentsOf: url)
            if let image {
                thumbnailCache.setObject(image, forKey: cacheKey)
            }
            completion(image)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            do {
                let cg = try gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 60), actualTime: nil)
                let image = NSImage(cgImage: cg, size: .zero)
                DispatchQueue.main.async {
                    self.thumbnailCache.setObject(image, forKey: cacheKey)
                    completion(image)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }

    func selectFolder() {
        let d = NSOpenPanel(); d.canChooseDirectories = true; d.canChooseFiles = false; if d.runModal() == .OK, let url = d.url { loadFolder(folderUrl: url, autoStart: true) }
    }

    func handleDroppedFile(url: URL) { let ext = url.pathExtension.lowercased(); if ["mp4", "mov", "m4v", "gif"].contains(ext) { if currentQueue.isEmpty { currentQueue = [url]; queueIndex = 0 } else { if let idx = currentQueue.firstIndex(of: url) { queueIndex = idx } else { currentQueue.insert(url, at: queueIndex + 1); queueIndex += 1 } }; startPlayback() } }
    func revealCurrentInFinder() { if !currentQueue.isEmpty && queueIndex < currentQueue.count { NSWorkspace.shared.activateFileViewerSelecting([currentQueue[queueIndex]]) } }
    func showFavoritesWindow() { guard requireProAccess(for: .playlists) else { return }; liquidWindow?.makeKeyAndOrderFront(nil); liquidController?.showLibraryDetail() }
    func playPlaylistItem(at index: Int, playlistName: String? = nil) {
        let name = playlistName ?? selectedPlaylistName
        let items = playlistEntries(named: name)
        guard index < items.count else { return }
        let url = URL(fileURLWithPath: items[index])
        if !currentQueue.contains(url) { currentQueue.append(url) }
        if let idx = currentQueue.firstIndex(of: url) {
            queueIndex = idx
            startPlayback()
        }
    }
    
    // WINDOW CLASSES

}
