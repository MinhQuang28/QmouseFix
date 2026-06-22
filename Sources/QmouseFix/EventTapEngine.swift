import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

/// Owns the CGEventTap that intercepts mouse buttons and scroll, running on a dedicated
/// high-priority thread (never the main thread — a stalled main thread would time out the tap).
final class EventTapEngine {

    static let shared = EventTapEngine()
    private init() {}

    private var tap: CFMachPort?
    private var thread: Thread?
    private var watchdog: Timer?
    private var hidManager: IOHIDManager?

    // Snapshot read by the tap callback thread; guarded by `lock`.
    private let lock = NSLock()
    private var enabled = true
    private var reverseScroll = false
    private var scrollMode: ScrollMode = .smooth
    private var scrollSpeed = 0.5
    private var scrollLines = 3
    private var smoothHighRes = false
    private var spaceDragButton = 0
    private var spaceDragThreshold = 200.0
    private var spaceDragReverse = false
    private var captureMode = false
    private var mappingsByButton: [Int: RemapAction] = [:]

    /// Source for the fresh wheel events we post to reverse Standard-mode scrolling (see below).
    private let scrollSource = CGEventSource(stateID: .hidSystemState)

    /// Smooth scrolling + drag-to-switch-Spaces; only ever touched on the tap thread.
    private let scrollAnimator = ScrollAnimator()
    private let spaceDrag = SpaceDragGesture()

    /// Start the tap thread (idempotent). Apply `config`.
    func start(config: AppConfig) {
        reload(config)
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "com.qmousefix.event-tap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()

        // macOS often disables the tap across sleep/wake WITHOUT delivering a
        // tapDisabledByTimeout event to our callback — so the callback's re-enable never fires
        // and the whole tap (scroll + Space-drag) stays dead until relaunch. Proactively re-enable
        // on wake, and keep a light watchdog as a safety net for silent disables.
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(self, selector: #selector(handleWake),
                             name: NSWorkspace.didWakeNotification, object: nil)
        wsCenter.addObserver(self, selector: #selector(handleWake),
                             name: NSWorkspace.screensDidWakeNotification, object: nil)
        // Plugging/unplugging an external display or changing resolution invalidates the scroll
        // animator's CADisplayLink the same way sleep does — rebuild it so scroll never silently dies.
        NotificationCenter.default.addObserver(self, selector: #selector(handleWake),
                             name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // A smooth gesture that spans a Space switch (or app activation) gets orphaned and ignored by
        // the newly-focused window — close it immediately so the next scroll opens a fresh gesture.
        wsCenter.addObserver(self, selector: #selector(handleContextChange),
                             name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        wsCenter.addObserver(self, selector: #selector(handleContextChange),
                             name: NSWorkspace.didActivateApplicationNotification, object: nil)
        startWatchdog()
        startDeviceMonitor()
    }

    /// Space/app-focus changed — end any in-flight smooth gesture so it can't get orphaned across the
    /// boundary (harmless no-op when no gesture is active).
    @objc func handleContextChange() {
        scrollAnimator.endGestureNow()
    }

    /// A mouse (dis)connected — e.g. changing the report rate re-enumerates it on USB, which orphans
    /// an in-flight smooth gesture just like a Space switch. Re-enable the tap and end the gesture so
    /// the next scroll starts fresh.
    private func handleDeviceChange() {
        reEnableTap()
        scrollAnimator.endGestureNow()
    }

    /// Watch for mice connecting/disconnecting via IOKit. Device matching/removal notifications need no
    /// Input-Monitoring permission (we never read input values) — they just tell us when to recover.
    private func startDeviceMonitor() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            Unmanaged<EventTapEngine>.fromOpaque(context).takeUnretainedValue().handleDeviceChange()
        }
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, cb, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, cb, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let opened = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened != kIOReturnSuccess {
            // Non-fatal: device callbacks won't fire, so report-rate re-enumeration recovery is skipped
            // (Space/app-switch recovery is unaffected). Log so a silent failure is diagnosable.
            NSLog("QmouseFix: IOHIDManagerOpen failed (0x%X) — report-rate scroll recovery disabled", opened)
        }
        hidManager = mgr
    }

    /// On wake, re-enable the tap AND rebuild the scroll animator's display link, which macOS
    /// invalidates across sleep (leaving smooth scroll dead until it eventually self-heals).
    @objc func handleWake() {
        reEnableTap()
        scrollAnimator.handleWake()
    }

