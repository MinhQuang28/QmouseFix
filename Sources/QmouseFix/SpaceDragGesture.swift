import QuartzCore

/// Hold a mouse button and drag to drive Spaces/Mission Control like the trackpad gesture:
///   • horizontal drag → switch Spaces (one jump per `threshold` px, paced by a cooldown)
///   • vertical drag   → up = Mission Control, down = App Exposé
/// The active axis is locked at the start of each drag so a swipe never does both.
///
/// Click-vs-drag: the same button can ALSO carry a normal remap. A quick click (no real drag) is
/// reported back to the engine so it fires the button's mapped action; a click-and-drag does the
/// gesture instead. So one button can be e.g. Mission Control on click, switch Spaces on drag.
///
/// Switching is driven through the Symbolic-HotKey SPI (`SystemActions`), so it works even if the
/// user disabled the system Space-switch keyboard shortcut. macOS 26+ blocks synthetic dock-swipe
/// gestures in WindowServer, so discrete jumps (not follow-finger) are the supported behaviour —
/// the same conclusion Mac Mouse Fix reached. A fast flick on release fires one extra jump for the
/// momentum feel of the real gesture.
///
/// State here is touched only on the event-tap thread; the public knobs are set from the same
/// thread at the top of each callback, so no locking is needed.
final class SpaceDragGesture {

    var button = 0          // 0 = disabled, else the 1-based button that triggers the gesture
    var threshold = 200.0   // pixels of horizontal drag per Space switch
    var reverse = false     // flip which horizontal direction maps to which Space

    private let deadzone = 6.0           // px of movement before a press counts as a drag (not a click)
    private let hCooldown = 0.30         // s between Space switches — roughly the slide-animation duration
    private let vThreshold = 150.0       // px of vertical drag to fire Mission Control / App Exposé
    private let vCooldown = 0.40         // s between vertical triggers, so a held drag doesn't re-toggle

    // Flick-on-release: a fast release still fires one jump even below the distance threshold.
    private let flickMinDistance = 50.0  // px accumulated since the last switch
    private let flickMinVelocity = 600.0 // px/s at release
    private let flickMaxIdle = 0.08      // s — if the pointer rested longer than this, it's not a flick

    private enum Axis { case undecided, horizontal, vertical }

    private var down = false
    private var dragged = false
    private var axis = Axis.undecided
    private var accX = 0.0
    private var accY = 0.0
    private var lastHSwitch = 0.0
    private var lastVTrigger = 0.0
    private var smoothedVel = 0.0        // EMA of drag speed along the active axis (px/s)
    private var lastDragTime = 0.0

    var isActive: Bool { down }

    /// Begin tracking a press of the gesture button. Returns true if this button is ours (caller
    /// should then swallow the button-down).
    func handleButtonDown(_ buttonNumber: Int) -> Bool {
        guard button != 0, buttonNumber == button else { return false }
        down = true
        dragged = false
        axis = .undecided
        accX = 0; accY = 0
        smoothedVel = 0
        return true
    }

    /// End tracking. `consumed` = this was our button (swallow the up). `wasClick` = it was a plain
    /// click with no drag, so the engine should fire the button's normal remap action.
    func handleButtonUp(_ buttonNumber: Int) -> (consumed: Bool, wasClick: Bool) {
        guard down, buttonNumber == button else { return (false, false) }
        if dragged { flickOnRelease() }
        let wasClick = !dragged
        down = false
        return (true, wasClick)
    }

    /// Returns true if a drag was consumed (the gesture button is held).
    func handleDrag(deltaX: Double, deltaY: Double) -> Bool {
        guard down else { return false }
        let now = CACurrentMediaTime()

        // Wait for real movement before treating this as a drag (so a click with tiny jitter still
        // counts as a click), then lock onto the axis that moved most.
        if !dragged {
            accX += deltaX; accY += deltaY
            if max(abs(accX), abs(accY)) >= deadzone {
                dragged = true
                axis = abs(accX) >= abs(accY) ? .horizontal : .vertical
                accX = 0; accY = 0
                lastDragTime = now
            }
            return true
        }

        // Track drag velocity (EMA) along the active axis for flick detection on release.
        let dt = now - lastDragTime
        lastDragTime = now
        let axisDelta = axis == .horizontal ? deltaX : deltaY
        if dt > 0, dt < 0.5 { smoothedVel = 0.7 * smoothedVel + 0.3 * (axisDelta / dt) }

        if axis == .horizontal {
            if now - lastHSwitch < hCooldown {
                accX = 0 // discard motion during the cooldown so one hard swipe = exactly one Space
            } else {
                accX += deltaX
                if abs(accX) >= threshold {
                    switchSpace(left: (accX < 0) != reverse)
                    accX = 0
                    lastHSwitch = now
                }
            }
        } else {
            accY += deltaY
            if now - lastVTrigger >= vCooldown, abs(accY) >= vThreshold {
                triggerVertical(up: accY < 0)
                accY = 0
                lastVTrigger = now
            }
        }
        return true
    }

    private func flickOnRelease() {
        let now = CACurrentMediaTime()
        // If the pointer rested before release, `smoothedVel` still holds the last movement's speed
        // (no events arrive while resting), so the idle check stops a drag-pause-release false flick.
        guard now - lastDragTime <= flickMaxIdle else { return }
        let acc = axis == .horizontal ? accX : accY
        guard abs(acc) >= flickMinDistance,
              abs(smoothedVel) >= flickMinVelocity,
              (smoothedVel > 0) == (acc > 0) else { return } // still moving in the accumulated direction

        if axis == .horizontal {
            if now - lastHSwitch >= hCooldown { // a threshold-switch just fired — don't double up
                switchSpace(left: (acc < 0) != reverse)
                lastHSwitch = now
            }
        } else if now - lastVTrigger >= vCooldown {
            triggerVertical(up: acc < 0)
            lastVTrigger = now
        }
    }

    private func switchSpace(left: Bool) {
        (left ? SystemActions.spaceLeft : SystemActions.spaceRight)()
    }

    private func triggerVertical(up: Bool) {
        (up ? SystemActions.missionControl : SystemActions.appExpose)()
    }
}
