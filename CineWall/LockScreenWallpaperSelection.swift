//
//  LockScreenWallpaperSelection.swift
//  CineWall
//
//  ExtensionKit Wallpaper Store Synchronization & Journaling.
//  Direct source-level parity with WallpaperMachine/App/Services/LockScreen/LockScreenWallpaperSelection.swift
//

import AppKit
import Darwin
import Foundation

public struct LockScreenFailure: LocalizedError, Sendable {
    public enum Reason: Sendable { case general, differentExtensionCopy, extensionTurnedOff, transient }
    public let message: String
    public var reason: Reason = .general
    public var errorDescription: String? { message }

    public init(message: String, reason: Reason = .general) {
        self.message = message
        self.reason = reason
    }
}

@MainActor
public final class LockScreenWallpaperSelection {
    private struct Entry: Codable, Equatable {
        var path: [String]
        var original: Data
        var created: Bool
        var observeOnly: Bool? = nil
        var fields: [String]? = nil
        var typeOwned: Bool? = nil
        var linkedOriginal: Data? = nil
        var inheritedOriginal: Data? = nil
        var globalWasPresent: Bool? = nil

        var ownedFields: Set<String> { Set(fields ?? ["Desktop", "Idle"]) }
    }

    private struct Settled: Equatable {
        var desktopDisplays: Set<String>
        var screenSaverDisplays: Set<String>
        var revision: String?
        var store: [Int]
    }

    private static var lastReloadSignal: Date?
    private static let globalPath = ["AllSpacesAndDisplays"]

    public let extensionIdentifier: String
    private let storeURL: URL
    private let journalURL: URL
    private let reload: @MainActor () throws -> Void
    private let persistJournal: @MainActor (URL, Data?) throws -> Void
    private var entries: [Entry] = []
    private var hasPersistedJournal = false
    private var restartPending = false
    private var settled: Settled?

