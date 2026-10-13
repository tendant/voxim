//
//  ModelStatusTests.swift
//  voximTests
//

import Testing
@testable import voxim

@MainActor
struct ModelStatusTests {
    @Test func lateProgressDoesNotOverrideReady() {
        let status = ModelStatus()
        status.update(.downloading(fraction: 0.5))
        status.update(.ready)
        status.update(.downloading(fraction: 1))
        #expect(status.state == .ready)
    }

    @Test func progressAdvancesBeforeReady() {
        let status = ModelStatus()
        status.update(.downloading(fraction: 0.2))
        status.update(.compiling)
        #expect(status.state == .compiling)
    }
}
