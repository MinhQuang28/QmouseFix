import AppKit
import CoreGraphics
import Foundation

/// Owns the CGEventTap that intercepts mouse buttons and scroll, running on a dedicated
/// high-priority thread (never the main thread — a stalled main thread would time out the tap).
final class EventTapEngine {

    static let shared = EventTapEngine()
    private init() {}

    private var tap: CFMachPort?
    private var thread: Thread?
    private var watchdog: Timer?

    // Snapshot read by the tap callback thread; guarded by `lock`.
    private let lock = NSLock()
    private var enabled = true
    private var reverseScroll = false
    private var scrollMode: ScrollMode = .smooth
    private var scrollSpeed = 0.5
    private var spaceDragButton = 0
    private var spaceDragThreshold = 200.0
    private var spaceDragReverse = false
    private var captureMode = false
    private var mappingsByButton: [Int: RemapAction] = [:]

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
        startWatchdog()
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
        let smooth = (scrollMode == .smooth)
        let speed = scrollSpeed
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
            let dir = reverse ? -1.0 : 1.0
            let lineV = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * dir
            let lineH = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * dir

            // Smooth mode drives a momentum glide from notched (line-based) ticks. High-res continuous
            // mice have no line deltas, so they fall through to the reverse-in-place path below.
            if smooth, !isContinuous, lineV != 0 || lineH != 0 {
                scrollAnimator.addTick(lineV: lineV, lineH: lineH, speed: speed)
                return nil // swallow; the animator drives a smooth pixel scroll
            }
            if reverse {
                // Integer line + pixel deltas...
                negate(event, .scrollWheelEventDeltaAxis1); negate(event, .scrollWheelEventPointDeltaAxis1)
                negate(event, .scrollWheelEventDeltaAxis2); negate(event, .scrollWheelEventPointDeltaAxis2)
                // ...and the fixed-point deltas, which AppKit actually reads for scrolling.
                negateDouble(event, .scrollWheelEventFixedPtDeltaAxis1)
                negateDouble(event, .scrollWheelEventFixedPtDeltaAxis2)
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

/// Flip the sign of an integer scroll field in place (used for reverse scrolling).
private func negate(_ event: CGEvent, _ field: CGEventField) {
    event.setIntegerValueField(field, value: -event.getIntegerValueField(field))
}

/// Flip the sign of a fixed-point (double) scroll field in place.
private func negateDouble(_ event: CGEvent, _ field: CGEventField) {
    event.setDoubleValueField(field, value: -event.getDoubleValueField(field))
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
