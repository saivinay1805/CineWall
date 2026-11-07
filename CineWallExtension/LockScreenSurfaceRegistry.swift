//
//  LockScreenSurfaceRegistry.swift
//  CineWallExtension
//
//  Thread-safe registry mapping surface identity to rendering surface.
//

import Foundation

@MainActor
public protocol LockScreenSurfaceLifecycle: AnyObject {
    var isReusable: Bool { get }
    func stop()
}

@MainActor
public final class LockScreenSurfaceRegistry<Surface: LockScreenSurfaceLifecycle> {
    public struct Acquisition {
        public let surface: Surface
        public let generation: UInt64
        public let isNew: Bool

        public init(surface: Surface, generation: UInt64, isNew: Bool) {
            self.surface = surface
            self.generation = generation
            self.isNew = isNew
        }
    }

    private var entries: [UUID: Acquisition] = [:]
    private var generations: [UUID: UInt64] = [:]

    public var values: [Surface] {
        entries.values.map(\.surface)
    }

    public init() {}

    public subscript(id: UUID) -> Surface? {
        entries[id]?.surface
    }

    public func acquire(
        id: UUID,
        matches: (Surface) -> Bool,
        create: (UInt64) throws -> Surface
    ) rethrows -> Acquisition {
        if let entry = entries[id], entry.surface.isReusable, matches(entry.surface) {
            return Acquisition(surface: entry.surface, generation: entry.generation, isNew: false)
        }
        remove(id)
        let generation = (generations[id] ?? 0) &+ 1
        generations[id] = generation
        let surface = try create(generation)
        let entry = Acquisition(surface: surface, generation: generation, isNew: true)
        entries[id] = entry
        return entry
    }

    public func isCurrent(id: UUID, surface: Surface, generation: UInt64) -> Bool {
        guard let entry = entries[id] else { return false }
        return entry.surface === surface && entry.generation == generation
    }

    public func remove(_ id: UUID, matching surface: Surface? = nil) {
        guard let entry = entries[id], surface == nil || entry.surface === surface else { return }
        entries.removeValue(forKey: id)
        entry.surface.stop()
    }
}
