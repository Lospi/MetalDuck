//
//  FrameRateEstimatorTests.swift
//  MetalDuckTests
//
//  Tests the pure timing policy used by Auto Capture FPS.
//

import Testing
@testable import MetalDuck

struct FrameRateEstimatorTests {

    @Test(
        "Stable changed frames resolve to the matching capture rate",
        .tags(.timing),
        arguments: [30, 60, 90, 120]
    )
    func stableChangedFramesResolveToMatchingRate(rate: Int) {
        let initialFrameRate = rate == 120 ? 60 : 120
        var estimator = FrameRateEstimator(initialFrameRate: initialFrameRate)

        let recommendation = feed(rate: rate, seconds: 4.0, into: &estimator)

        #expect(recommendation == rate)
        #expect(estimator.currentFrameRate == rate)
        #expect(estimator.estimatedFrameRate == rate)
    }

    @Test(
        "Measured frame rates quantize to supported capture rates",
        .tags(.timing),
        arguments: [
            QuantizationCase(measured: 28.0, expected: 30),
            QuantizationCase(measured: 41.0, expected: 40),
            QuantizationCase(measured: 57.5, expected: 60),
            QuantizationCase(measured: 76.0, expected: 72),
            QuantizationCase(measured: 144.0, expected: 120)
        ]
    )
    func measuredRatesQuantizeToSupportedRates(sample: QuantizationCase) {
        let quantized = FrameRateEstimator.quantizedFrameRate(for: sample.measured)

        #expect(quantized == sample.expected)
    }

    @Test("Jitter around 60 Hz still resolves to 60 FPS", .tags(.timing))
    func jitterAroundSixtyResolvesToSixty() {
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

    @Test("Static frames hold the last stable rate", .tags(.timing))
    func staticFramesHoldLastStableRate() {
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

    @Test("Rate changes require stability and cooldown", .tags(.timing))
    func rateChangesRequireStabilityAndCooldown() {
        var estimator = FrameRateEstimator(initialFrameRate: 120)
        _ = feed(rate: 60, seconds: 4.0, into: &estimator)

        let earlyRecommendation = feed(rate: 30, start: 4.0, seconds: 3.0, into: &estimator)
        #expect(earlyRecommendation != 30)
        #expect(estimator.currentFrameRate == 60)

        let laterRecommendation = feed(rate: 30, start: 7.0, seconds: 4.0, into: &estimator)
        #expect(laterRecommendation == 30)
        #expect(estimator.currentFrameRate == 30)
    }

    @Test("Non-finite timestamps are ignored", .tags(.timing))
    func nonFiniteTimestampsAreIgnored() {
        var estimator = FrameRateEstimator(initialFrameRate: 60)

        #expect(estimator.observe(timestamp: .nan, changedAreaRatio: 1.0) == nil)
        #expect(estimator.observe(timestamp: .infinity, changedAreaRatio: 1.0) == nil)
        #expect(estimator.currentFrameRate == 60)
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

struct QuantizationCase: Sendable, CustomTestStringConvertible {
    let measured: Double
    let expected: Int

    var testDescription: String {
        "\(measured) Hz -> \(expected) FPS"
    }
}
