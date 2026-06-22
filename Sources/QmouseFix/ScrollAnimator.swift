import AppKit
import CoreGraphics
import QuartzCore

/// Trackpad-like momentum scrolling with Mac-Mouse-Fix-style acceleration.
///
/// Each wheel notch adds an impulse to a velocity (pixels/second) that decays exponentially; every
/// frame emits `velocity × elapsed-time` pixels. Two accelerators shape each tick's impulse (re-derived
/// in Swift, not copied from MMF):
///   • tick-speed acceleration — faster consecutive ticks → bigger impulse.
///   • consecutive-tick speedup — a sustained scroll grows impulses exponentially after a few ticks.
/// (Both are disabled in the current "light" profile, see the tuning block.) A direction reversal
/// drops the old velocity immediately so flipping direction is crisp.
///
/// Smoothness comes from two choices that kill the judder of a naive timer loop:
///   • the glide is paced by a `CADisplayLink`, so frames land exactly on the display's refresh (no
///     `Thread.sleep` jitter, and never more events than the screen can show). When idle the link is
///     paused — zero CPU — instead of being torn down and recreated.
///   • each frame carries its precise sub-pixel delta in the fixed-point field, so slow scrolls don't
///     visibly step between whole pixels.
///
/// The link lives on its own thread+run-loop so it never competes with the event tap. Shared velocity
/// state is guarded by `lock`; `NSObject` base is only needed for the display-link target selector.
final class ScrollAnimator: NSObject {

    /// Marks our own synthetic scroll events (via `.eventSourceUserData`) so the tap skips them.
    static let syntheticTag: Int64 = 0x5132_4D46 // "Q2MF"

    private let lock = NSLock()
    private var remV = 0.0     // pixels still to emit, vertical (the running scroll target)
    private var remH = 0.0     // pixels still to emit, horizontal
    private var carryV = 0.0   // sub-pixel carry for the integer pixel field
    private var carryH = 0.0
    private var running = false
    private var lastTime = 0.0
    private var lastMotionTime = 0.0   // last frame/tick that actually moved — drives the gesture hold
    private var phaseStarted = false   // whether the current glide has emitted its "began" event yet
    private let gestureHold = 0.12     // s to keep the gesture (and link) alive after motion settles, so
                                       // consecutive notches continue ONE gesture instead of thrashing
                                       // ended→began each notch (a cause of the hitchy feel)
    private let source = CGEventSource(stateID: .hidSystemState)

    // Undocumented gesture-phase field + values. Tagging our synthetic events as a coherent gesture
    // (began → changed → ended) is what makes phase-aware apps like Safari scroll smoothly instead of
    // juddering on each discrete pixel event.
    private let scrollPhaseField = CGEventField(rawValue: 99)! // kCGScrollWheelEventScrollPhase
    private let phaseBegan: Int64 = 1
    private let phaseChanged: Int64 = 2
    private let phaseEnded: Int64 = 4

    private var displayLink: CADisplayLink?   // created/used only on the animator thread
    private var linkRunLoop: CFRunLoop?        // that thread's run loop, for cross-thread wake-ups
    private var thread: Thread?

    // Scroll tuning — a distance-accumulator (ease-to-target) model, not impulse+decay. Each notch
    // ADDS a fixed distance to the remaining target; every frame emits a fraction of what's left, so
    // the per-frame delta tapers smoothly (no per-notch pulsing) and motion stops exactly at the
    // accumulated distance (no floaty over-coast). This is what fixes the "khựng/giật + trễ" feel,
    // especially in Chromium/Electron apps (VS Code) whose own velocity tracker hated the old
    // spike-then-decay deltas.
    private let pixelsPerNotch = 70.0 // Smooth: distance one notch contributes at speed 1.0 (× `speed`)
    private let pixelsPerLine = 30.0  // Smooth-step: pixels per "line" of the fixed N-line notch step
    private var response = 0.07       // s — current ease time constant (set per tick by the mode)
    private let responseSmooth = 0.07 // floatier, trackpad-like momentum
    private let responseStep = 0.045  // crisp: settles in ~0.15 s so each notch lands as a discrete step
    private let maxRemaining = 6000.0 // px clamp so a fast spin can't accumulate an absurd target
    private let stopDistance = 0.1    // px; below this the remaining is flushed and the glide settles

