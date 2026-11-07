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
        let home = LockScreenConfiguration.realUserHomeDirectory()
        let defaultStore = home.appendingPathComponent(
            "Library/Application Support/com.apple.wallpaper/Store/Index.plist"
        )
        let resolvedStore = storeURL ?? defaultStore
        let defaultFolder = folder ?? home.appendingPathComponent(
            "Library/Application Support/CineWall"
        )
        let resolvedJournal = journalURL ?? defaultFolder.appendingPathComponent("native-selection.plist")

        self.storeURL = resolvedStore
        self.journalURL = resolvedJournal
        self.reload = reload ?? {
            if resolvedStore == defaultStore {
                try LockScreenWallpaperSelection.reloadWallpaperAgent()
            }
        }
        self.persistJournal = persistJournal ?? LockScreenWallpaperSelection.persistJournalFile
    }

    public var isRestored: Bool {
        entries.isEmpty && !restartPending
    }

    public func recover() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let recovered = try PropertyListDecoder().decode([Entry].self, from: Data(contentsOf: journalURL))
        entries = recovered
        hasPersistedJournal = true
        restartPending = true
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
        let priorEntries = entries
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
            let removed = previous.subtracting(desired)
            let allPreviouslyOwned = previous.allSatisfy { Self.owns(node[$0], extID: extensionIdentifier) }

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

            if !observeOnly {
                for key in desired.sorted() {
                    let current = node[key] as? [String: Any]
                    let content = current?["Content"] as? [String: Any]
                    let choices = content?["Choices"] as? [[String: Any]]
                    let expected = (selection["Content"] as? [String: Any])?["Choices"] as? [[String: Any]]
                    if added.contains(key) || (revision != nil && choices?.first?["Configuration"] as? Data != expected?.first?["Configuration"] as? Data) {
                        node[key] = selection
                    }
                }
                if prior == nil && typeOwned { node["Type"] = "individual" }
            }

            if desired.isEmpty && !removed.isEmpty && typeOwned && allPreviouslyOwned
                && node["Type"] as? String == "individual"
                && ["Desktop", "Idle"].allSatisfy({ (node[$0] as? NSDictionary) == (original[$0] as? NSDictionary) }) {
                node["Type"] = original["Type"]
            }

            if desired.isEmpty, let linkedOriginal {
                let baseline = Self.separatedLinked(linkedOriginal)
                if prior?.created == true, (node as NSDictionary) == (baseline as NSDictionary) {
                    node = [:]
                } else {
                    node = Self.relinked(node, original: linkedOriginal)
                }
            }

            if desired.isEmpty, let inheritedOriginal, prior?.created == true, (node as NSDictionary) == (inheritedOriginal as NSDictionary) {
                node = [:]
            }

            if !desired.isEmpty {
                if !observeOnly, !(node["Desktop"] is [String: Any] && node["Idle"] is [String: Any]) {
                    throw LockScreenFailure(message: "This macOS wallpaper store format is unsupported.")
                }
                original = original.filter { desired.contains($0.key) || ($0.key == "Type" && typeOwned) }
                let originalData = (prior != nil && desired == previous) ? prior!.original : try Self.encode(original)
                let entry = Entry(
                    path: path, original: originalData, created: prior?.created ?? (existing == nil),
                    observeOnly: observeOnly, fields: desired.sorted(), typeOwned: typeOwned,
                    linkedOriginal: try prior.map(\.linkedOriginal) ?? linkedOriginal.map { try Self.encode($0) },
                    inheritedOriginal: try prior.map(\.inheritedOriginal) ?? inheritedOriginal.map { try Self.encode($0) }
                )
                if !added.isEmpty { try record(entry, original: original) }
                retained.append(entry)
            }

            let value: [String: Any]? = node.isEmpty && ((prior?.created ?? false) || existing == nil) ? nil : node
            if (existing as NSDictionary?) != (value as NSDictionary?) {
                Self.setNode(&root, path: path, value: value)
                changed = true
            }
        }

        let globalEntry = entries.first { $0.path == Self.globalPath }
        let global = Self.node(root, path: Self.globalPath)
        if !activeFields.isEmpty || globalEntry != nil {
            let previous = globalEntry?.ownedFields ?? []
            var original = globalEntry.flatMap { originals[$0.path] } ?? global ?? [:]
            let wasPresent = globalEntry?.globalWasPresent ?? (globalEntry == nil ? global != nil : !original.isEmpty)
            var restored = Self.separatedLinked(global ?? [:])
            let supported = restored.isEmpty || ["desktop", "idle", "individual"].contains(restored["Type"] as? String ?? "")

            if !activeFields.isEmpty {
                guard supported, previous.intersection(activeFields).allSatisfy({ restored[$0] == nil }) else {
                    throw LockScreenFailure(message: "The system wallpaper was changed externally. External choices will be preserved.")
                }
            }

            if supported && !(activeFields.isEmpty && global?["Type"] as? String == "linked") {
                if globalEntry != nil {
                    if let global {
                        let choiceKeys: Set<String> = ["Desktop", "Idle", "Linked", "Type"]
                        original = original.filter { choiceKeys.contains($0.key) }.merging(global.filter { !choiceKeys.contains($0.key) }) { _, new in new }
                    }
                    var expanded = Self.separatedLinked(original)
                    for key in activeFields.subtracting(previous) { expanded[key] = restored[key] }
                    if (expanded as NSDictionary) != (Self.separatedLinked(original) as NSDictionary) {
                        original = Self.globalNode(expanded) ?? [:]
                    }
                }
                if global == nil {
                    restored = original.filter { !["Desktop", "Idle", "Linked", "Type"].contains($0.key) }
                }
                for key in previous.subtracting(activeFields) where restored[key] == nil {
                    restored[key] = Self.separatedLinked(original)[key]
                }
                for key in activeFields { restored.removeValue(forKey: key) }
                var replacement = Self.globalNode(restored)
                if let node = replacement { replacement = Self.relinked(node, original: original) }
                if activeFields.isEmpty, (replacement as NSDictionary?) == (Self.globalNode(Self.separatedLinked(original)) as NSDictionary?) {
                    replacement = !original.isEmpty || wasPresent ? original : nil
                }
                if (global as NSDictionary?) != (replacement as NSDictionary?) {
                    Self.setNode(&root, path: Self.globalPath, value: replacement)
                    changed = true
                }
            }

            if !activeFields.isEmpty {
                let kept = globalEntry.flatMap { (originals[$0.path] as NSDictionary?) == (original as NSDictionary) ? $0.original : nil }
                let entry = Entry(
                    path: Self.globalPath, original: try kept ?? Self.encode(original),
                    created: globalEntry?.created ?? (global == nil), fields: activeFields.sorted(),
                    typeOwned: false, globalWasPresent: wasPresent
                )
                try record(entry, original: original)
                retained.append(entry)
            }
        }

        for entry in entries where entry.path != Self.globalPath {
            try reconcile(entry, path: entry.path, observeOnly: entry.observeOnly == true)
        }

        for path in fallbackPaths where !activeFields.isEmpty && !entries.contains(where: { $0.path == path }) {
            try reconcile(nil, path: path, observeOnly: true)
        }
        for path in paths where !entries.contains(where: { $0.path == path }) {
            try reconcile(nil, path: path, observeOnly: false)
        }

        if changed {
            try persistEntries(recovery)
            guard try Data(contentsOf: storeURL) == bytes else {
                entries = priorEntries
                throw LockScreenFailure(message: "The system wallpaper changed during selection. Please retry.", reason: .transient)
            }
            try Self.encode(root).write(to: storeURL, options: .atomic)
            restartPending = true
        }

        if restartPending {
            try reload()
            restartPending = false
        }

        let unchanged = !changed && retained == entries
        try persistEntries(retained)
        if unchanged { settled = request }
    }

    private func persistEntries(_ next: [Entry]) throws {
        guard next != entries || hasPersistedJournal != !next.isEmpty else { return }
        let data = try (next.isEmpty ? nil : PropertyListEncoder().encode(next))
        try persistJournal(journalURL, data)
        entries = next
        hasPersistedJournal = !next.isEmpty
    }

    public static func persistJournalFile(_ url: URL, _ data: Data?) throws {
        if let data {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func restorationOriginal(
        _ node: [String: Any],
        path: [String],
        root: [String: Any],
        fields: Set<String>,
        journaled: ([String]) -> [String: Any]?,
        extID: String
    ) throws -> [String: Any] {
        var original = node
        let fallbackPaths = Self.fallbackPaths(for: path)

        for field in fields.sorted() {
            if let direct = node[field] as? [String: Any], !owns(direct, extID: extID) {
                original[field] = direct
                continue
            }
            var fallbackChoice: [String: Any]?
            for fallback in fallbackPaths {
                if let journaled = journaled(fallback),
                   let choice = journaled[field] as? [String: Any], !owns(choice, extID: extID) {
                    fallbackChoice = choice
                    break
                }
                if let fallbackNode = Self.node(root, path: fallback) {
                    let separated = Self.separatedLinked(fallbackNode)
                    if let choice = separated[field] as? [String: Any], !owns(choice, extID: extID) {
                        fallbackChoice = choice
                        break
                    }
                }
            }
            if let fallbackChoice {
                original[field] = fallbackChoice
            } else {
                throw LockScreenFailure(message: "Cannot resolve a fallback wallpaper choice for \(field) on display \(path.last ?? "unknown").")
            }
        }
        original["Type"] = node["Type"] ?? "individual"
        return original
    }

    private static func defaultLinkedChoice(_ node: [String: Any]) -> [String: Any]? {
        guard node["Type"] as? String == "linked",
              let linked = node["Linked"] as? [String: Any],
              let content = linked["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]], !choices.isEmpty,
              choices.allSatisfy({ choice in
                  guard let provider = choice["Provider"] as? String, !provider.isEmpty else { return false }
                  return provider != LockScreenConfiguration.extensionIdentifier
              }) else { return nil }
        return linked
    }

    private static func separatedLinked(_ node: [String: Any]) -> [String: Any] {
        guard let linked = defaultLinkedChoice(node) else { return node }
        var result = node
        result.removeValue(forKey: "Linked")
        result["Type"] = "individual"
        result["Desktop"] = linked
        result["Idle"] = linked
        return result
    }

    private static func relinked(_ node: [String: Any], original: [String: Any]) -> [String: Any] {
        guard let linked = defaultLinkedChoice(original),
              node["Type"] as? String == "individual",
              ["Desktop", "Idle"].allSatisfy({ (node[$0] as? NSDictionary) == (linked as NSDictionary) }) else { return node }
        var result = node
        result.removeValue(forKey: "Desktop")
        result.removeValue(forKey: "Idle")
        result["Type"] = "linked"
        result["Linked"] = linked
        return result
    }

    private static func globalNode(_ node: [String: Any]) -> [String: Any]? {
        var result = node
        switch (node["Desktop"] != nil, node["Idle"] != nil) {
        case (true, true): result["Type"] = "individual"
        case (true, false): result["Type"] = "desktop"
        case (false, true): result["Type"] = "idle"
        case (false, false): return nil
        }
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
