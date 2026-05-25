//
//  MetalDuckTests.swift
//  MetalDuckTests
//
//  Created by Roberto Camargo on 07/11/25.
//

import CoreMedia
import Testing
@testable import MetalDuck

struct MetalDuckTests {

    @Test("Stable changed frames resolve to the matching capture rate", arguments: [30, 60, 90, 120])
    func stableChangedFramesResolveToMatchingRate(rate: Int) {
        let initialFrameRate = rate == 120 ? 60 : 120
        var estimator = FrameRateEstimator(initialFrameRate: initialFrameRate)

        let recommendation = feed(rate: rate, seconds: 4.0, into: &estimator)

        #expect(recommendation == rate)
        #expect(estimator.currentFrameRate == rate)
        #expect(estimator.estimatedFrameRate == rate)
    }

    @Test func jitterAroundSixtyResolvesToSixty() {
        var estimator = FrameRateEstimator(initialFrameRate: 120)
        var timestamp = 0.0
        var recommendation: Int?

        for frameIndex in 0..<260 {
            let jitter = frameIndex.isMultiple(of: 2) ? 0.0015 : -0.0015
            timestamp += (1.0 / 60.0) + jitter
            recommendation = estimator.observe(
                timestamp: timestamp,
                changedAreaRatio: 1.0
            ) ?? recommendation
        }

        #expect(recommendation == 60)
        #expect(estimator.currentFrameRate == 60)
    }

    @Test func staticFramesHoldLastStableRate() {
        var estimator = FrameRateEstimator(initialFrameRate: 120)
        _ = feed(rate: 60, seconds: 4.0, into: &estimator)

        for offset in 1...300 {
            let recommendation = estimator.observe(
                timestamp: 4.0 + Double(offset) / 30.0,
                changedAreaRatio: 0
            )
            #expect(recommendation == nil)
        }

        #expect(estimator.currentFrameRate == 60)
    }

    @Test func rateChangesRequireStabilityAndCooldown() {
        var estimator = FrameRateEstimator(initialFrameRate: 120)
        _ = feed(rate: 60, seconds: 4.0, into: &estimator)

        let earlyRecommendation = feed(rate: 30, start: 4.0, seconds: 3.0, into: &estimator)
        #expect(earlyRecommendation != 30)
        #expect(estimator.currentFrameRate == 60)

        let laterRecommendation = feed(rate: 30, start: 7.0, seconds: 4.0, into: &estimator)
        #expect(laterRecommendation == 30)
        #expect(estimator.currentFrameRate == 30)
    }

    @Test func estimatesAboveOneTwentyClampToOneTwenty() {
        var estimator = FrameRateEstimator(initialFrameRate: 60)

        let recommendation = feed(rate: 144, seconds: 4.0, into: &estimator)

        #expect(recommendation == 120)
        #expect(estimator.currentFrameRate == 120)
    }

    @Test func autoFrameRateDefaultsToManualMode() {
        let settings = CaptureSettings()

        #expect(settings.autoFrameRateEnabled == false)
        #expect(settings.frameRate == 60)
    }

    @Test func manualFrameRateIntervalUsesConfiguredFrameRate() {
        let interval = CaptureSettings.frameInterval(for: 60)

        #expect(interval.value == 1)
        #expect(interval.timescale == 60)
    }

    @discardableResult
    private func feed(
        rate: Int,
        start: Double = 0,
        seconds: Double,
        into estimator: inout FrameRateEstimator,
        changedAreaRatio: Double? = 1.0
    ) -> Int? {
        var recommendation: Int?
        let frameCount = Int(Double(rate) * seconds)

        for frameIndex in 0...frameCount {
            recommendation = estimator.observe(
                timestamp: start + Double(frameIndex) / Double(rate),
                changedAreaRatio: changedAreaRatio
            ) ?? recommendation
        }

        return recommendation
    }

}