    /// Feed a wheel notch (line deltas, already direction-corrected). In Smooth-step mode each notch is
    /// a fixed `lines`-line step with a crisp ease and no coast; otherwise `speed` scales a momentum glide.
    func addTick(lineV: Double, lineH: Double, speed: Double, stepped: Bool, lines: Int) {
        let now = CACurrentMediaTime()
        let dist = stepped ? Double(lines) * pixelsPerLine : pixelsPerNotch * speed

        lock.lock()
        response = stepped ? responseStep : responseSmooth
        // Reversing direction: drop the opposing remainder so the flip is immediate, not muddy.
        if lineV != 0, (lineV > 0) != (remV > 0) { remV = 0; carryV = 0 }
        if lineH != 0, (lineH > 0) != (remH > 0) { remH = 0; carryH = 0 }
        remV = clampDist(remV + lineV * dist)
        remH = clampDist(remH + lineH * dist)
        lastMotionTime = now
        let wasIdle = !running
        if wasIdle { running = true; lastTime = now; phaseStarted = false }
        lock.unlock()

        if wasIdle { startOrWake() }
    }

    /// Feed raw pixel deltas from a high-res "continuous" mouse (e.g. Keychron M6) that reports pixel
    /// motion but has no hardware flywheel, so macOS renders it choppily. Accumulating the pixels into
    /// the same ease-to-target glide smooths the bursts the way the notch path smooths wheel clicks —
    /// total distance is preserved (scaled by `speed`), just spread over the ease window.
    func addPixels(pxV: Double, pxH: Double, speed: Double) {
        let now = CACurrentMediaTime()
        let gain = speed / 0.5 // 0.5 slider default → 1.0 (native magnitude)

        lock.lock()
        response = responseSmooth
        if pxV != 0, (pxV > 0) != (remV > 0) { remV = 0; carryV = 0 }
        if pxH != 0, (pxH > 0) != (remH > 0) { remH = 0; carryH = 0 }
        remV = clampDist(remV + pxV * gain)
        remH = clampDist(remH + pxH * gain)
        lastMotionTime = now
        let wasIdle = !running
        if wasIdle { running = true; lastTime = now; phaseStarted = false }
        lock.unlock()

        if wasIdle { startOrWake() }
    }

    private func clampDist(_ v: Double) -> Double { max(-maxRemaining, min(maxRemaining, v)) }

