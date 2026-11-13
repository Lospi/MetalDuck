import Testing
@testable import MetalDuck

@MainActor
struct InterpolationThroughputMonitorTests {
    private static let sixtyFPS = 1.0 / 60.0
    private static let framesUntilVerdict =
        InterpolationThroughputMonitor.warmUpFrameCount + InterpolationThroughputMonitor.windowSize

    /// Feeds the same timing until a verdict is due and returns every verdict produced.
    private func verdicts(
        _ monitor: inout InterpolationThroughputMonitor,
        processingTime: Double,
        frames: Int,
        frameInterval: Double = sixtyFPS
    ) -> [Double] {
        (0..<frames).compactMap { _ in
            monitor.observe(processingTime: processingTime, frameInterval: frameInterval)
        }
    }

    @Test("Processing slower than the capture interval asks for a step-down", .tags(.upscaling, .timing))
    func slowProcessingStepsDown() {
        var monitor = InterpolationThroughputMonitor()
        let result = verdicts(&monitor, processingTime: 0.094, frames: Self.framesUntilVerdict)
        #expect(result == [0.094])
    }

    @Test("Processing that keeps up never asks for a step-down", .tags(.upscaling, .timing))
    func fastProcessingStays() {
        var monitor = InterpolationThroughputMonitor()
        let result = verdicts(&monitor, processingTime: 0.011, frames: Self.framesUntilVerdict * 3)
        #expect(result.isEmpty)
    }

    @Test("No verdict is given before warm-up and a full window have passed", .tags(.upscaling, .timing))
    func waitsForAFullWindow() {
        var monitor = InterpolationThroughputMonitor()
        let result = verdicts(&monitor, processingTime: 0.094, frames: Self.framesUntilVerdict - 1)
        #expect(result.isEmpty)
    }

    @Test("A few slow frames in an otherwise fast window are ignored", .tags(.upscaling, .timing))
    func outliersAreIgnored() {
        var monitor = InterpolationThroughputMonitor()
        var result: [Double] = []
        for frame in 0..<Self.framesUntilVerdict {
            let time = frame % 5 == 0 ? 0.2 : 0.011
            if let verdict = monitor.observe(processingTime: time, frameInterval: Self.sixtyFPS) {
                result.append(verdict)
            }
        }
        #expect(result.isEmpty)
    }

    @Test("The same timing can be acceptable at a lower capture rate", .tags(.upscaling, .timing))
    func verdictDependsOnCaptureRate() {
        var monitor = InterpolationThroughputMonitor()
        let result = verdicts(&monitor, processingTime: 0.025, frames: Self.framesUntilVerdict, frameInterval: 1.0 / 30.0)
        #expect(result.isEmpty)
    }

    @Test("Reset starts warm-up again", .tags(.upscaling, .timing))
    func resetRestartsWarmUp() {
        var monitor = InterpolationThroughputMonitor()
        _ = verdicts(&monitor, processingTime: 0.094, frames: Self.framesUntilVerdict - 1)
        monitor.reset()
        #expect(monitor.observe(processingTime: 0.094, frameInterval: Self.sixtyFPS) == nil)
    }

    @Test("Invalid timings are ignored", .tags(.upscaling, .timing))
    func invalidInputIsIgnored() {
        var monitor = InterpolationThroughputMonitor()
        #expect(monitor.observe(processingTime: 0, frameInterval: Self.sixtyFPS) == nil)
        #expect(monitor.observe(processingTime: 0.094, frameInterval: 0) == nil)
    }
}