    /// Re-enable the tap if macOS disabled it (e.g. across sleep/wake). Safe to call from any thread
    /// and idempotent — tapEnable on an already-enabled tap is a no-op.
    @objc func reEnableTap() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("QmouseFix: event tap was disabled (sleep/wake?), re-enabled")
        }
    }

    /// Periodically poll for a silently-disabled tap. 2s is invisible to the user yet costs nothing.
    private func startWatchdog() {
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.reEnableTap() }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// While capturing in Settings, let mouse-button events pass through to the UI (so the capture
    /// field can read which button was clicked) instead of remapping/swallowing them.
    func setCaptureMode(_ on: Bool) {
        lock.lock(); captureMode = on; lock.unlock()
    }

    /// Update the live snapshot when config changes.
    func reload(_ config: AppConfig) {
        lock.lock()
        enabled = config.enabled
        reverseScroll = config.reverseScroll
        scrollMode = config.scrollMode
        scrollSpeed = config.scrollSpeed
        scrollLines = config.scrollLines
        smoothHighRes = config.smoothHighRes
        spaceDragButton = config.spaceDragButton
        spaceDragThreshold = config.spaceDragThreshold
        spaceDragReverse = config.spaceDragReverse
        mappingsByButton = Dictionary(config.mappings.map { ($0.buttonNumber, $0.action) },
                                      uniquingKeysWith: { first, _ in first })
        lock.unlock()
    }

    // MARK: - Tap thread

    private func threadMain() {
        let mask: CGEventMask =
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // tapCreate returns nil until Accessibility is granted. Retry instead of giving up, so the
        // tap comes alive the moment the user flips the toggle — no app restart needed.
        var created: CFMachPort?
        while created == nil {
            created = CGEvent.tapCreate(tap: .cghidEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: eventTapCallback,
                                        userInfo: refcon)
            if created == nil {
                NSLog("QmouseFix: event tap not created (Accessibility not granted yet?), retrying…")
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        let tap = created!
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    /// Called from the tap thread for every event of interest.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a slow/stalled tap — re-enable it (the classic event-tap gotcha).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let on = enabled
        let capturing = captureMode
        let maps = mappingsByButton
        let reverse = reverseScroll
        let mode = scrollMode
        let speed = scrollSpeed
        let lines = scrollLines
        let smoothHiRes = smoothHighRes
        spaceDrag.button = spaceDragButton
        spaceDrag.threshold = spaceDragThreshold
        spaceDrag.reverse = spaceDragReverse
        lock.unlock()

        // During capture, let button events reach the Settings UI untouched.
        if capturing {
            switch type {
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                return Unmanaged.passUnretained(event)
            default: break
            }
        }

        guard on else { return Unmanaged.passUnretained(event) }

        switch type {
        case .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
            // The Space-drag gesture owns its button: swallow the down and decide click-vs-drag
            // on release (so a plain click can still fire the button's mapped action).
            if spaceDrag.handleButtonDown(button) { return nil }
            if let action = maps[button] { action.post(); return nil }
            return Unmanaged.passUnretained(event)

        case .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
            let up = spaceDrag.handleButtonUp(button)
            if up.consumed {
                // A plain click (no drag) on the gesture button still triggers its remap.
                if up.wasClick, let action = maps[button] { action.post() }
                return nil
            }
            if maps[button] != nil { return nil } // we swallowed the down; swallow the up too
            return Unmanaged.passUnretained(event)

        case .otherMouseDragged:
            // While the gesture is active, feed it both axes and swallow the drag so the motion
            // drives Spaces/Mission Control instead of moving anything underneath.
            if spaceDrag.handleDrag(deltaX: event.getDoubleValueField(.mouseEventDeltaX),
                                    deltaY: event.getDoubleValueField(.mouseEventDeltaY)) { return nil }
            return Unmanaged.passUnretained(event)

        case .scrollWheel:
            // Let our own synthetic pixel events (from the animator) pass straight through.
            if event.getIntegerValueField(.eventSourceUserData) == ScrollAnimator.syntheticTag {
                return Unmanaged.passUnretained(event)
            }
            // Leave real trackpad gestures completely alone — they carry a scroll or momentum phase,
            // which a mouse wheel never does (high-resolution mice are "continuous" but phase-less, so
            // we must NOT gate on `isContinuous` here — that's what was skipping reverse on those mice).
            let phase = event.getIntegerValueField(scrollPhaseField)
            let momentumPhase = event.getIntegerValueField(scrollMomentumPhaseField)
            guard phase == 0, momentumPhase == 0 else { return Unmanaged.passUnretained(event) }

            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

            // High-resolution / free-spin mice (e.g. MX Master 3) report continuous pixel deltas and,
            // on free-spin, the hardware flywheel coasts on its own. The OS already renders these
            // smoothly, so running them through our momentum engine would fight the flywheel and feel
            // floaty. Instead keep them native but honor the user's Scroll-speed slider and reverse —
            // both of which otherwise never reach a continuous mouse.
            if isContinuous {
                // High-res mice with NO flywheel (e.g. Keychron M6) report continuous pixels but scroll
                // choppily because the OS adds no momentum. When the user opts in, route their pixel
                // deltas through the same ease-to-target animator that smooths the notch path. Free-spin
                // mice (MX Master 3) should leave this OFF so we don't fight their hardware flywheel.
                let animated = (mode == .smooth || mode == .smoothStep)
                if smoothHiRes, animated {
                    let dir = reverse ? -1.0 : 1.0
                    let pxV = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * dir
                    let pxH = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * dir
                    if pxV != 0 || pxH != 0 {
                        scrollAnimator.addPixels(pxV: pxV, pxH: pxH, speed: speed)
                        return nil // swallow; the animator drives the pixel scroll
                    }
                }
                applyContinuous(event, speed: speed, reverse: reverse)
                return Unmanaged.passUnretained(event)
            }

            let dir = reverse ? -1.0 : 1.0
            let lineV = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * dir
            let lineH = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * dir

            // Notched mouse: Smooth and Smooth-step both drive the animator (momentum vs crisp N-line
            // step); Standard falls through to raw passthrough below.
            let animated = (mode == .smooth || mode == .smoothStep)
            if animated, lineV != 0 || lineH != 0 {
                scrollAnimator.addTick(lineV: lineV, lineH: lineH, speed: speed,
                                       stepped: mode == .smoothStep, lines: lines)
                return nil // swallow; the animator drives the pixel scroll
            }
            if reverse {
                // macOS does NOT honor in-place delta edits on a passed-through wheel event — the
                // system re-reads the original kernel deltas, so negating the fields in place is
                // invisible (this is why reverse worked in Smooth, which posts fresh events, but not
                // in Standard). So build a FRESH reversed wheel event carrying the negated line, pixel
                // and fixed-point deltas, tag it so our tap skips it, post it, and swallow the original.
                guard let rev = CGEvent(scrollWheelEvent2Source: scrollSource, units: .line,
                                        wheelCount: 2, wheel1: Int32(lineV), wheel2: Int32(lineH),
                                        wheel3: 0) else { return Unmanaged.passUnretained(event) }
                rev.setIntegerValueField(.scrollWheelEventPointDeltaAxis1,
                    value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
                rev.setIntegerValueField(.scrollWheelEventPointDeltaAxis2,
                    value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
                rev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1,
                    value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
                rev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2,
                    value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
                rev.setIntegerValueField(.eventSourceUserData, value: ScrollAnimator.syntheticTag)
                rev.post(tap: .cghidEventTap)
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// Undocumented CGEvent scroll fields that distinguish a real trackpad gesture (which sets a scroll
/// or momentum phase) from a mouse wheel (which never does, even high-resolution "continuous" mice).
private let scrollPhaseField = CGEventField(rawValue: 99)!          // kCGScrollWheelEventScrollPhase
private let scrollMomentumPhaseField = CGEventField(rawValue: 123)! // kCGScrollWheelEventMomentumPhase

extension EventTapEngine {
    /// Scale a continuous (high-res) mouse's deltas by the Scroll-speed slider and flip them for
    /// reverse, in place. Neutral speed (0.5, the slider default) maps to gain 1.0 so the mouse keeps
    /// its native feel until the user actually moves the slider.
    fileprivate func applyContinuous(_ event: CGEvent, speed: Double, reverse: Bool) {
        let gain = (speed / 0.5) * (reverse ? -1.0 : 1.0)
        if gain == 1.0 { return } // default speed, not reversed → leave the event untouched
        scaleInt(event, .scrollWheelEventDeltaAxis1, gain)
        scaleInt(event, .scrollWheelEventDeltaAxis2, gain)
        scaleInt(event, .scrollWheelEventPointDeltaAxis1, gain)
        scaleInt(event, .scrollWheelEventPointDeltaAxis2, gain)
        // Fixed-point deltas are what AppKit actually reads for continuous scrolling.
        scaleDouble(event, .scrollWheelEventFixedPtDeltaAxis1, gain)
        scaleDouble(event, .scrollWheelEventFixedPtDeltaAxis2, gain)
    }
}

/// Scale an integer scroll field in place (rounded). Used for continuous-mouse speed/reverse.
private func scaleInt(_ event: CGEvent, _ field: CGEventField, _ factor: Double) {
    let scaled = Double(event.getIntegerValueField(field)) * factor
    event.setIntegerValueField(field, value: Int64(scaled.rounded()))
}

/// Scale a fixed-point (double) scroll field in place.
private func scaleDouble(_ event: CGEvent, _ field: CGEventField, _ factor: Double) {
    event.setDoubleValueField(field, value: event.getDoubleValueField(field) * factor)
}

/// Top-level C-compatible callback (CGEventTapCallBack). Forwards to the engine via `refcon`.
private func eventTapCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<EventTapEngine>.fromOpaque(refcon).takeUnretainedValue()
    return engine.handle(type: type, event: event)
}
