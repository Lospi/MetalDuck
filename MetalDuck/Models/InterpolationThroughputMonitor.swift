import Foundation

/// Decides whether frame interpolation is too slow for the capture rate.
///
/// The OS-advertised limits only say a resolution can run, not that it runs in real time.
/// Frames are processed one at a time, so when one frame takes longer than the interval between
/// captured frames, the rest are dropped and the output ends up slower than plain passthrough.
struct InterpolationThroughputMonitor {
    /// Frames ignored after the model becomes ready, while timings settle.
    static let warmUpFrameCount = 10
    /// Frames judged together, so one slow frame does not trigger a step-down.
    static let windowSize = 30

    private var skippedFrames = 0
    private var samples: [Double] = []

    /// Records how long one input frame took to process.
    ///
    /// Returns the window's median processing time when a full window shows the processor cannot
    /// keep up with `frameInterval`, and nil otherwise. Each window is judged once and discarded.
    mutating func observe(processingTime: Double, frameInterval: Double) -> Double? {
        guard processingTime > 0, frameInterval > 0 else { return nil }

        guard skippedFrames >= Self.warmUpFrameCount else {
            skippedFrames += 1
            return nil
        }

        samples.append(processingTime)
        guard samples.count >= Self.windowSize else { return nil }

        let median = samples.sorted()[samples.count / 2]
        samples.removeAll(keepingCapacity: true)
        return median > frameInterval ? median : nil
    }

    mutating func reset() {
        skippedFrames = 0
        samples.removeAll(keepingCapacity: true)
    }
}
