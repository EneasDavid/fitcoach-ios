import Foundation
import Testing
@testable import FitCoach

// Which environment a launch gets: production (Firebase), or the in-memory demo. These tests never touch Firebase.

/// A `ProcessInfo` with scripted launch arguments / environment (a real one inside a test run always carries `XCTest…` variables).
private final class ScriptedProcessInfo: ProcessInfo, @unchecked Sendable {
    private let scriptedArguments: [String]
    private let scriptedEnvironment: [String: String]

    init(arguments: [String] = [], environment: [String: String] = [:]) {
        scriptedArguments = arguments
        scriptedEnvironment = environment
        super.init()
    }

    override var arguments: [String] { scriptedArguments }
    override var environment: [String: String] { scriptedEnvironment }
}

@Suite("App environment selection")
struct AppEnvironmentTests {
    @Test("A normal launch with Firebase configured is production")
    func productionWhenConfigured() {
        #expect(AppEnvironment.detect(ScriptedProcessInfo(), firebaseConfigured: true) == .production)
    }

    @Test("-UITestMode is always the demo, configured or not, and -UITestOffline starts it offline")
    func uiTestModeWins() {
        let online = ScriptedProcessInfo(arguments: ["-UITestMode"])
        let offline = ScriptedProcessInfo(arguments: ["-UITestMode", "-UITestOffline"])
        #expect(AppEnvironment.detect(online, firebaseConfigured: true) == .uiTesting(startOffline: false))
        #expect(AppEnvironment.detect(offline, firebaseConfigured: true) == .uiTesting(startOffline: true))
        #expect(AppEnvironment.detect(online, firebaseConfigured: false) == .uiTesting(startOffline: false))
    }

    @Test("A launch hosted by a test run is never production")
    func testHostIsDemo() {
        let hosted = ScriptedProcessInfo(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"])
        #expect(AppEnvironment.detect(hosted, firebaseConfigured: true) == .uiTesting(startOffline: false))
    }

    @Test("Without GoogleService-Info.plist a debug build opens the demo; a release build does not fall back")
    func missingPlist() {
        let result = AppEnvironment.detect(ScriptedProcessInfo(), firebaseConfigured: false)
        #if DEBUG
        #expect(result == .uiTesting(startOffline: false))
        #else
        #expect(result == .production)
        #endif
    }

    @Test("The plist check looks inside the given bundle")
    func plistLookup() throws {
        // Two separate folders: Foundation caches a bundle's directory listing, so one folder checked before and after would lie.
        func bundle(withPlist: Bool) throws -> (Bundle, URL) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fitcoach-bundle-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if withPlist { try Data("<plist/>".utf8).write(to: folder.appendingPathComponent("GoogleService-Info.plist")) }
            return (try #require(Bundle(path: folder.path)), folder)
        }
        let (empty, emptyFolder) = try bundle(withPlist: false)
        let (configured, configuredFolder) = try bundle(withPlist: true)
        defer {
            try? FileManager.default.removeItem(at: emptyFolder)
            try? FileManager.default.removeItem(at: configuredFolder)
        }
        #expect(!AppEnvironment.hasFirebaseConfiguration(in: empty))
        #expect(AppEnvironment.hasFirebaseConfiguration(in: configured))
    }
}
