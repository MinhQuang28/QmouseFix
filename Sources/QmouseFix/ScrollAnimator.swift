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
    private var velV = 0.0    // velocity, pixels per second
    private var velH = 0.0
    private var carryV = 0.0  // sub-pixel carry for the integer pixel field
    private var carryH = 0.0
    private var running = false
    private var lastTime = 0.0
    private var lastMotionTime = 0.0   // last frame/tick that actually moved — drives the gesture hold
    private var phaseStarted = false   // whether the current glide has emitted its "began" event yet
    private let gestureHold = 0.18     // s to keep the gesture (and link) alive after velocity dies, so
                                       // consecutive ticks continue ONE gesture instead of thrashing
                                       // ended→began each notch (the cause of the hitchy feel)
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

    // Momentum tuning. ("Light / near-1:1" profile: acceleration off, very short coast — each notch
    // moves a predictable amount and the glide settles almost as soon as you stop. `baseImpulse` is
    // the headline sensitivity knob; the user's Settings "Scroll speed" scales it on top via `speed`.)
    private let baseImpulse = 420.0  // px/sec added per notch at speed 1.0, before acceleration
    private let decayPerSec = 0.006  // velocity multiplier per second → short coast (~0.2 s)
    private let maxVel = 9000.0      // px/sec clamp so fast spins don't fling absurdly far
    private let stopVel = 40.0       // px/sec; below this the glide ends (higher = stops sooner)

    // Acceleration tuning. (Disabled for this profile: accelMax 1.0 and speedupBase 1.0 mean every
    // notch contributes the same impulse, so distance scrolled is fully predictable.)
    private let tickIntervalMin = 0.015 // s — fastest natural tick gap; anything faster reads as max speed
    private let tickIntervalMax = 0.16  // s — gap beyond which ticks aren't "consecutive" (resets accel)
    private let accelMax = 1.0          // impulse multiplier at the fastest tick speed (1.0 = off)
    private let speedupAfter = 6        // consecutive ticks before the exponential speedup kicks in
    private let speedupBase = 1.0       // per-tick growth once past `speedupAfter` (1.0 = off)
    private let speedupMax = 1.0        // cap so it can't run away
    private var lastTickTime = 0.0
    private var consecutiveTicks = 0

    /// Feed a wheel tick (line deltas, already direction-corrected). `speed` scales momentum.
    func addTick(lineV: Double, lineH: Double, speed: Double) {
        let now = CACurrentMediaTime()
        let interval = now - lastTickTime
        lastTickTime = now

        // Reset the consecutive run when too long a gap passes; otherwise grow it.
        if interval > tickIntervalMax { consecutiveTicks = 0 } else { consecutiveTicks += 1 }

        // Tick-speed acceleration: map the gap (clamped) to 0 (slow) … 1 (fast), then to a multiplier.
        let clamped = min(max(interval, tickIntervalMin), tickIntervalMax)
        let fastness = (tickIntervalMax - clamped) / (tickIntervalMax - tickIntervalMin)
        let accel = 1.0 + fastness * (accelMax - 1.0)

        // Consecutive-tick speedup: exponential growth once a sustained scroll is underway.
        let extra = consecutiveTicks - speedupAfter
        let speedup = extra > 0 ? min(pow(speedupBase, Double(extra)), speedupMax) : 1.0

        let impulse = baseImpulse * speed * accel * speedup

        lock.lock()
        // Reversing direction: drop the opposing velocity so the flip is immediate, not muddy.
        if lineV != 0, (lineV > 0) != (velV > 0) { velV = 0; carryV = 0 }
        if lineH != 0, (lineH > 0) != (velH > 0) { velH = 0; carryH = 0 }
        velV = clamp(velV + lineV * impulse)
        velH = clamp(velH + lineH * impulse)
        lastMotionTime = now
        let wasIdle = !running
        if wasIdle { running = true; lastTime = now; phaseStarted = false }
        lock.unlock()

        if wasIdle { startOrWake() }
    }

    private func clamp(_ v: Double) -> Double { max(-maxVel, min(maxVel, v)) }

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
        velV = 0; velH = 0; carryV = 0; carryH = 0
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
            lock.lock(); thread = nil; running = false; velV = 0; velH = 0; lock.unlock()
            return
        }
        lock.lock(); linkRunLoop = CFRunLoopGetCurrent(); displayLink = link; lock.unlock()
        link.add(to: .current, forMode: .common)
        // A bare port keeps the run loop alive while the link is paused, so the thread survives idle.
        RunLoop.current.add(NSMachPort(), forMode: .common)
        CFRunLoopRun()
    }

    /// One display-refresh tick: decay velocity, emit the elapsed distance, pause the link when idle.
    @objc private func step(_ link: CADisplayLink) {
        lock.lock()
        let now = CACurrentMediaTime()
        let dt = min(now - lastTime, 0.05) // clamp after any stall so we don't lurch
        lastTime = now
        let decay = pow(decayPerSec, dt)   // frame-rate-independent exponential friction
        velV *= decay
        velH *= decay

        let moving = abs(velV) >= stopVel || abs(velH) >= stopVel
        var dV = 0.0, dH = 0.0
        var iV = 0.0, iH = 0.0
        if moving {
            lastMotionTime = now
            dV = velV * dt
            dH = velH * dt
            carryV += dV; iV = carryV.rounded(.towardZero); carryV -= iV
            carryH += dH; iH = carryH.rounded(.towardZero); carryH -= iH
        } else {
            velV = 0; velH = 0; carryV = 0; carryH = 0 // settle, but keep the gesture/link warm
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
