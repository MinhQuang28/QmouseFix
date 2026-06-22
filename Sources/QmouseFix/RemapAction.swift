import CoreGraphics
import AppKit

/// What a remapped mouse button does. Keystroke actions cover spaces/Mission Control and any custom
/// shortcut; media keys cover volume/playback; `launchpad` opens Launchpad. All via public APIs.
enum RemapAction: Codable, Equatable, Hashable, Sendable {
    case keyStroke(keyCode: UInt16, control: Bool, option: Bool, command: Bool, shift: Bool)
    case mediaKey(MediaKey)
    case launchpad

    // Keystroke presets (macOS default shortcuts)
    static let spaceLeft      = keyStroke(keyCode: 0x7B, control: true, option: false, command: false, shift: false) // Ctrl+←
    static let spaceRight     = keyStroke(keyCode: 0x7C, control: true, option: false, command: false, shift: false) // Ctrl+→
    static let missionControl = keyStroke(keyCode: 0x7E, control: true, option: false, command: false, shift: false) // Ctrl+↑
    static let appExpose      = keyStroke(keyCode: 0x7D, control: true, option: false, command: false, shift: false) // Ctrl+↓

    /// Actions offered in the Settings picker.
    static var presets: [RemapAction] {
        [.spaceLeft, .spaceRight, .missionControl, .appExpose, .launchpad,
         .mediaKey(.volumeDown), .mediaKey(.volumeUp), .mediaKey(.mute),
         .mediaKey(.playPause), .mediaKey(.previous), .mediaKey(.next)]
    }

    /// Serial queue so keystrokes are synthesized OFF the event-tap thread (posting from inside the
    /// tap callback is unreliable for system hotkeys and would stall the tap). A FRESH event source
    /// is made per keystroke so modifier state never accumulates/desyncs across calls — reusing one
    /// source made Space-switching flaky (it worked once, then stopped).
    private static let keyQueue = DispatchQueue(label: "com.qmousefix.keystroke", qos: .userInteractive)

    /// Perform the action.
    func post() {
        switch self {
        case let .keyStroke(code, control, option, command, shift):
            // Mission Control / App Exposé are WindowServer hotkeys that ignore synthetic key events
            // on recent macOS — drive them via the Dock SPI instead (reliable).
            if control && !option && !command && !shift {
                if code == 0x7E { SystemActions.missionControl(); return } // Ctrl+Up
                if code == 0x7D { SystemActions.appExpose();      return } // Ctrl+Down
                // Space switching: drive the symbolic hotkey directly so it works even when the
                // user disabled the "Move left/right a space" keyboard shortcut.
                if code == 0x7B { SystemActions.spaceLeft();  return }     // Ctrl+Left
                if code == 0x7C { SystemActions.spaceRight(); return }     // Ctrl+Right
            }
            // System symbolic hotkeys (Mission Control, Move-Space) only fire when WindowServer sees
            // the REAL modifier keys held WITH matching flags. Press each modifier (flag accumulated
            // on its own event), tap the key, then release — spaced by tiny delays so WindowServer
            // registers the modifier before the key. Done off the tap thread.
            var mods: [(key: CGKeyCode, flag: CGEventFlags)] = []
            if control { mods.append((0x3B, .maskControl)) }
            if shift   { mods.append((0x38, .maskShift)) }
            if option  { mods.append((0x3A, .maskAlternate)) }
            if command { mods.append((0x37, .maskCommand)) }
            let allFlags = mods.reduce(into: CGEventFlags()) { $0.insert($1.flag) }

            RemapAction.keyQueue.async {
                let src = CGEventSource(stateID: .privateState)
                let loc = CGEventTapLocation.cghidEventTap
                var acc = CGEventFlags()
                for m in mods {
                    acc.insert(m.flag)
                    let e = CGEvent(keyboardEventSource: src, virtualKey: m.key, keyDown: true)
                    e?.flags = acc; e?.post(tap: loc)
                    usleep(1500)
                }
                if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
                    down.flags = allFlags; down.post(tap: loc)
                }
                usleep(1500)
                if let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
                    up.flags = allFlags; up.post(tap: loc)
                }
                usleep(1500)
                for m in mods.reversed() {
                    acc.remove(m.flag)
                    let e = CGEvent(keyboardEventSource: src, virtualKey: m.key, keyDown: false)
                    e?.flags = acc; e?.post(tap: loc)
                    usleep(800)
                }
            }

        case let .mediaKey(key):
            key.post()

        case .launchpad:
            // Launchpad.app was removed in macOS 26+. Trigger it via its symbolic hotkey instead
            // (works where the OS still has Launchpad; harmless no-op otherwise).
            RemapAction.keyStroke(keyCode: 0x83, control: false, option: false, command: false, shift: false).post()
        }
    }

    /// Human-readable name for the UI.
    var displayName: String {
        switch self {
        case .keyStroke:
            if self == .spaceLeft      { return "Move Left a Space" }
            if self == .spaceRight     { return "Move Right a Space" }
            if self == .missionControl { return "Mission Control" }
            if self == .appExpose      { return "App Exposé" }
            guard case let .keyStroke(code, control, option, command, shift) = self else { return "—" }
            var s = ""
            if control { s += "⌃" }
            if option  { s += "⌥" }
            if shift   { s += "⇧" }
            if command { s += "⌘" }
            return s + KeyCodes.name(for: code)
        case let .mediaKey(key):
            return key.name
        case .launchpad:
            return "Launchpad"
        }
    }
}
