//
//  VideoPerformanceSummary.swift
//  MetalDuck
//

import AVFoundation
import Foundation

/// Snapshot of `AVSampleBufferVideoRenderer` presentation metrics formatted for the Debug HUD.
nonisolated struct VideoPerformanceSummary: Equatable, Sendable {
    let totalFrames: Int
    let droppedFrames: Int
    let corruptedFrames: Int
    let optimizedCompositingFrames: Int
    let totalAccumulatedFrameDelay: TimeInterval

    init(
        totalFrames: Int,
        droppedFrames: Int,
        corruptedFrames: Int,
        optimizedCompositingFrames: Int,
        totalAccumulatedFrameDelay: TimeInterval
    ) {
        self.totalFrames = max(0, totalFrames)
        self.droppedFrames = max(0, droppedFrames)
        self.corruptedFrames = max(0, corruptedFrames)
        self.optimizedCompositingFrames = max(0, optimizedCompositingFrames)
        self.totalAccumulatedFrameDelay = max(0, totalAccumulatedFrameDelay)
    }

    init(metrics: AVVideoPerformanceMetrics) {
        self.init(
            totalFrames: metrics.totalNumberOfFrames,
            droppedFrames: metrics.numberOfDroppedFrames,
            corruptedFrames: metrics.numberOfCorruptedFrames,
            optimizedCompositingFrames: metrics.numberOfFramesDisplayedUsingOptimizedCompositing,
            totalAccumulatedFrameDelay: metrics.totalAccumulatedFrameDelay
        )
    }

    var displayedFrames: Int {
        max(0, totalFrames - droppedFrames)
    }

    /// Average display deadline delay in milliseconds across displayed frames.
    var averageFrameDelayMilliseconds: Double? {
        guard displayedFrames > 0 else { return nil }
        return (totalAccumulatedFrameDelay / Double(displayedFrames)) * 1000.0
    }

    /// Percentage (0...100) of displayed frames composited on the optimized path.
    var optimizedCompositingPercentage: Int? {
        guard displayedFrames > 0 else { return nil }
        let ratio = min(1.0, max(0.0, Double(optimizedCompositingFrames) / Double(displayedFrames)))
        return Int((ratio * 100.0).rounded())
    }

    var hudLine: String {
        guard totalFrames > 0 else {
            return " Render: waiting for metrics "
        }

        var parts = ["\(droppedFrames) drop"]
        if let delayMs = averageFrameDelayMilliseconds {
            parts.append(String(format: "%.1fms delay", delayMs))
        }
        if let optimizedPct = optimizedCompositingPercentage {
            parts.append("\(optimizedPct)% opt")
        }
        if corruptedFrames > 0 {
            parts.append("\(corruptedFrames) corrupt")
        }
        return " Render: \(parts.joined(separator: " · ")) "
    }
}
