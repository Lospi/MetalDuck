//
//  AppStateTests.swift
//  MetalDuckTests
//
//  Tests the capture lifecycle state without starting ScreenCaptureKit.
//

import Testing
@testable import MetalDuck

@MainActor
struct AppStateTests {

    @Test("Only the first of two overlapping start requests is accepted", .tags(.capture))
    func overlappingStartsCollapse() {
        let state = AppState()

        #expect(state.beginStarting())
        #expect(!state.beginStarting(), "A second start must be refused while the first is in flight.")
        #expect(state.isStarting)
        #expect(!state.isCapturing)
    }

    @Test("A start request is refused while capturing", .tags(.capture))
    func startIsRefusedWhileCapturing() {
        let state = AppState()
        #expect(state.beginStarting())
        state.startCapture()

        #expect(state.isCapturing)
        #expect(!state.isStarting)
        #expect(!state.beginStarting())
    }

    @Test("A failed start can be retried", .tags(.capture))
    func failedStartCanBeRetried() {
        let state = AppState()
        #expect(state.beginStarting())
        state.cancelStarting()

        #expect(!state.isStarting)
        #expect(state.beginStarting())
    }

    @Test("Capture can be started again after stopping", .tags(.capture))
    func startAfterStop() {
        let state = AppState()
        #expect(state.beginStarting())
        state.startCapture()
        state.stopCapture()

        #expect(!state.isCapturing)
        #expect(state.beginStarting())
    }
}
