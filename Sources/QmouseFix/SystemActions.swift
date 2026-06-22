import CoreGraphics
import Foundation

/// Drives WindowServer/Dock features that ignore synthetic key events on recent macOS.
///
/// Two private mechanisms, both resolved at runtime via `dlsym` (no link-time dependency):
///   • `CoreDockSendNotification` — Mission Control / Exposé / Show Desktop (Dock SPI).
///   • CoreGraphics Symbolic-HotKey (SHK) API — switching Spaces.
///
/// Switching Spaces: we READ which key the user has bound to the Space-switch hotkey (read-only) and
/// synthesize exactly that key, so it works even if they remapped it. If the binding can't be read or
/// is disabled, we fall back to the macOS default (Ctrl+←/→). We deliberately NEVER write the SHK
/// configuration — this only ever adds mouse-driven input, it does not modify any system setting.
enum SystemActions {

    // MARK: - Dock notifications (Mission Control / Exposé / Show Desktop)

    private typealias SendFn = @convention(c) (CFString, Int32) -> Void

    private static let send: SendFn? = {
        // RTLD_DEFAULT (-2): search every already-loaded image for the symbol.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification")
        else { return nil }
        return unsafeBitCast(sym, to: SendFn.self)
    }()

    static var isAvailable: Bool { send != nil }

    /// Toggle Mission Control (overview of all windows/spaces).
    static func missionControl() { fire("com.apple.expose.awake") }
    /// Toggle App Exposé (windows of the front app).
    static func appExpose() { fire("com.apple.expose.front.awake") }
    /// Toggle Show Desktop.
    static func showDesktop() { fire("com.apple.showdesktop.awake") }

    private static func fire(_ name: String) {
        DispatchQueue.main.async { send?(name as CFString, 0) }
    }

    // MARK: - Symbolic hotkeys (switch Spaces)

    /// Switch to the Space on the left / right.
    static func spaceLeft()  { postSHK(shkSpaceLeft,  defaultVKC: 0x7B) } // ← left arrow
    static func spaceRight() { postSHK(shkSpaceRight, defaultVKC: 0x7C) } // → right arrow

    private static let shkSpaceLeft:  Int32 = 79
    private static let shkSpaceRight: Int32 = 81

    private static let kNullKeyEquivalent: UInt16 = 0xFFFF
    private static let kControlMask: UInt32 = 1 << 18 // kCGSControlKeyMask == CGEventFlags.maskControl

    // Runs SHK reads and the synthesized key off the event-tap thread.
    private static let queue = DispatchQueue(label: "com.qmousefix.shk", qos: .userInteractive)

    private typealias GetSHKFn    = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias IsEnabledFn = @convention(c) (Int32) -> Bool

    private static func lookup<T>(_ name: String, as: T.Type) -> T? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
    private static let getSHK    = lookup("CGSGetSymbolicHotKeyValue", as: GetSHKFn.self)
    private static let isEnabled = lookup("CGSIsSymbolicHotKeyEnabled", as: IsEnabledFn.self)

    /// Trigger a Space-switch hotkey by synthesizing the key it's bound to (read-only lookup). Falls
    /// back to the macOS default Ctrl+arrow if the binding can't be read or is disabled. Never writes
    /// any system configuration — a harmless no-op at worst if the user disabled the shortcut entirely.
    private static func postSHK(_ shk: Int32, defaultVKC: UInt16) {
        queue.async {
            var keq: UInt16 = 0, vkc: UInt16 = 0, mods: UInt32 = 0
            if let getSHK, let isEnabled,
               getSHK(shk, &keq, &vkc, &mods) == 0, isEnabled(shk),
               keq == kNullKeyEquivalent, vkc != kNullKeyEquivalent {
                // The hotkey resolves by virtual key code — replay exactly what the user has bound.
                postKey(vkc, mods)
            } else {
                postKey(defaultVKC, kControlMask)
            }
        }
    }

    private static func postKey(_ vkc: UInt16, _ mods: UInt32) {
        let src = CGEventSource(stateID: .privateState)
        let loc = CGEventTapLocation.cgSessionEventTap // SHKs are observed at the session tap
        let flags = CGEventFlags(rawValue: UInt64(mods))
        if let down = CGEvent(keyboardEventSource: src, virtualKey: vkc, keyDown: true) {
            down.flags = flags; down.post(tap: loc)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: vkc, keyDown: false) {
            up.flags = flags; up.post(tap: loc)
        }
    }
}
