//
//  LockScreenExtensionRegistration.swift
//  CineWall
//
//  ExtensionKit Registration, Election, and Reconciliation.
//

import Foundation

public actor LockScreenExtensionRegistration {
    public static let extensionPath = "Contents/Extensions/CineWallExtension.appex"

    private static let pluginKit = URL(fileURLWithPath: "/usr/bin/pluginkit")
    private static let launchServices = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")

    private let app: URL
    private let targetExtensionIdentifier: String

    public init(
        currentAppURL: URL = Bundle.main.bundleURL,
        targetExtensionIdentifier: String = LockScreenConfiguration.extensionIdentifier
    ) {
        let appURL: URL
        if currentAppURL.pathExtension == "app" {
            appURL = currentAppURL
        } else {
            let installedApp = URL(fileURLWithPath: "/Applications/CineWall.app")
            if FileManager.default.fileExists(atPath: installedApp.path) {
                appURL = installedApp
            } else {
                appURL = currentAppURL
            }
        }
        self.app = appURL.resolvingSymlinksInPath().standardizedFileURL
        self.targetExtensionIdentifier = targetExtensionIdentifier
    }

    public func reconcile() async throws -> URL {
        let intended = app.appendingPathComponent(Self.extensionPath)
        guard FileManager.default.fileExists(atPath: intended.path) else {
            return intended
        }

        let registered = try await registrations()
        let others = registered.map(\.url).filter { $0.standardizedFileURL.path != intended.standardizedFileURL.path }
        if others.isEmpty, registered.contains(where: { $0.url.standardizedFileURL.path == intended.standardizedFileURL.path }) {
            try checkElection(registered, intended: intended)
            return intended
        }

        _ = try? await Self.runCommand(Self.launchServices, ["-f", app.path])
        _ = try? await Self.runCommand(Self.pluginKit, ["-a", intended.path])
        _ = try? await Self.runCommand(Self.pluginKit, ["-e", "use", "-i", targetExtensionIdentifier])

        return intended
    }

    public func enableExtension() async throws {
        _ = try? await Self.runCommand(Self.pluginKit, ["-e", "use", "-i", targetExtensionIdentifier])
    }

    public enum Mark: Equatable, Sendable {
        case blank, elected, ignored, superseded, debugger, unknown
    }

    public struct Record: Equatable, Sendable {
        public var url: URL
        public var mark: Mark

        public init(url: URL, mark: Mark) {
            self.url = url
            self.mark = mark
        }
    }

    private func checkElection(_ records: [Record], intended: URL) throws {
        guard let record = records.first(where: { $0.url.standardizedFileURL.path == intended.standardizedFileURL.path }) else { return }
        if record.mark == .ignored {
            throw LockScreenFailure(
                message: "macOS has the lock-screen extension turned off in System Settings. Enable it or retry to activate.",
                reason: .extensionTurnedOff
            )
        }
    }

    private func registrations() async throws -> [Record] {
        let output = (try? await Self.runCommand(Self.pluginKit, [
            "-m", "-A", "-D", "-v", "-i", targetExtensionIdentifier,
        ])) ?? ""
        return (try? Self.parseRecords(output, extensionID: targetExtensionIdentifier)) ?? []
    }

    public static func parseRecords(_ output: String, extensionID: String) throws -> [Record] {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines == ["(no matches)"] { return [] }
        var result: [Record] = []
        for line in lines {
            if line.hasPrefix("(") && (line.hasSuffix(" plug-ins)") || line.hasSuffix(" plug-in)")) {
                continue
            }
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 4 else { continue }
            let head = fields[0]
            let path = fields[3]
            var mark: Mark = .blank
            if head.hasPrefix("+") { mark = .elected }
            else if head.hasPrefix("-") { mark = .ignored }
            else if head.hasPrefix("=") { mark = .superseded }
            else if head.hasPrefix("!") { mark = .debugger }

            result.append(Record(url: URL(fileURLWithPath: String(path)).standardizedFileURL, mark: mark))
        }
        return result
    }

    public static func runCommand(_ executable: URL, _ arguments: [String]) async throws -> String {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
