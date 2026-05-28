//
//  FrameRateEstimator.swift
//  MetalDuck
//
//  Estimates a captured window's presented update rate from changed frame timing.
//

import Foundation

struct FrameRateEstimator {
    static let supportedFrameRates = [30, 40, 45, 50, 60, 72, 90, 100, 120]

    private let windowDuration: TimeInterval
    private let stabilityDuration: TimeInterval
    private let cooldownDuration: TimeInterval
    private let minimumChangedAreaRatio: Double
    private var changedFrameTimestamps: [TimeInterval] = []
    private var candidateFrameRate: Int?
    private var candidateStartTime: TimeInterval?
    private var lastRecommendationTime: TimeInterval?

    private(set) var currentFrameRate: Int
    private(set) var estimatedFrameRate: Int?

    init(
        initialFrameRate: Int = 60,
        windowDuration: TimeInterval = 2.5,
        stabilityDuration: TimeInterval = 2.0,
        cooldownDuration: TimeInterval = 5.0,
        minimumChangedAreaRatio: Double = 0.001
    ) {
        self.currentFrameRate = Self.quantizedFrameRate(for: Double(initialFrameRate))
        self.windowDuration = windowDuration
        self.stabilityDuration = stabilityDuration
        self.cooldownDuration = cooldownDuration
        self.minimumChangedAreaRatio = minimumChangedAreaRatio
    }

    mutating func reset(initialFrameRate: Int) {
        changedFrameTimestamps.removeAll(keepingCapacity: true)
        candidateFrameRate = nil
        candidateStartTime = nil
        lastRecommendationTime = nil
        estimatedFrameRate = nil
        currentFrameRate = Self.quantizedFrameRate(for: Double(initialFrameRate))
    }

    mutating func observe(timestamp: TimeInterval, changedAreaRatio: Double?) -> Int? {
        guard timestamp.isFinite else { return nil }

        trimSamples(olderThan: timestamp - windowDuration)

        guard frameHasMeaningfulChanges(changedAreaRatio) else {
            return nil
        }

        if let last = changedFrameTimestamps.last, timestamp <= last {
            return nil
        }

        changedFrameTimestamps.append(timestamp)
        trimSamples(olderThan: timestamp - windowDuration)

        guard let estimate = estimateFrameRate() else {
            return nil
        }

        estimatedFrameRate = estimate

        if candidateFrameRate != estimate {
            candidateFrameRate = estimate
            candidateStartTime = timestamp
            return nil
        }

        guard let candidateStartTime,
              timestamp - candidateStartTime >= stabilityDuration,
              estimate != currentFrameRate
        else {
            return nil
        }

        if let lastRecommendationTime,
           timestamp - lastRecommendationTime < cooldownDuration {
            return nil
        }

        currentFrameRate = estimate
        lastRecommendationTime = timestamp
        return estimate
    }

    static func quantizedFrameRate(for measuredFrameRate: Double) -> Int {
        guard measuredFrameRate.isFinite else {
            return supportedFrameRates.first ?? 30
        }

        if measuredFrameRate <= Double(supportedFrameRates[0]) {
            return supportedFrameRates[0]
        }

        if measuredFrameRate >= Double(supportedFrameRates[supportedFrameRates.count - 1]) {
            return supportedFrameRates[supportedFrameRates.count - 1]
        }

        return supportedFrameRates.min { first, second in
            abs(Double(first) - measuredFrameRate) < abs(Double(second) - measuredFrameRate)
        } ?? supportedFrameRates[0]
    }

    private func frameHasMeaningfulChanges(_ changedAreaRatio: Double?) -> Bool {
        guard let changedAreaRatio else {
            return true
        }
        return changedAreaRatio >= minimumChangedAreaRatio
    }

    private func estimateFrameRate() -> Int? {
        guard let first = changedFrameTimestamps.first,
              let last = changedFrameTimestamps.last,
              changedFrameTimestamps.count >= 2
        else {
            return nil
        }

        let duration = last - first
        guard duration >= 1.0 else {
            return nil
        }

        let measuredFrameRate = Double(changedFrameTimestamps.count - 1) / duration
        return Self.quantizedFrameRate(for: measuredFrameRate)
    }

    private mutating func trimSamples(olderThan cutoff: TimeInterval) {
        changedFrameTimestamps.removeAll { $0 < cutoff }
    }
}
