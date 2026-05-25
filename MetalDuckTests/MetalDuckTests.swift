//
//  MetalDuckTests.swift
//  MetalDuckTests
//
//  Created by Roberto Camargo on 07/11/25.
//

import Testing
@testable import MetalDuck

struct MetalDuckTests {

    @Test func targetFrameRateUsesInterpolationMultiplier() {
        var settings = UpscaleSettings()
        settings.interpolationMultiplier = 3

        #expect(settings.targetFrameRate(sourceFrameRate: 30) == 90)
    }

    @Test func targetFrameRateUsesTwoTimesCadenceWhenSpatialUpscaleIsEnabled() {
        var settings = UpscaleSettings()
        settings.interpolationMultiplier = 4
        settings.spatialUpscaleEnabled = true

        #expect(settings.targetFrameRate(sourceFrameRate: 30) == 60)
    }

}
