//
//  UpscaleSettingsTests.swift
//  MetalDuckTests
//
//  Tests deterministic frame-rate and scale math for processing settings.
//

import CoreGraphics
import Testing
@testable import MetalDuck

struct UpscaleSettingsTests {

    @Test(
        "Target frame rate uses the interpolation multiplier",
        .tags(.settings, .upscaling),
        arguments: [
            TargetFrameRateCase(sourceFrameRate: 30, multiplier: 2, expectedTargetFrameRate: 60),
            TargetFrameRateCase(sourceFrameRate: 30, multiplier: 3, expectedTargetFrameRate: 90),
            TargetFrameRateCase(sourceFrameRate: 60, multiplier: 4, expectedTargetFrameRate: 240)
        ]
    )
    func targetFrameRateUsesInterpolationMultiplier(sample: TargetFrameRateCase) {
        var settings = UpscaleSettings()
        settings.interpolationMultiplier = sample.multiplier

        #expect(settings.targetFrameRate(sourceFrameRate: sample.sourceFrameRate) == sample.expectedTargetFrameRate)
    }

    @Test(
        "Spatial upscale fixes output cadence at 2x",
        .tags(.settings, .upscaling),
        arguments: [2, 3, 4]
    )
    func targetFrameRateUsesTwoTimesCadenceWhenSpatialUpscaleIsEnabled(multiplier: Int) {
        var settings = UpscaleSettings()
        settings.interpolationMultiplier = multiplier
        settings.spatialUpscaleEnabled = true

        #expect(settings.targetFrameRate(sourceFrameRate: 30) == 60)
    }

    @Test("Scale factor uses the smaller axis scale", .tags(.settings, .upscaling))
    func scaleFactorUsesSmallerAxisScale() {
        var settings = UpscaleSettings()
        settings.sourceResolution = CGSize(width: 1920, height: 1080)
        settings.targetResolution = CGSize(width: 3840, height: 1440)

        #expect(abs(settings.scaleFactor - Float(4.0 / 3.0)) < 0.0001)
    }
}

struct TargetFrameRateCase: Sendable, CustomTestStringConvertible {
    let sourceFrameRate: Int
    let multiplier: Int
    let expectedTargetFrameRate: Int

    var testDescription: String {
        "\(sourceFrameRate) FPS x \(multiplier) -> \(expectedTargetFrameRate) FPS"
    }
}
