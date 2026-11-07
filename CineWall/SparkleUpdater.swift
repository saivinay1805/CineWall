import Cocoa

#if canImport(Sparkle)
import Sparkle
#endif

enum SparkleUpdaterError: LocalizedError {
    case frameworkUnavailable
    case feedURLMissing
    case publicKeyMissing
    case insecureFeedURL

    var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            return "Sparkle is linked in the project, but this build cannot import it yet. Re-open the project in Xcode and let Swift Package Manager finish resolving dependencies."
        case .feedURLMissing:
            return "Add a real SUFeedURL before shipping updates. Right now CineWall is wired for Sparkle, but the update feed is still a placeholder."
        case .publicKeyMissing:
            return "Add your Sparkle SUPublicEDKey before shipping updates. Generate your Ed25519 key pair and paste the public key into Info.plist."
        case .insecureFeedURL:
            return "Sparkle updates should be served from an HTTPS appcast feed."
        }
    }
}

final class SparkleUpdater: NSObject {
    static let shared = SparkleUpdater()

    #if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController
    #endif

    override private init() {
        #if canImport(Sparkle)
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
        super.init()
    }

    var statusLine: String {
        switch configurationError {
        case nil:
            #if canImport(Sparkle)
            return "Automatic app updates are configured."
            #else
            return "Automatic app updates will work after Sparkle resolves in Xcode."
            #endif
        case .frameworkUnavailable:
            return "Sparkle package is waiting to resolve in Xcode."
        case .feedURLMissing:
            return "Set your appcast feed URL to enable updates."
        case .publicKeyMissing:
            return "Add your Sparkle public key to enable updates."
        case .insecureFeedURL:
            return "Use an HTTPS appcast feed for Sparkle."
        }
    }

    func checkForUpdates() throws {
        if let configurationError {
            throw configurationError
        }

        #if canImport(Sparkle)
        updaterController.checkForUpdates(nil)
        #else
        throw SparkleUpdaterError.frameworkUnavailable
        #endif
    }

    private var configurationError: SparkleUpdaterError? {
        #if !canImport(Sparkle)
        return .frameworkUnavailable
        #else
        guard let feedURL = nonPlaceholderValue(for: "SUFeedURL") else {
            return .feedURLMissing
        }
        guard URL(string: feedURL)?.scheme?.lowercased() == "https" else {
            return .insecureFeedURL
        }
        guard nonPlaceholderValue(for: "SUPublicEDKey") != nil else {
            return .publicKeyMissing
        }
        return nil
        #endif
    }

    private func nonPlaceholderValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("REPLACE_WITH") else {
            return nil
        }
        return trimmed
    }
}
