//
//  LockScreenPresentationAuthority.swift
//  CineWall
//
//  Power monitoring, session lock state detection, and presentation policy.
//

import CoreGraphics
import Foundation

public struct FastDisplayPowerProbe: Sendable {
    public var isAsleep: @Sendable (UInt32) -> Bool
    public var onlineDisplays: @Sendable () -> [UInt32]

    public static let system = FastDisplayPowerProbe(
        isAsleep: { CGDisplayIsAsleep($0) != 0 },
        onlineDisplays: {
            var count: UInt32 = 0
            guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
            return Array(displays.prefix(Int(count)))
        }
    )

    public func displaysAsleep(for displayID: UInt32?) -> Bool {
        if let displayID { return isAsleep(displayID) }
        let displays = onlineDisplays()
        return !displays.isEmpty && displays.allSatisfy(isAsleep)
    }
}

public enum FastWallpaperPresentationAuthority {
    public enum SurfaceRole: Sendable {
        case lockScreen
        case preview
    }

    public enum HostActivity: Sendable {
        case active
        case suspended
    }

    public struct SuspensionReasons: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let userPaused = SuspensionReasons(rawValue: 1 << 0)
        public static let displaysAsleep = SuspensionReasons(rawValue: 1 << 1)
        public static let hostSuspended = SuspensionReasons(rawValue: 1 << 2)
        public static let noConsumer = SuspensionReasons(rawValue: 1 << 3)
        public static let previewBudgetSpent = SuspensionReasons(rawValue: 1 << 4)
    }

    public struct Request: Sendable {
        public var role: SurfaceRole
        public var userPaused: Bool
        public var displaysAsleep: Bool
        public var sessionLocked: Bool
        public var sessionOnConsole: Bool
        public var presentationMode: String
        public var hostActivity: HostActivity
        public var presentedFor: Duration?
        public var continuousPreviewRequested: Bool
        public var lockScreenEnabled: Bool
        public var screenSaverEnabled: Bool

        public init(
            role: SurfaceRole,
            userPaused: Bool = false,
            displaysAsleep: Bool = false,
            sessionLocked: Bool = false,
            sessionOnConsole: Bool = true,
            presentationMode: String = "active",
            hostActivity: HostActivity = .active,
            presentedFor: Duration? = nil,
            continuousPreviewRequested: Bool = false,
            lockScreenEnabled: Bool = true,
            screenSaverEnabled: Bool = false
        ) {
            self.role = role
            self.userPaused = userPaused
            self.displaysAsleep = displaysAsleep
            self.sessionLocked = sessionLocked
            self.sessionOnConsole = sessionOnConsole
            self.presentationMode = presentationMode
            self.hostActivity = hostActivity
            self.presentedFor = presentedFor
            self.continuousPreviewRequested = continuousPreviewRequested
            self.lockScreenEnabled = lockScreenEnabled
            self.screenSaverEnabled = screenSaverEnabled
        }
    }

    public static let previewBudget: Duration = .seconds(30)
    public static let desktopSettleBudget: Duration = .seconds(2)

    public static func suspensionReasons(for request: Request) -> SuspensionReasons {
        var reasons: SuspensionReasons = []
        if request.userPaused { reasons.insert(.userPaused) }
        if request.displaysAsleep { reasons.insert(.displaysAsleep) }
        if request.hostActivity == .suspended { reasons.insert(.hostSuspended) }
        if !request.sessionOnConsole { reasons.insert(.noConsumer) }

        switch request.role {
        case .preview:
            if !request.continuousPreviewRequested, let presented = request.presentedFor, presented >= previewBudget {
                reasons.insert(.previewBudgetSpent)
            }
        case .lockScreen:
            let isIdleScreensaver = request.presentationMode == "idle"
            let activeConsumer = request.sessionLocked || (isIdleScreensaver && request.screenSaverEnabled) || request.lockScreenEnabled
            if !activeConsumer {
                reasons.insert(.noConsumer)
            }
        }
        return reasons
    }

    public struct SessionState: Equatable, Sendable {
        public var locked: Bool
        public var onConsole: Bool

        public init(locked: Bool = false, onConsole: Bool = true) {
            self.locked = locked
            self.onConsole = onConsole
        }

        public init(dictionary: [String: Any]?) {
            self.locked = dictionary?["CGSSessionScreenIsLocked"] as? Bool ?? false
            self.onConsole = dictionary?["kCGSSessionOnConsoleKey"] as? Bool ?? true
        }

        public static func current() -> SessionState {
            SessionState(dictionary: CGSessionCopyCurrentDictionary() as? [String: Any])
        }
    }
}

@MainActor
public final class FastLockScreenReevaluationBurst {
    public typealias Schedule = (Duration, @escaping @MainActor () -> Void) -> (() -> Void)
    nonisolated public static let defaultOffsets: [Duration] = [.milliseconds(250), .milliseconds(750), .seconds(2)]

    private let offsets: [Duration]
    private let schedule: Schedule
    private let perform: @MainActor () -> Void
    private var generation: UInt64 = 0
    private var cancels: [() -> Void] = []

    nonisolated public static func scheduleBySleeping(after delay: Duration, work: @escaping @MainActor () -> Void) -> (() -> Void) {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            work()
        }
        return { task.cancel() }
    }

    public init(
        offsets: [Duration] = FastLockScreenReevaluationBurst.defaultOffsets,
        schedule: @escaping Schedule = FastLockScreenReevaluationBurst.scheduleBySleeping,
        perform: @escaping @MainActor () -> Void
    ) {
        self.offsets = offsets
        self.schedule = schedule
        self.perform = perform
    }

    public func trigger() {
        cancel()
        let current = generation
        for offset in offsets {
            cancels.append(
                schedule(offset) { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.perform()
                }
            )
        }
        perform()
    }

    public func cancel() {
        generation &+= 1
        let pending = cancels
        cancels.removeAll()
        pending.forEach { $0() }
    }
}