    public init(
        extensionIdentifier: String = LockScreenConfiguration.extensionIdentifier,
        folder: URL? = nil,
        storeURL: URL? = nil,
        journalURL: URL? = nil,
        reload: (@MainActor () throws -> Void)? = nil,
        persistJournal: (@MainActor (URL, Data?) throws -> Void)? = nil
    ) {
        self.extensionIdentifier = extensionIdentifier
        let defaultStore = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/com.apple.wallpaper/Store/Index.plist"
        )
        let resolvedStore = storeURL ?? defaultStore
        let defaultFolder = folder ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/CineWall"
        )
        let resolvedJournal = journalURL ?? defaultFolder.appendingPathComponent("native-selection.plist")

        self.storeURL = resolvedStore
        self.journalURL = resolvedJournal
        self.reload = reload ?? { try Self.reloadWallpaperAgent() }
        self.persistJournal = persistJournal ?? { url, data in
            if let data {
                try data.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        loadJournal()
    }

    public var isRestored: Bool {
        entries.isEmpty && !restartPending
    }

    public func recover() throws {
        guard !entries.isEmpty || restartPending else { return }
        settled = nil
        try synchronize(desktopDisplays: [], screenSaverDisplays: [])
    }

    public func validateCanSynchronize() throws {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let root = try PropertyListSerialization.propertyList(from: Data(contentsOf: storeURL), format: nil) as? [String: Any]
        if let global = root?["AllSpacesAndDisplays"] as? [String: Any],
           global["Type"] as? String == "linked", Self.defaultLinkedChoice(global) == nil {
            throw LockScreenFailure(
                message: "A system-wide linked wallpaper currently overrides individual displays. Turn off that wallpaper app or its all-displays setting before enabling native wallpaper animation."
            )
        }
    }

    public func synchronize(
        desktopDisplays: Set<String>,
        screenSaverDisplays: Set<String>,
        revision: String? = nil
    ) throws {
        let displays = desktopDisplays.union(screenSaverDisplays)
        if displays.isEmpty && entries.isEmpty && !restartPending { return }

        let request = Self.storeVersion(storeURL).map {
            Settled(desktopDisplays: desktopDisplays, screenSaverDisplays: screenSaverDisplays, revision: revision, store: $0)
        }
        if !restartPending, let request, request == settled { return }
        settled = nil

        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let bytes = try Data(contentsOf: storeURL)
        guard var root = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              root["Displays"] is [String: Any], root["Spaces"] is [String: Any] else {
            throw LockScreenFailure(message: "This macOS wallpaper store format is unsupported. Selection was not changed.")
        }

        var paths = displays.sorted().map { ["Displays", $0] }
        let spaces = root["Spaces"] as? [String: Any] ?? [:]
        for (space, value) in spaces.sorted(by: { $0.key < $1.key }) {
            guard let node = value as? [String: Any], node["Displays"] is [String: Any] else {
                throw LockScreenFailure(message: "This macOS Space has an unsupported wallpaper configuration.")
            }
            paths += displays.sorted().map { ["Spaces", space, "Displays", $0] }
        }
        let fallbackPaths = [["SystemDefault"]] + spaces.keys.sorted().map { ["Spaces", $0, "Default"] }
        let activeFields = Set((desktopDisplays.isEmpty ? [] : ["Desktop"]) + (screenSaverDisplays.isEmpty ? [] : ["Idle"]))

        func desiredFields(_ path: [String], observeOnly: Bool) -> Set<String> {
            if observeOnly { return fallbackPaths.contains(path) ? activeFields : [] }
            guard paths.contains(path), let display = path.last else { return [] }
            return Set((desktopDisplays.contains(display) ? ["Desktop"] : []) + (screenSaverDisplays.contains(display) ? ["Idle"] : []))
        }

        var originals: [[String]: [String: Any]] = [:]
        for entry in entries {
            guard let original = try PropertyListSerialization.propertyList(from: entry.original, format: nil) as? [String: Any] else {
                throw LockScreenFailure(message: "The native wallpaper restoration journal is invalid.")
            }
            originals[entry.path] = entry.path == Self.globalPath ? original : original.filter {
                entry.ownedFields.contains($0.key) || ($0.key == "Type" && (entry.typeOwned ?? true))
            }
        }

        let journaledOriginal = { (path: [String]) in originals[path] }
        var recovery = entries
        var retained: [Entry] = []
        var changed = false
        let selection = try Self.makeSelectionDict(extensionIdentifier: extensionIdentifier, revision: revision)

        func record(_ entry: Entry, original: [String: Any]) throws {
            if let index = recovery.firstIndex(where: { $0.path == entry.path }) {
                var merged = originals[entry.path] ?? [:]
                if entry.path == Self.globalPath {
                    merged = original
                } else {
                    for key in entry.ownedFields.subtracting(recovery[index].ownedFields) {
                        merged[key] = original[key]
                    }
                }
                recovery[index].original = entry.path == Self.globalPath ? entry.original : try Self.encode(merged)
                recovery[index].fields = recovery[index].ownedFields.union(entry.ownedFields).sorted()
                originals[entry.path] = merged
            } else {
                recovery.append(entry)
                originals[entry.path] = original
            }
        }

        func reconcile(_ prior: Entry?, path: [String], observeOnly: Bool) throws {
            let desired = desiredFields(path, observeOnly: observeOnly)
            let previous = prior?.ownedFields ?? []
            let existing = Self.node(root, path: path)
            if existing == nil && desired.isEmpty { return }
            if existing == nil, !observeOnly, !previous.intersection(desired).isEmpty {
                throw LockScreenFailure(message: "A native wallpaper override was removed outside CineWall.")
            }

            var node = existing ?? [:]
            var linkedOriginal: [String: Any]?
            if let data = prior?.linkedOriginal {
                linkedOriginal = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            }
            var inheritedOriginal: [String: Any]?
            if let data = prior?.inheritedOriginal {
                inheritedOriginal = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            }

            if prior == nil, !desired.isEmpty {
                if Self.defaultLinkedChoice(node) != nil {
                    linkedOriginal = node
                } else if existing == nil, !observeOnly {
                    let inherited = try Self.restorationOriginal(
                        ["Type": "individual", "Desktop": selection, "Idle": selection],
                        path: path, root: root, fields: ["Desktop", "Idle"],
                        journaled: journaledOriginal, extID: extensionIdentifier
                    )
                    inheritedOriginal = inherited
                    node = inherited
                }
            }

            if !observeOnly, !desired.isEmpty, let linkedOriginal, existing == nil || Self.defaultLinkedChoice(node) != nil {
                node = Self.separatedLinked(node.isEmpty ? linkedOriginal : node)
            }
            if !observeOnly && !desired.isEmpty && existing != nil && node["Type"] as? String != "individual" {
                throw LockScreenFailure(message: "This display uses a linked or unsupported native wallpaper configuration.")
            }

            var original = prior.flatMap { originals[$0.path] } ?? [:]
            for key in previous.sorted() {
                if desired.contains(key) {
                    if !observeOnly && !Self.owns(node[key], extID: extensionIdentifier) {
                        throw LockScreenFailure(message: "The system wallpaper was changed externally. External choices will be preserved.")
                    }
                } else if Self.owns(node[key], extID: extensionIdentifier) {
                    node[key] = original[key]
                }
            }

            let added = desired.subtracting(previous)
            if !added.isEmpty {
                let restored = try Self.restorationOriginal(
                    Self.separatedLinked(node), path: path, root: root, fields: added,
                    journaled: journaledOriginal, extID: extensionIdentifier
                )
                for key in added { original[key] = restored[key] }
            }

            let typeOwned = prior.map { $0.typeOwned ?? true }
                ?? (!observeOnly && existing == nil && linkedOriginal == nil && inheritedOriginal == nil)
            if prior == nil && typeOwned { original["Type"] = existing?["Type"] }

            let fields = prior.map { $0.ownedFields.union(desired) } ?? desired
            var entry = Entry(
                path: path, original: try Self.encode(original), created: prior?.created ?? (existing == nil),
                observeOnly: observeOnly ? true : nil, fields: fields.sorted(),
                typeOwned: typeOwned ? true : nil,
                linkedOriginal: try linkedOriginal.map(Self.encode),
                inheritedOriginal: try inheritedOriginal.map(Self.encode)
            )

            if !observeOnly {
                if !desired.isEmpty { node["Type"] = "individual" }
                for field in desired { node[field] = selection }
            }

            if desired.isEmpty {
                if entry.created {
                    node = [:]
                } else {
                    node["Type"] = original["Type"] ?? node["Type"]
                    if let linkedOriginal {
                        node = linkedOriginal
                    } else if (node["Desktop"] != nil || node["Idle"] != nil),
                              let unlinked = Self.defaultLinkedChoice(node) {
                        node = Self.unseparatedLinked(node, choice: unlinked)
                    }
                }
            }

            if prior == nil, !desired.isEmpty {
                try record(entry, original: original)
            }
            if !desired.isEmpty || !(entry.created && node.isEmpty) {
                if desired.isEmpty { entry.fields = [] }
                retained.append(entry)
            }

            let updated: [String: Any]? = (entry.created && desired.isEmpty && node.isEmpty) ? nil : node
            if !NSDictionary(dictionary: existing ?? [:]).isEqual(to: updated ?? [:]) {
                changed = true
                Self.setNode(&root, path: path, value: updated)
            }
        }

        for path in fallbackPaths {
            try reconcile(entries.first(where: { $0.path == path }), path: path, observeOnly: true)
        }
        for path in paths {
            try reconcile(entries.first(where: { $0.path == path }), path: path, observeOnly: false)
        }

        // Global AllSpacesAndDisplays synchronization for macOS 14+
        let globalPrior = entries.first(where: { $0.path == Self.globalPath })
        let globalExisting = Self.node(root, path: Self.globalPath)
        let globalWasPresent = globalPrior?.globalWasPresent ?? (globalExisting != nil)

        if displays.isEmpty {
            if let prior = globalPrior {
                let original = try PropertyListSerialization.propertyList(from: prior.original, format: nil) as? [String: Any]
                let restored = globalWasPresent ? original : nil
                if !NSDictionary(dictionary: globalExisting ?? [:]).isEqual(to: restored ?? [:]) {
                    changed = true
                    Self.setNode(&root, path: Self.globalPath, value: restored)
                }
            }
        } else {
            var globalNode = globalExisting ?? [:]
            let original = globalPrior.flatMap { originals[$0.path] } ?? globalExisting ?? [:]
            if globalPrior == nil {
                let entry = Entry(
                    path: Self.globalPath, original: try Self.encode(original), created: globalExisting == nil,
                    observeOnly: false, fields: ["Idle"], typeOwned: true, globalWasPresent: globalWasPresent
                )
                try record(entry, original: original)
                retained.append(entry)
            } else if let prior = globalPrior {
                retained.append(prior)
            }

            globalNode["Type"] = "individual"
            globalNode["Idle"] = selection
            if !NSDictionary(dictionary: globalExisting ?? [:]).isEqual(to: globalNode) {
                changed = true
                Self.setNode(&root, path: Self.globalPath, value: globalNode)
            }
        }

        entries = recovery
        try persistJournalIfNeeded()

        if changed {
            try Self.encode(root).write(to: storeURL, options: .atomic)
            restartPending = true
        }

        if restartPending {
            try reload()
            restartPending = false
        }

        entries = retained
        try persistJournalIfNeeded()
        settled = request
    }

    private func loadJournal() {
        guard FileManager.default.fileExists(atPath: journalURL.path),
              let data = try? Data(contentsOf: journalURL),
              let decoded = try? PropertyListDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
        hasPersistedJournal = true
    }

    private func persistJournalIfNeeded() throws {
        if entries.isEmpty {
            if hasPersistedJournal {
                try persistJournal(journalURL, nil)
                hasPersistedJournal = false
            }
        } else {
            let data = try PropertyListEncoder().encode(entries)
            try persistJournal(journalURL, data)
            hasPersistedJournal = true
        }
    }

    private static func makeSelectionDict(extensionIdentifier: String, revision: String?) throws -> [String: Any] {
        let emptyOptionValues = try encode(["values": [String: Any]()])
        return [
            "Content": [
                "Choices": [
                    [
                        "Provider": extensionIdentifier,
                        "Configuration": Data((revision.map { "current:" + $0 } ?? "current").utf8),
                        "Files": [String](),
                    ]
                ],
                "Shuffle": "$null",
                "EncodedOptionValues": emptyOptionValues,
            ],
            "LastSet": Date(),
            "LastUse": Date(),
        ]
    }

    private static func owns(_ value: Any?, extID: String) -> Bool {
        guard let selection = value as? [String: Any],
              let content = selection["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]], choices.count == 1 else { return false }
        let provider = choices[0]["Provider"] as? String
        return provider == extID
    }

    private static func encode(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private static func storeVersion(_ url: URL) -> [Int]? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return [
            Int(info.st_dev), Int(truncatingIfNeeded: info.st_ino), Int(info.st_size),
            info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec,
            info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec,
        ]
    }

    private static func node(_ root: [String: Any], path: [String]) -> [String: Any]? {
        var node = root
        for key in path {
            guard let child = node[key] as? [String: Any] else { return nil }
            node = child
        }
        return node
    }

    private static func setNode(_ root: inout [String: Any], path: [String], value: [String: Any]?) {
        guard let key = path.first else { return }
        if path.count == 1 {
            root[key] = value
            return
        }
        var child = root[key] as? [String: Any] ?? [:]
        setNode(&child, path: Array(path.dropFirst()), value: value)
        root[key] = child
    }

    private static func defaultLinkedChoice(_ node: [String: Any]) -> [String: Any]? {
        guard node["Type"] as? String == "linked",
              let linked = node["Linked"] as? [String: Any] else { return nil }
        return linked
    }

    private static func separatedLinked(_ node: [String: Any]) -> [String: Any] {
        guard let linked = defaultLinkedChoice(node) else { return node }
        var result = node
        result["Type"] = "individual"
        result["Desktop"] = linked
        result["Idle"] = linked
        result.removeValue(forKey: "Linked")
        return result
    }

    private static func unseparatedLinked(_ node: [String: Any], choice: [String: Any]) -> [String: Any] {
        var result = node
        result["Type"] = "linked"
        result["Linked"] = choice
        result.removeValue(forKey: "Desktop")
        result.removeValue(forKey: "Idle")
        return result
    }

    private static func restorationOriginal(
        _ node: [String: Any], path: [String], root: [String: Any], fields: Set<String>,
        journaled: ([String]) -> [String: Any]?, extID: String
    ) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for field in fields {
            if let direct = node[field] as? [String: Any], !owns(direct, extID: extID) {
                result[field] = direct
                continue
            }
            var found: [String: Any]?
            for fallback in fallbackPaths(for: path) {
                if let original = journaled(fallback), let item = original[field] as? [String: Any], !owns(item, extID: extID) {
                    found = item
                    break
                }
                if let fallbackNode = Self.node(root, path: fallback) {
                    let separated = Self.separatedLinked(fallbackNode)
                    if let item = separated[field] as? [String: Any], !owns(item, extID: extID) {
                        found = item
                        break
                    }
                }
            }
            if let found {
                result[field] = found
            }
        }
        result["Type"] = node["Type"] ?? "individual"
        return result
    }

    private static func fallbackPaths(for path: [String]) -> [[String]] {
        var paths: [[String]] = []
        if path.count == 4, path[0] == "Spaces" {
            paths.append(["Displays", path[3]])
            paths.append(["Spaces", path[1], "Default"])
        }
        return paths + [["SystemDefault"], ["AllSpacesAndDisplays"]]
    }

    public static func reloadWallpaperAgent() throws {
        let expected = "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent"
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else {
            throw LockScreenFailure(message: "Unable to enumerate the wallpaper service.", reason: .transient)
        }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, Int(count) <= pids.count else {
            throw LockScreenFailure(message: "Unable to identify the wallpaper service safely.", reason: .transient)
        }
        var found = false
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == getuid(), info.pbi_ruid == getuid() else { continue }
            let length = path.withUnsafeMutableBytes {
                proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
            }
            guard length > 0, String(cString: path) == expected else { continue }
            guard kill(pid, SIGTERM) == 0 || errno == ESRCH else {
                throw LockScreenFailure(message: "macOS refused to reload WallpaperAgent (errno \(errno)).")
            }
            found = true
        }
        if found {
            lastReloadSignal = Date()
            return
        }
        if let last = lastReloadSignal, Date().timeIntervalSince(last) < 10 { return }
        throw LockScreenFailure(message: "No user-owned WallpaperAgent is currently running.", reason: .transient)
    }
}
