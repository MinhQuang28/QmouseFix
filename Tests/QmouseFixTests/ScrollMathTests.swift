import XCTest
@testable import QmouseFix

/// Guards the ease-to-target scroll math (`ScrollAnimator.advance`) — the most regression-prone part,
/// since scroll feel has been re-tuned repeatedly. Verifies it converges to exactly the target
/// distance, tapers smoothly, never overshoots, and is frame-rate independent.
final class ScrollMathTests: XCTestCase {

    private let response = 0.07
    private let stopDistance = 0.1

    /// Drive `advance` to completion and return total emitted + frames taken.
    private func drain(target: Double, dt: Double) -> (total: Double, frames: Int) {
        var remaining = target
        var total = 0.0
        var frames = 0
        while remaining != 0 {
            let (delta, next) = ScrollAnimator.advance(remaining: remaining, dt: dt,
                                                       response: response, stopDistance: stopDistance)
            total += delta
            remaining = next
            frames += 1
            XCTAssertLessThan(frames, 10_000, "advance failed to converge")
        }
        return (total, frames)
    }

    func testConvergesToExactTarget() {
        let (total, _) = drain(target: 100, dt: 1.0 / 60)
        XCTAssertEqual(total, 100, accuracy: 1e-9, "must emit exactly the accumulated distance")
    }

    func testNegativeTargetConverges() {
        let (total, _) = drain(target: -250, dt: 1.0 / 60)
        XCTAssertEqual(total, -250, accuracy: 1e-9)
    }

    /// Same target, different refresh rates → same total distance (frame-rate independent ease).
    func testFrameRateIndependentTotal() {
        let at60 = drain(target: 500, dt: 1.0 / 60).total
        let at120 = drain(target: 500, dt: 1.0 / 120).total
        XCTAssertEqual(at60, at120, accuracy: 1e-6)
    }

    /// During the eased phase each frame emits a fraction of what's left, so deltas must monotonically
    /// shrink (smooth taper, no per-notch pulsing) — never grow. The final sub-`stopDistance` sliver is
    /// flushed in one frame (covered by `testSubStopDistanceFlushesImmediately`) and is exempt.
    func testDeltasTaperDownward() {
        var remaining = 1000.0
        var prev = Double.infinity
        var guardCount = 0
        while abs(remaining) >= stopDistance {
            let (delta, next) = ScrollAnimator.advance(remaining: remaining, dt: 1.0 / 60,
                                                       response: response, stopDistance: stopDistance)
            XCTAssertLessThanOrEqual(delta, prev + 1e-9, "delta grew: \(delta) > \(prev)")
            XCTAssertGreaterThan(delta, 0)
            prev = delta
            remaining = next
            guardCount += 1
            XCTAssertLessThan(guardCount, 10_000)
        }
    }

    /// No frame may emit more than what was remaining (no overshoot past the target).
    func testNeverOvershoots() {
        var remaining = 300.0
        while remaining > 0 {
            let (delta, next) = ScrollAnimator.advance(remaining: remaining, dt: 1.0 / 60,
                                                       response: response, stopDistance: stopDistance)
            XCTAssertLessThanOrEqual(delta, remaining + 1e-9)
            XCTAssertGreaterThanOrEqual(next, -1e-9)
            remaining = next
        }
    }

    /// A sub-`stopDistance` sliver is flushed in one frame so motion stops instead of crawling.
    func testSubStopDistanceFlushesImmediately() {
        let (delta, remaining) = ScrollAnimator.advance(remaining: 0.05, dt: 1.0 / 60,
                                                       response: response, stopDistance: stopDistance)
        XCTAssertEqual(delta, 0.05, accuracy: 1e-12)
        XCTAssertEqual(remaining, 0)
    }

    /// A crisper response (Smooth-step) settles in fewer frames than the floatier Smooth response.
    func testCrisperResponseSettlesFaster() {
        func frames(response: Double) -> Int {
            var remaining = 200.0, n = 0
            while remaining != 0 {
                let (_, next) = ScrollAnimator.advance(remaining: remaining, dt: 1.0 / 60,
                                                       response: response, stopDistance: stopDistance)
                remaining = next; n += 1
            }
            return n
        }
        XCTAssertLessThan(frames(response: 0.045), frames(response: 0.07))
    }
}
