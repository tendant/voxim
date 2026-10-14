//
//  FnHoldDetectorTests.swift
//  voximTests
//

import CoreGraphics
import Testing
@testable import voxim

struct FnHoldDetectorTests {
    let fn: CGEventFlags = .maskSecondaryFn
    let leftArrow: Int64 = 123
    let esc = FnHoldDetector.escapeKey

    @Test func longHoldStartsAndReleaseStops() {
        var d = FnHoldDetector()
        #expect(d.handle(.flagsChanged(fn)) == .arm)
        #expect(d.handle(.holdElapsed) == .press)
        #expect(d.isActive)
        #expect(d.handle(.flagsChanged([])) == .release)
        #expect(!d.isActive)
    }

    @Test func shortTapDoesNothing() {
        var d = FnHoldDetector()
        #expect(d.handle(.flagsChanged(fn)) == .arm)
        #expect(d.handle(.flagsChanged([])) == .tap)
        // A late timer from the tap must not start recording.
        #expect(d.handle(.holdElapsed) == nil)
        #expect(!d.isActive)
    }

    @Test func fnAsModifierForAnotherKeyNeverStarts() {
        var d = FnHoldDetector()
        #expect(d.handle(.flagsChanged(fn)) == .arm)
        #expect(d.handle(.keyDown(keyCode: leftArrow)) == .disarm)  // fn+← (Home)
        #expect(d.handle(.holdElapsed) == nil)
        #expect(d.handle(.flagsChanged([])) == nil)
        // Next clean hold works again.
        #expect(d.handle(.flagsChanged(fn)) == .arm)
        #expect(d.handle(.holdElapsed) == .press)
    }

    @Test(arguments: [CGEventFlags.maskCommand, .maskControl, .maskAlternate, .maskShift])
    func fnWithOtherModifierNeverStarts(modifier: CGEventFlags) {
        // Other modifier first, then fn.
        var a = FnHoldDetector()
        #expect(a.handle(.flagsChanged([modifier, fn])) == nil)
        #expect(a.handle(.holdElapsed) == nil)

        // fn first, then another modifier joins before the threshold.
        var b = FnHoldDetector()
        #expect(b.handle(.flagsChanged(fn)) == .arm)
        #expect(b.handle(.flagsChanged([fn, modifier])) == .disarm)
        #expect(b.handle(.holdElapsed) == nil)
    }

    @Test func keysAndModifiersWhileRecordingDontStopIt() {
        var d = FnHoldDetector()
        _ = d.handle(.flagsChanged(fn))
        _ = d.handle(.holdElapsed)
        #expect(d.handle(.keyDown(keyCode: leftArrow)) == nil)
        #expect(d.handle(.flagsChanged([fn, .maskShift])) == nil)
        #expect(d.isActive)
        #expect(d.handle(.flagsChanged(.maskShift)) == .release)
    }

    @Test func resetEndsWhateverIsInFlight() {
        var idle = FnHoldDetector()
        #expect(idle.reset() == nil)

        var armed = FnHoldDetector()
        _ = armed.handle(.flagsChanged(fn))
        #expect(armed.reset() == .disarm)

        var active = FnHoldDetector()
        _ = active.handle(.flagsChanged(fn))
        _ = active.handle(.holdElapsed)
        #expect(active.reset() == .release)
        #expect(!active.isActive)
    }

    @Test func escCancelsRecordingAndFnReleaseDoesNothingAfter() {
        var d = FnHoldDetector()
        _ = d.handle(.flagsChanged(fn))
        _ = d.handle(.holdElapsed)
        #expect(d.handle(.keyDown(keyCode: esc)) == .cancel)
        #expect(!d.isActive)
        #expect(d.handle(.flagsChanged([])) == nil)
        // Next hold starts normally.
        #expect(d.handle(.flagsChanged(fn)) == .arm)
    }

    @Test func escOutsideRecordingIsLeftAlone() {
        var d = FnHoldDetector()
        #expect(d.handle(.keyDown(keyCode: esc)) == nil)
        _ = d.handle(.flagsChanged(fn))
        // fn+esc before the threshold is a normal key combo, not a cancel.
        #expect(d.handle(.keyDown(keyCode: esc)) == .disarm)
    }

    @Test func escCancelsInHandsFreeWithoutFnHeld() {
        var d = FnHoldDetector()
        #expect(d.handle(.keyDown(keyCode: esc)) == nil)
        d.handsFree = true
        #expect(d.handle(.keyDown(keyCode: esc)) == .cancel)
        #expect(d.handle(.keyDown(keyCode: leftArrow)) == nil)
    }
}

struct DoubleTapDetectorTests {
    /// Registers taps at the given times; returns which ones completed a double-tap.
    private func taps(_ times: [Double], resetAfterFirst: Bool = false) -> [Bool] {
        var detector = DoubleTapDetector()
        var results: [Bool] = []
        for (index, time) in times.enumerated() {
            results.append(detector.registerTap(at: time))
            if resetAfterFirst && index == 0 { detector.reset() }
        }
        return results
    }

    @Test func twoQuickTapsMakeADoubleTap() {
        #expect(taps([10.0, 10.3]) == [false, true])
    }

    @Test func slowTapsDoNot() {
        // The second slow tap starts a new pair with the third.
        #expect(taps([10.0, 10.6, 10.9]) == [false, false, true])
    }

    @Test func aTripleTapIsOneDoubleTapThenAFreshStart() {
        #expect(taps([1.0, 1.2, 1.4]) == [false, true, false])
    }

    @Test func resetForgetsAPendingTap() {
        #expect(taps([1.0, 1.2], resetAfterFirst: true) == [false, false])
    }
}
