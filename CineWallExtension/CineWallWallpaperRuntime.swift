//
//  CineWallWallpaperRuntime.swift
//  CineWallExtension
//
//  Dynamic Private Framework Loader & Remote Context Marshaller.
//

import AppKit
import Foundation
import IOSurface
import os
import Security

public enum CineWallWallpaperRuntime {
    private static var handle: UnsafeMutableRawPointer?

    public static let exchange = LockScreenConfiguration.exchangeDirectory

    public static func load() throws {
        if handle == nil {
            guard let framework = dlopen(
                "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit",
                RTLD_LAZY
            ) else {
                throw failure("WallpaperExtensionKit is not available on this macOS version.")
            }
            handle = framework
        }
    }

    public static func failure(_ detail: String) -> NSError {
        NSError(domain: "CineWallWallpaperExtension", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }

    public static func contextReply(_ contextID: UInt32) throws -> AnyObject {
        try load()
        guard let cls = NSClassFromString("WallpaperRemoteContextXPC"),
              let ivar = class_getInstanceVariable(cls, "box") else {
            throw failure("Cannot allocate WallpaperRemoteContextXPC.")
        }
        guard let raw = class_createInstance(cls, 0) else {
            throw failure("Failed to instantiate WallpaperRemoteContextXPC.")
        }
        let offset = ivar_getOffset(ivar)
        let object = raw as AnyObject
        Unmanaged.passUnretained(object).toOpaque().advanced(by: offset).storeBytes(of: contextID, as: UInt32.self)
        return object
    }

    public static func snapshotReply(_ surface: IOSurface) throws -> AnyObject {
        try load()
        guard let cls = NSClassFromString("WallpaperSnapshotXPC"),
              let ivar = class_getInstanceVariable(cls, "rawValue") else {
            throw failure("Cannot allocate WallpaperSnapshotXPC.")
        }
        guard let raw = class_createInstance(cls, 0) else {
            throw failure("Failed to instantiate WallpaperSnapshotXPC.")
        }
        let offset = ivar_getOffset(ivar)
        let object = raw as AnyObject
        let retained = Unmanaged.passRetained(surface).toOpaque()
        Unmanaged.passUnretained(object).toOpaque().advanced(by: offset).storeBytes(of: retained, as: UnsafeMutableRawPointer.self)
        return object
    }

    public static func context(displayID: UInt32?) throws -> CAContext {
        guard let cls = NSClassFromString("CAContext") as? NSObject.Type else {
            throw failure("Missing CAContext class.")
        }
        let sel = NSSelectorFromString("remoteContextWithOptions:")
        guard cls.responds(to: sel) else {
            throw failure("CAContext does not respond to remoteContextWithOptions:")
        }
        var options: [String: Any] = [:]
        if let displayID {
            options["displayId"] = displayID
        }
        guard let ctx = cls.perform(sel, with: options)?.takeUnretainedValue() as? CAContext else {
            throw failure("Failed to create remote CAContext.")
        }
        return ctx
    }

    public static func accepts(_ connection: NSXPCConnection) -> Bool {
        guard connection.responds(to: NSSelectorFromString("auditToken")) else { return false }
        var token = connection.auditToken
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributeAudit: data] as CFDictionary,
            [],
            &code
        ) == errSecSuccess, let code else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            "anchor apple" as CFString,
            [],
            &requirement
        ) == errSecSuccess, let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    public static func field(_ label: String, in value: Any, depth: Int = 0) -> Any? {
        guard depth < 8 else { return nil }
        let mirror = Mirror(reflecting: value)
        if let child = mirror.children.first(where: { $0.label == label }) { return child.value }
        for child in mirror.children {
            if let result = field(label, in: child.value, depth: depth + 1) { return result }
        }
        return nil
    }

    public static func identifier(_ value: Any?) -> UUID? {
        guard let value else { return nil }
        if let id = value as? UUID { return id }
        if let direct = field("rawValue", in: value) as? UUID { return direct }
        if let nested = field("box", in: value), let id = field("rawValue", in: nested) as? UUID { return id }
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            if let id = child.value as? UUID { return id }
        }
        return nil
    }

    public static func enumCase(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .enum else { return "\(value)" }
        return mirror.children.first?.label ?? "\(value)"
    }

    public static func logRequestShape(_ kind: String, _ request: Any?) {
        guard let request else { return }
        log("\(kind) request type=\(type(of: request))")
    }

    public static func recordHostRelease(_ released: Bool) {
        let file = exchange.appendingPathComponent("released-\(getpid())")
        if released {
            try? "".write(to: file, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static let logger = Logger(subsystem: "svkr.CineWall", category: "Extension")

    public static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        NSLog("[CineWallExtension] %@", message)
    }
}
