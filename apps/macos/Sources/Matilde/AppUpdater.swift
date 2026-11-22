import Combine
import Sparkle
import SwiftUI
import MatildeKit

/// Sparkle owns update discovery, signature validation, installation, and relaunch.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController?

    init() {
        // swift run / tests are not distributable app bundles.
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        // The feed (matilde.page/appcast.xml) keeps an anonymous count of update checks by app
        // version and macOS major version, read from this user agent; nothing else is sent.
        // Sparkle's default is "Matilde/<version> Sparkle/<version>".
        let macOS = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        controller.updater.userAgentString = "\(controller.updater.userAgentString) macOS/\(macOS)"
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        controller.startUpdater()
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
