//
//  LockScreenConfiguration.swift
//  CineWall
//
//  ExtensionKit Lock Screen & Screen Saver Configuration Schema (Version 2).
//  Hardware-accelerated Wallpaper Extension Protocol Parity.
//

import Foundation

public struct LockScreenFraming: Codable, Equatable, Sendable {
    public static let centered = LockScreenFraming(panX: 0.5, panY: 0.5)

    public var panX: Double = 0.5
    public var panY: Double = 0.5

    public var isValid: Bool {
        (0.0...1.0).contains(panX) && (0.0...1.0).contains(panY)
    }

    public init(panX: Double = 0.5, panY: Double = 0.5) {
        self.panX = panX
        self.panY = panY
    }
}

public struct LockScreenScene: Codable, Equatable, Sendable {
    public var displayID: UInt32
    public var title: String
    /// Paths relative to the exchange directory, never external URLs.
    public var projectPath: String
    public var assetsPath: String
    public var previewPath: String?
    public var fps: UInt32
    /// Native renderer values: none=0, stretch=1, match/fit=2, fill=3.
    public var scalingMode: Int32
    public var scalingFactor: Double
    public var paused: Bool
    public var framing: LockScreenFraming?
    public var plainVideo: Bool?
    public var nativeVideoFile: String?

    public var effectiveFraming: LockScreenFraming {
        framing ?? .centered
    }

    public init(
        displayID: UInt32,
        title: String,
        projectPath: String,
        assetsPath: String,
        previewPath: String? = nil,
        fps: UInt32 = 60,
        scalingMode: Int32 = 3,
        scalingFactor: Double = 1.0,
        paused: Bool = false,
        framing: LockScreenFraming? = .centered,
        plainVideo: Bool? = true,
        nativeVideoFile: String? = nil
    ) {
        self.displayID = displayID
        self.title = title
        self.projectPath = projectPath
        self.assetsPath = assetsPath
        self.previewPath = previewPath
        self.fps = fps
        self.scalingMode = scalingMode
        self.scalingFactor = scalingFactor
        self.paused = paused
        self.framing = framing
        self.plainVideo = plainVideo
        self.nativeVideoFile = nativeVideoFile
    }

    public func sharesRenderer(with other: LockScreenScene) -> Bool {
        displayID == other.displayID &&
        projectPath == other.projectPath &&
        nativeVideoFile == other.nativeVideoFile
    }
}

public struct LockScreenConfiguration: Codable, Equatable, Sendable {
    public static let supportedVersion = 2
    public static let fileName = "configuration.json"
    public static let changedNotification = "svkr.CineWall.lock-screen.changed"
    public static let extensionIdentifier = "svkr.CineWall.wallpaper-extension"

    public static let exchangeRelativePath = "Library/Application Support/CineWall/LockScreenExchange"

    public static func realUserHomeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var exchangeDirectory: URL {
        realUserHomeDirectory().appendingPathComponent(exchangeRelativePath, isDirectory: true)
    }

    public var version: Int
    public var revision: String
    public var scenes: [LockScreenScene]
    public var lockScreenEnabled: Bool
    public var screenSaverEnabled: Bool

    public init(
        version: Int = supportedVersion,
        revision: String = UUID().uuidString,
        scenes: [LockScreenScene],
        lockScreenEnabled: Bool = true,
        screenSaverEnabled: Bool = false
    ) {
        self.version = version
        self.revision = revision
        self.scenes = scenes
        self.lockScreenEnabled = lockScreenEnabled
        self.screenSaverEnabled = screenSaverEnabled
    }
}

public struct LockScreenReadiness: Codable, Sendable {
    public var revision: String
    public var displayID: UInt32
    public var error: String?
    public var held: String?
    public var processID: Int32?

    public init(
        revision: String,
        displayID: UInt32,
        error: String? = nil,
        held: String? = nil,
        processID: Int32? = nil
    ) {
        self.revision = revision
        self.displayID = displayID
        self.error = error
        self.held = held
        self.processID = processID
    }
}

public struct LockScreenShutdownAck: Codable, Equatable, Sendable {
    public var revision: String
    public var processID: Int32
    public var timestamp: TimeInterval
    public var error: String?

    public init(
        revision: String,
        processID: Int32,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        error: String? = nil
    ) {
        self.revision = revision
        self.processID = processID
        self.timestamp = timestamp
        self.error = error
    }

    public static func fileName(forPID pid: Int32) -> String {
        "shutdown-ack-\(pid).json"
    }
}
