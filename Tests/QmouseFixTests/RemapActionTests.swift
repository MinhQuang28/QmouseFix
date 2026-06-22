import XCTest
@testable import QmouseFix

/// Guards the button-action model: every variant must survive Codable round-trips (a mapping that
/// fails to decode would silently vanish from the user's config) and the preset display names that
/// the Settings UI relies on must stay stable.
final class RemapActionTests: XCTestCase {

    private func roundTrip(_ action: RemapAction) throws -> RemapAction {
        let data = try JSONEncoder().encode(action)
        return try JSONDecoder().decode(RemapAction.self, from: data)
    }

    func testKeyStrokeRoundTrip() throws {
        let action = RemapAction.keyStroke(keyCode: 0x09, control: false, option: false,
                                           command: true, shift: true) // ⌘⇧V
        XCTAssertEqual(try roundTrip(action), action)
    }

    func testPresetsRoundTrip() throws {
        for preset in RemapAction.presets {
            XCTAssertEqual(try roundTrip(preset), preset, "preset failed round-trip: \(preset)")
        }
    }

    func testLaunchpadRoundTrip() throws {
        XCTAssertEqual(try roundTrip(.launchpad), .launchpad)
    }

    func testMediaKeyRoundTrip() throws {
        XCTAssertEqual(try roundTrip(.mediaKey(.playPause)), .mediaKey(.playPause))
    }

    func testSpacePresetDisplayNames() {
        XCTAssertEqual(RemapAction.spaceLeft.displayName, "Move Left a Space")
        XCTAssertEqual(RemapAction.spaceRight.displayName, "Move Right a Space")
        XCTAssertEqual(RemapAction.missionControl.displayName, "Mission Control")
        XCTAssertEqual(RemapAction.appExpose.displayName, "App Exposé")
        XCTAssertEqual(RemapAction.launchpad.displayName, "Launchpad")
    }

    /// A custom combo renders modifier glyphs in a stable order (⌃⌥⇧⌘).
    func testCustomKeyStrokeDisplayShowsModifiers() {
        let action = RemapAction.keyStroke(keyCode: 0x00, control: true, option: true,
                                           command: true, shift: true)
        let name = action.displayName
        XCTAssertTrue(name.hasPrefix("⌃⌥⇧⌘"), "unexpected modifier order: \(name)")
    }

    func testPresetsAreDistinct() {
        let names = RemapAction.presets.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "preset display names must be unique")
    }
}
