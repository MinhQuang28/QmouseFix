import XCTest
@testable import QmouseFix

/// Guards the persisted-config contract: round-trips, tolerant decoding (a missing key must fall back
/// to a default, never throw — throwing would wipe the user's saved settings), and the legacy
/// `smoothScroll` bool → `ScrollMode` bridge.
final class AppConfigTests: XCTestCase {

    private func roundTrip(_ config: AppConfig) throws -> AppConfig {
        let data = try JSONEncoder().encode(config)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    func testDefaultsRoundTrip() throws {
        let decoded = try roundTrip(AppConfig())
        XCTAssertEqual(decoded.enabled, true)
        XCTAssertEqual(decoded.scrollMode, .smooth)
        XCTAssertEqual(decoded.scrollSpeed, 0.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.scrollLines, 3)
        XCTAssertEqual(decoded.smoothHighRes, false)
        XCTAssertEqual(decoded.reverseScroll, false)
        XCTAssertEqual(decoded.mappings.count, AppConfig.defaultMappings.count)
    }

    func testNonDefaultValuesPersist() throws {
        var config = AppConfig()
        config.enabled = false
        config.reverseScroll = true
        config.scrollMode = .smoothStep
        config.scrollSpeed = 1.3
        config.scrollLines = 7
        config.smoothHighRes = true
        config.spaceDragButton = 4
        config.spaceDragThreshold = 250
        config.spaceDragReverse = true
        config.mappings = [ButtonMapping(buttonNumber: 6, action: .missionControl)]

        let decoded = try roundTrip(config)
        XCTAssertEqual(decoded.enabled, false)
        XCTAssertEqual(decoded.reverseScroll, true)
        XCTAssertEqual(decoded.scrollMode, .smoothStep)
        XCTAssertEqual(decoded.scrollSpeed, 1.3, accuracy: 1e-9)
        XCTAssertEqual(decoded.scrollLines, 7)
        XCTAssertEqual(decoded.smoothHighRes, true)
        XCTAssertEqual(decoded.spaceDragButton, 4)
        XCTAssertEqual(decoded.spaceDragThreshold, 250, accuracy: 1e-9)
        XCTAssertEqual(decoded.spaceDragReverse, true)
        XCTAssertEqual(decoded.mappings, config.mappings)
    }

    /// An old config saved before a setting existed must decode with that setting at its default,
    /// not throw and reset everything.
    func testMissingKeysFallBackToDefaults() throws {
        let partial = #"{"enabled":false,"reverseScroll":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: partial)
        XCTAssertEqual(decoded.enabled, false)
        XCTAssertEqual(decoded.reverseScroll, true)
        // Everything absent falls back to defaults.
        XCTAssertEqual(decoded.scrollMode, .smooth)
        XCTAssertEqual(decoded.scrollLines, 3)
        XCTAssertEqual(decoded.smoothHighRes, false)
        XCTAssertEqual(decoded.mappings.count, AppConfig.defaultMappings.count)
    }

    func testEmptyObjectDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: #"{}"#.data(using: .utf8)!)
        XCTAssertEqual(decoded.scrollMode, AppConfig().scrollMode)
        XCTAssertEqual(decoded.scrollSpeed, AppConfig().scrollSpeed, accuracy: 1e-9)
    }

    /// Legacy bridge: configs predating `scrollMode` stored a `smoothScroll` bool.
    func testLegacySmoothScrollTrueMapsToSmooth() throws {
        let legacy = #"{"smoothScroll":true}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: legacy).scrollMode, .smooth)
    }

    func testLegacySmoothScrollFalseMapsToStandard() throws {
        let legacy = #"{"smoothScroll":false}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: legacy).scrollMode, .standard)
    }

    /// A present `scrollMode` wins over the legacy bool when both appear.
    func testScrollModeWinsOverLegacyBool() throws {
        let both = #"{"scrollMode":"smoothStep","smoothScroll":false}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: both).scrollMode, .smoothStep)
    }
}
