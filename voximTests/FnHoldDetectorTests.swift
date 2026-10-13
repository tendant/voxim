//
//  FnHoldDetectorTests.swift
//  voximTests
//

import CoreGraphics
import Testing
@testable import voxim

struct FnHoldDetectorTests {
    let fn: CGEventFlags = .maskSecondaryFn

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
        #expect(d.handle(.flagsChanged([])) == .disarm)
        // A late timer from the tap must not start recording.
        #expect(d.handle(.holdElapsed) == nil)
        #expect(!d.isActive)
    }

    @Test func fnAsModifierForAnotherKeyNeverStarts() {
        var d = FnHoldDetector()
        #expect(d.handle(.flagsChanged(fn)) == .arm)
        #expect(d.handle(.keyDown) == .disarm)            // e.g. fn+← (Home)
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
        #expect(d.handle(.keyDown) == nil)
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
}
