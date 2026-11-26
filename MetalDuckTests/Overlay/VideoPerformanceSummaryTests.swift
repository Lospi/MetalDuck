//
//  VideoPerformanceSummaryTests.swift
//  MetalDuckTests
//

import Testing
@testable import MetalDuck

struct VideoPerformanceSummaryTests {
    @Test("Waiting state is shown when no frames have been counted", .tags(.timing))
    func zeroFramesShowsWaiting() {
        let summary = VideoPerformanceSummary(
            totalFrames: 0,
            droppedFrames: 0,
            corruptedFrames: 0,
            optimizedCompositingFrames: 0,
            totalAccumulatedFrameDelay: 0
        )

        #expect(summary.displayedFrames == 0)
        #expect(summary.averageFrameDelayMilliseconds == nil)
        #expect(summary.optimizedCompositingPercentage == nil)
        #expect(summary.hudLine == " Render: waiting for metrics ")
    }

    @Test("Formats dropped frames, average delay, and optimized compositing percentage", .tags(.timing))
    func normalMetricsFormatting() {
        let summary = VideoPerformanceSummary(
            totalFrames: 600,
            droppedFrames: 3,
            corruptedFrames: 0,
            optimizedCompositingFrames: 580,
            totalAccumulatedFrameDelay: 0.2985 // 0.5 ms across 597 displayed frames
        )

        #expect(summary.displayedFrames == 597)
        #expect(summary.optimizedCompositingPercentage == 97)
        #expect(summary.hudLine == " Render: 3 drop · 0.5ms delay · 97% opt ")
    }

    @Test("Includes corrupted frame count only when non-zero", .tags(.timing))
    func corruptedFramesShownWhenPresent() {
        let summary = VideoPerformanceSummary(
            totalFrames: 100,
            droppedFrames: 0,
            corruptedFrames: 2,
            optimizedCompositingFrames: 100,
            totalAccumulatedFrameDelay: 0.1
        )

        #expect(summary.hudLine == " Render: 0 drop · 1.0ms delay · 100% opt · 2 corrupt ")
    }

    @Test("Handles all frames dropped without division by zero", .tags(.timing))
    func allFramesDropped() {
        let summary = VideoPerformanceSummary(
            totalFrames: 10,
            droppedFrames: 10,
            corruptedFrames: 0,
            optimizedCompositingFrames: 0,
            totalAccumulatedFrameDelay: 0.5
        )

        #expect(summary.displayedFrames == 0)
        #expect(summary.averageFrameDelayMilliseconds == nil)
        #expect(summary.optimizedCompositingPercentage == nil)
        #expect(summary.hudLine == " Render: 10 drop ")
    }

    @Test("Clamps out-of-range optimized counts and negative inputs safely", .tags(.timing))
    func clampsInvalidCounts() {
        let summary = VideoPerformanceSummary(
            totalFrames: 10,
            droppedFrames: -2,
            corruptedFrames: -1,
            optimizedCompositingFrames: 15,
            totalAccumulatedFrameDelay: -0.5
        )

        #expect(summary.droppedFrames == 0)
        #expect(summary.corruptedFrames == 0)
        #expect(summary.optimizedCompositingPercentage == 100)
        #expect(summary.averageFrameDelayMilliseconds == 0)
    }
}
