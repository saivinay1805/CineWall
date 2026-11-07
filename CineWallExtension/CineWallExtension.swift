//
//  CineWallExtension.swift
//  CineWallExtension
//
//  ExtensionKit Entry Point Implementing WallpaperExtensionXPCProtocol.
//

import AppKit
import ExtensionFoundation

private final class CineWallWallpaperHandler: NSObject, WallpaperExtensionXPCProtocol {
    override init() {
        super.init()
    }

    func acquire(withId identifier: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
        DispatchQueue.main.async {
            CineWallWallpaperController.shared.acquire(id: identifier, request: request, reply: reply)
        }
    }

    func update(withId identifier: Any?, request: Any?, reply: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            do {
                try CineWallWallpaperController.shared.update(id: identifier, request: request)
                reply(nil)
            } catch {
                reply(error)
            }
        }
    }

    func invalidate(withId identifier: Any?, reply: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            CineWallWallpaperController.shared.invalidate(id: identifier)
            reply(nil)
        }
    }

    func snapshot(withId identifier: Any?, reply: @escaping (Any?, Error?) -> Void) {
        DispatchQueue.main.async {
            CineWallWallpaperController.shared.snapshot(id: identifier, reply: reply)
        }
    }

    func provideSettingsViewModels(withContentTypes types: Any?, reply: @escaping (Any?, Error?) -> Void) {
        reply(nil, nil)
    }

    func isChoiceDownloaded(with choiceID: Any?, reply: @escaping (Any?, Error?) -> Void) {
        reply(NSNumber(value: true), nil)
    }

    func selectedChoicesDidChange(for identifier: Any?, reply: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            CineWallWallpaperController.shared.reload()
            reply(nil)
        }
    }

    func handleNotification(withNamed name: String?, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func migrateSelectedChoice(for choiceID: Any?, reply: @escaping (Any?, Error?) -> Void) {
        reply(choiceID, nil)
    }

    func migrate(from: Any?, to: Any?, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func addChoiceRequest(withChoiceRequest choiceRequest: Any?, onBehalfOfProcess process: Any?, reply: @escaping (Any?, Error?) -> Void) {
        reply(nil, nil)
    }

    func canSkipShuffledContent(withId identifier: Any?, reply: @escaping (Bool, Error?) -> Void) {
        reply(false, nil)
    }

    func skipShuffledContent(withId identifier: Any?, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func removeChoiceRequest(withChoiceRequest choiceRequest: Any?, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func download(withChoiceID choiceID: Any?, reply: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        reply(nil)
        return progress
    }

    func cancelDownload(for choiceID: Any?, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func pauseDownload(for choiceID: Any?, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func resumeDownload(for choiceID: Any?, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func removeDownload(for choiceID: Any?, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func invokeContextMenuAction(withMenuItemID itemID: String?, groupItemID: String?, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func handleDebugRequest(for request: Any?, reply: @escaping (Any?, Error?) -> Void) {
        reply(nil, nil)
    }
}

private struct CineWallWallpaperConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        guard CineWallWallpaperRuntime.accepts(connection) else {
            CineWallWallpaperRuntime.log("Rejected untrusted wallpaper host.")
            return false
        }
        do {
            try CineWallWallpaperRuntime.load()
        } catch {
            CineWallWallpaperRuntime.log(error.localizedDescription)
            return false
        }
        let interface = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)
        let names = [
            "WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperContentTypeSetXPC",
            "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC", "WallpaperSettingsViewModelsXPC",
            "WallpaperExtensionChoiceRequestXPC", "AuditTokenXPC", "WallpaperDebugRequestXPC",
            "WallpaperMigrationVersionXPC",
        ]
        let classes = NSSet(
            array: names.compactMap(NSClassFromString) + [
                NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self, NSURL.self,
                NSError.self,
            ]
        ) as! Set<AnyHashable>
        for (selector, indexes, reply) in [
            ("acquireWithId:request:reply:", [0, 1], false), ("acquireWithId:request:reply:", [0], true),
            ("updateWithId:request:reply:", [0, 1], false), ("invalidateWithId:reply:", [0], false),
            ("snapshotWithId:reply:", [0], false), ("snapshotWithId:reply:", [0], true),
            ("provideSettingsViewModelsWithContentTypes:reply:", [0], false),
            ("provideSettingsViewModelsWithContentTypes:reply:", [0], true),
            ("isChoiceDownloadedWith:reply:", [0], false),
            ("selectedChoicesDidChangeFor:reply:", [0], false),
            ("migrateSelectedChoiceFor:reply:", [0], false),
            ("migrateSelectedChoiceFor:reply:", [0], true),
            ("migrateFrom:to:reply:", [0, 1], false),
            ("addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:", [0, 1], false),
            ("removeChoiceRequestWithChoiceRequest:reply:", [0], false),
            ("canSkipShuffledContentWithId:reply:", [0], false),
            ("skipShuffledContentWithId:reply:", [0], false),
            ("downloadWithChoiceID:reply:", [0], false),
            ("cancelDownloadFor:reply:", [0], false), ("pauseDownloadFor:reply:", [0], false),
            ("resumeDownloadFor:reply:", [0], false), ("removeDownloadFor:reply:", [0], false),
            ("invokeContextMenuActionWithMenuItemID:groupItemID:reply:", [0, 1], false),
            ("handleDebugRequestFor:reply:", [0], false),
            ("handleNotificationWithNamed:reply:", [0], false),
        ] {
            for index in indexes {
                interface.setClasses(classes, for: NSSelectorFromString(selector), argumentIndex: index, ofReply: reply)
            }
        }
        connection.exportedInterface = interface
        connection.exportedObject = CineWallWallpaperHandler()
        CineWallWallpaperRuntime.recordHostRelease(false)
        let pid = connection.processIdentifier
        connection.invalidationHandler = {
            DispatchQueue.main.async {
                CineWallWallpaperRuntime.recordHostRelease(true)
                CineWallWallpaperRuntime.log("Connection closed pid=\(pid)")
            }
        }
        connection.resume()
        CineWallWallpaperRuntime.log("Accepted native host pid=\(connection.processIdentifier)")
        return true
    }
}

@main
final class CineWallExtension: NSObject, AppExtension {
    override required init() {
        super.init()
        do {
            try CineWallWallpaperRuntime.load()
            DispatchQueue.main.async { CineWallWallpaperController.shared.start() }
            CineWallWallpaperRuntime.log("CineWall wallpaper extension started: bundle=\(Bundle.main.bundleURL.path)")
        } catch {
            CineWallWallpaperRuntime.log("Unavailable: \(error.localizedDescription)")
        }
    }

    var configuration: some AppExtensionConfiguration { CineWallWallpaperConfiguration() }
}
