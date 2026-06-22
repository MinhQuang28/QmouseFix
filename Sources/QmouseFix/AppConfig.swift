import Foundation

/// How the mouse wheel scrolls.
enum ScrollMode: String, Codable, Sendable, CaseIterable {
    case standard    // OS stepped wheel — raw passthrough; each notch jumps instantly
    case smooth      // trackpad-style eased momentum
    case smoothStep  // Windows-browser style: each notch eases a fixed N-line step, no coast

    var label: String {
        switch self {
        case .standard:   return "Standard (instant)"
        case .smooth:     return "Smooth (trackpad)"
        case .smoothStep: return "Smooth-step (Windows)"
        }
    }
}

/// A single mouse-button → action mapping.
struct ButtonMapping: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var buttonNumber: Int   // 1-based: 1=left, 2=right, 3=middle, 4/5=side buttons, ...
    var action: RemapAction
}

/// The whole persisted configuration. Plain Codable value stored as JSON — no keychain,
/// no license, survives rebuilds.
struct AppConfig: Codable, Sendable {
    var enabled: Bool = true
    var reverseScroll: Bool = false
    var scrollMode: ScrollMode = .smooth
    var scrollSpeed: Double = 0.5       // 0.2 (slow) … 1.5 (fast); scales smooth-scroll momentum
    var scrollLines: Int = 3            // lines per notch in Smooth-step mode (Windows default = 3)
    var smoothHighRes: Bool = false     // also smooth high-res "continuous" mice (e.g. Keychron M6) that
                                        // lack a flywheel; keep off for MX-Master-style free-spin mice
    var spaceDragButton: Int = 0        // 0 = off; else button held to drag-switch Spaces
    var spaceDragThreshold: Double = 200 // pixels of horizontal drag per Space switch
    var spaceDragReverse: Bool = false  // flip drag direction ↔ Space direction
    var mappings: [ButtonMapping] = AppConfig.defaultMappings

    /// Sensible defaults so the app is useful on first launch.
    static let defaultMappings: [ButtonMapping] = [
        ButtonMapping(buttonNumber: 4, action: .spaceLeft),
        ButtonMapping(buttonNumber: 5, action: .spaceRight),
    ]
}

/// Tolerant decoding: missing keys fall back to defaults, so adding a new setting never throws
/// (which would wipe the user's saved config). Encoding stays synthesized.
extension AppConfig {
    enum CodingKeys: String, CodingKey {
        case enabled, reverseScroll, scrollMode, smoothScroll, scrollSpeed, scrollLines, smoothHighRes
        case spaceDragButton, spaceDragThreshold, spaceDragReverse, mappings
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled            = try c.decodeIfPresent(Bool.self,            forKey: .enabled)            ?? enabled
        reverseScroll      = try c.decodeIfPresent(Bool.self,            forKey: .reverseScroll)      ?? reverseScroll
        // Prefer scrollMode; fall back to the legacy `smoothScroll` bool if that's all we have.
        if let mode = try c.decodeIfPresent(ScrollMode.self, forKey: .scrollMode) {
            scrollMode = mode
        } else if let legacy = try c.decodeIfPresent(Bool.self, forKey: .smoothScroll) {
            scrollMode = legacy ? .smooth : .standard
        }
        scrollSpeed        = try c.decodeIfPresent(Double.self,          forKey: .scrollSpeed)        ?? scrollSpeed
        scrollLines        = try c.decodeIfPresent(Int.self,             forKey: .scrollLines)        ?? scrollLines
        smoothHighRes      = try c.decodeIfPresent(Bool.self,            forKey: .smoothHighRes)      ?? smoothHighRes
        spaceDragButton    = try c.decodeIfPresent(Int.self,             forKey: .spaceDragButton)    ?? spaceDragButton
        spaceDragThreshold = try c.decodeIfPresent(Double.self,          forKey: .spaceDragThreshold) ?? spaceDragThreshold
        spaceDragReverse   = try c.decodeIfPresent(Bool.self,            forKey: .spaceDragReverse)   ?? spaceDragReverse
        mappings           = try c.decodeIfPresent([ButtonMapping].self, forKey: .mappings)          ?? mappings
    }

    // Custom encode because `smoothScroll` is a decode-only legacy key with no backing property.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(reverseScroll, forKey: .reverseScroll)
        try c.encode(scrollMode, forKey: .scrollMode)
        try c.encode(scrollSpeed, forKey: .scrollSpeed)
        try c.encode(scrollLines, forKey: .scrollLines)
        try c.encode(smoothHighRes, forKey: .smoothHighRes)
        try c.encode(spaceDragButton, forKey: .spaceDragButton)
        try c.encode(spaceDragThreshold, forKey: .spaceDragThreshold)
        try c.encode(spaceDragReverse, forKey: .spaceDragReverse)
        try c.encode(mappings, forKey: .mappings)
    }
}
