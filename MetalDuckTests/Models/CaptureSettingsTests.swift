//
//  CaptureSettingsTests.swift
//  MetalDuckTests
//
//  Tests deterministic capture settings behavior without starting ScreenCaptureKit.
//

import CoreMedia
import Testing
@testable import MetalDuck

struct CaptureSettingsTests {

    @Test("Capture settings default to manual 60 FPS", .tags(.settings))
    func defaultsToManualSixtyFPS() {
        let settings = CaptureSettings()

        #expect(settings.autoFrameRateEnabled == false, "Auto capture FPS should be opt-in.")
        #expect(settings.frameRate == 60, "Manual capture should remain 60 FPS by default.")
    }

    @Test("Frame interval uses the configured frame rate", .tags(.settings))
    func frameIntervalUsesConfiguredFrameRate() {
        let interval = CaptureSettings.frameInterval(for: 60)

        #expect(interval.value == 1)
        #expect(interval.timescale == 60)
    }

    @Test(
        "Invalid frame rates clamp to a one-second interval",
        .tags(.settings),
        arguments: [-120, 0, 1]
    )
    func invalidFrameRatesClampToOneFPS(frameRate: Int) {
        let interval = CaptureSettings.frameInterval(for: frameRate)

        #expect(interval.value == 1)
        #expect(interval.timescale == 1)
    }

    @Test("Auto capture sampling ceiling is 120 FPS", .tags(.settings))
    func autoSamplingCeilingIsOneTwentyFPS() {
        #expect(CaptureSettings.autoFrameRateSamplingCeiling == 120)
    }
}
