import XCTest
@testable import MatildeKit
import MatildeKitTesting

final class SyncServerSelectionTests: XCTestCase {
    private let staging = SyncServer.staging.baseURL.absoluteString
    private let production = SyncServer.production.baseURL.absoluteString

    private func resolve(_ arguments: [String] = [], override: String? = nil, stored: String? = nil, debug: Bool) -> SyncServerSelection.Resolution {
        SyncServerSelection.resolve(arguments: ["Matilde"] + arguments, override: override, storedURL: stored, debug: debug)
    }

    func testReleaseBuildUsesProductionByDefault() {
        XCTAssertEqual(resolve(debug: false), .init(server: .production, replaced: nil))
        XCTAssertEqual(resolve(stored: production, debug: false), .init(server: .production, replaced: nil))
    }

    func testReleaseBuildIgnoresStoredStagingAndSignsOutOfIt() {
        XCTAssertEqual(resolve(stored: staging, debug: false), .init(server: .production, replaced: .staging))
    }

    func testReleaseBuildSelectsStagingWithHiddenDefaultOrLaunchArgument() {
        XCTAssertEqual(resolve(override: "staging", debug: false), .init(server: .staging, replaced: nil))
        XCTAssertEqual(resolve(override: " Staging\n", stored: production, debug: false), .init(server: .staging, replaced: .production))
        XCTAssertEqual(resolve(["--sync-server", "staging"], debug: false), .init(server: .staging, replaced: nil))
        XCTAssertEqual(resolve(["--sync-server", "staging"], stored: staging, debug: false), .init(server: .staging, replaced: nil))
    }

    func testLaunchArgumentWinsOverHiddenDefault() {
        XCTAssertEqual(resolve(["--sync-server", "production"], override: "staging", stored: staging, debug: false),
                       .init(server: .production, replaced: .staging))
    }

    func testUnknownValuesFallBackToProduction() {
        XCTAssertEqual(resolve(["--sync-server", "https://evil.example/v1/"], override: "nope", debug: false).server, .production)
        XCTAssertEqual(resolve(["--sync-server"], debug: false).server, .production)
        XCTAssertEqual(resolve(stored: "https://evil.example/v1/", debug: true), .init(server: .production, replaced: nil))
    }

    func testDebugBuildKeepsThePickersChoice() {
        XCTAssertEqual(resolve(stored: staging, debug: true), .init(server: .staging, replaced: nil))
        XCTAssertEqual(resolve(stored: production, debug: true), .init(server: .production, replaced: nil))
        XCTAssertEqual(resolve(override: "production", stored: staging, debug: true), .init(server: .production, replaced: .staging))
    }

    func testReadsTheHiddenDefault() {
        let suite = "SyncServerSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(staging, forKey: "sync.serverURL")
        XCTAssertEqual(SyncServerSelection.resolve(defaults: defaults, storedKey: "sync.serverURL", arguments: ["Matilde"]).server,
                       SyncServerSelection.isDebugBuild ? .staging : .production)
        defaults.set("staging", forKey: SyncServerSelection.overrideKey)
        XCTAssertEqual(SyncServerSelection.resolve(defaults: defaults, storedKey: "sync.serverURL", arguments: ["Matilde"]),
                       .init(server: .staging, replaced: nil))
    }
}