    /// Close any in-flight glide/gesture immediately and reset, so the NEXT scroll opens a fresh
    /// `began`. A smooth gesture that spans a Space switch gets orphaned (the new Space's window never
    /// saw its `began`) and is ignored until a fresh one starts — forcing that fresh start here is the
    /// fix. `running = false` is the part that matters (next tick becomes `wasIdle`); the posted `ended`
    /// just closes the gesture cleanly in the app we were scrolling.
    func endGestureNow() {
        lock.lock()
        let rl = linkRunLoop
        let hadGesture = phaseStarted
        running = false
        phaseStarted = false
        remV = 0; remH = 0; carryV = 0; carryH = 0
        lock.unlock()

        guard hadGesture, let rl else { return } // nothing open → nothing to close
        // The block runs on the link thread (rl is the run loop `runLoop()` drives), the same thread
        // as step()/post() — so touching `post()` and `displayLink` here is single-threaded and safe.
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            self.post(intV: 0, intH: 0, preciseV: 0, preciseH: 0, phase: self.phaseEnded)
            self.displayLink?.isPaused = true
        }
        CFRunLoopWakeUp(rl)
    }

    /// Pure, frame-rate-independent ease step (extracted so it's unit-testable). Emits a fraction
    /// `1 - e^(-dt/response)` of what's left, but flushes the final sub-`stopDistance` sliver in one go
    /// so motion actually reaches the target instead of crawling asymptotically. Returns the delta to
    /// emit this frame and the remaining distance after it.
    static func advance(remaining: Double, dt: Double, response: Double,
                        stopDistance: Double) -> (delta: Double, remaining: Double) {
        if abs(remaining) < stopDistance { return (remaining, 0) }
        let delta = remaining * (1 - exp(-dt / response))
        return (delta, remaining - delta)
    }

    /// Spin up the animator thread on first use, or un-pause its display link on later glides.
    /// `thread`/`linkRunLoop` are read+written under `lock` so a failed start (see `runLoop`) can be
    /// retried by the next tick without racing.
    private func startOrWake() {
        lock.lock()
        if thread == nil {
            let t = Thread { [weak self] in self?.runLoop() }
            t.name = "com.qmousefix.scroll-animator"
            t.qualityOfService = .userInteractive
            thread = t
            lock.unlock()
            t.start()
            return
        }
        let rl = linkRunLoop
        lock.unlock()
        // Toggle `isPaused` on the link's own thread (CADisplayLink isn't documented thread-safe).
        guard let rl else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.displayLink?.isPaused = false
        }
        CFRunLoopWakeUp(rl)
    }

    /// macOS invalidates the display link across sleep/wake: the link thread stays alive but its
    /// CADisplayLink (bound to the pre-sleep display session) stops firing, so `step` never runs,
    /// `running` stays stuck true, and smooth scroll dies permanently. Tear the old link+thread down
    /// so the next tick rebuilds a fresh link bound to the current display.
    func handleWake() {
        lock.lock()
        let rl = linkRunLoop
        let link = displayLink
        displayLink = nil
        linkRunLoop = nil
        thread = nil
        running = false
        remV = 0; remH = 0; carryV = 0; carryH = 0
        phaseStarted = false
        lock.unlock()

        guard let rl else { return }
        // Invalidate the stale link and stop its run loop on its own thread (so the thread exits and
        // the next addTick spins up a clean replacement).
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) {
            link?.invalidate()
            CFRunLoopStop(rl)
        }
        CFRunLoopWakeUp(rl)
    }

    private func runLoop() {
        guard let link = NSScreen.main?.displayLink(target: self, selector: #selector(step(_:))) else {
            // No display right now (asleep / clamshell / switching). Reset so the NEXT tick retries
            // instead of leaving smooth scroll permanently dead.
            lock.lock(); thread = nil; running = false; remV = 0; remH = 0; lock.unlock()
            return
        }
        lock.lock(); linkRunLoop = CFRunLoopGetCurrent(); displayLink = link; lock.unlock()
        link.add(to: .current, forMode: .common)
        // A bare port keeps the run loop alive while the link is paused, so the thread survives idle.
        RunLoop.current.add(NSMachPort(), forMode: .common)
        CFRunLoopRun()
    }

    /// One display-refresh tick: emit a fraction of the remaining distance (smooth ease-out toward the
    /// accumulated target), then pause the link when settled.
    @objc private func step(_ link: CADisplayLink) {
        lock.lock()
        let now = CACurrentMediaTime()
        let dt = min(now - lastTime, 0.05) // clamp after any stall so we don't lurch
        lastTime = now

        // Frame-rate-independent ease: take a fraction of what's left so the per-frame delta tapers
        // smoothly. Flush the last sub-`stopDistance` sliver in one go so motion actually reaches the
        // target and stops, instead of crawling asymptotically.
        let (dV, newRemV) = ScrollAnimator.advance(remaining: remV, dt: dt, response: response, stopDistance: stopDistance)
        let (dH, newRemH) = ScrollAnimator.advance(remaining: remH, dt: dt, response: response, stopDistance: stopDistance)
        remV = newRemV
        remH = newRemH

        let moving = dV != 0 || dH != 0
        var iV = 0.0, iH = 0.0
        if moving {
            lastMotionTime = now
            carryV += dV; iV = carryV.rounded(.towardZero); carryV -= iV
            carryH += dH; iH = carryH.rounded(.towardZero); carryH -= iH
        } else {
            carryV = 0; carryH = 0 // settle, but keep the gesture/link warm
        }

        // Only truly finish once the gesture has been idle past the hold window — until then a new tick
        // can revive the SAME gesture, avoiding the ended→began churn that feels hitchy.
        let finish = !moving && (now - lastMotionTime) >= gestureHold
        let willEmit = moving
        let hadGesture = phaseStarted
        if willEmit { phaseStarted = true }
        if finish { running = false; phaseStarted = false }
        lock.unlock()

        if finish {
            // Close the gesture (only if one was opened) so the app finalizes it cleanly.
            if hadGesture { post(intV: 0, intH: 0, preciseV: 0, preciseH: 0, phase: phaseEnded) }
            link.isPaused = true // pause (not tear down) → zero CPU until the next tick
        } else if willEmit {
            post(intV: Int32(iV), intH: Int32(iH), preciseV: dV, preciseH: dH,
                 phase: hadGesture ? phaseChanged : phaseBegan)
        }
    }

    private func post(intV: Int32, intH: Int32, preciseV: Double, preciseH: Double, phase: Int64) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2, wheel1: intV, wheel2: intH, wheel3: 0) else { return }
        // Mark continuous so apps treat it as trackpad-style smooth scrolling, not a wheel notch.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Carry the exact sub-pixel delta for apps that read the fixed-point field (most modern ones),
        // so slow scrolls glide instead of stepping between whole pixels.
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: preciseV)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: preciseH)
        // Stamp the gesture phase so phase-aware apps (Safari) render a smooth gesture, not jumps.
        event.setIntegerValueField(scrollPhaseField, value: phase)
        event.setIntegerValueField(.eventSourceUserData, value: ScrollAnimator.syntheticTag)
        event.post(tap: .cghidEventTap)
    }
}
