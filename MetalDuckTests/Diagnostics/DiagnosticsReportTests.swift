import Testing
@testable import MetalDuck

struct DiagnosticsReportTests {
    @Test("Reports separate advertised limits, skipped tests, and produced frames")
    @MainActor func distinguishesCapabilityAndProcessingResults() {
        let runner = DiagnosticsRunner()
        runner.frameInterpIsSupported = true
        runner.superResIsSupported = true
        runner.interpolationCapability = .limits(maximumDimension: 1920, maximumPixelCount: 2073600)
        runner.spatialInterpolationCapability = .unsupported
        runner.frameInterpolationResults = [
            .init(resolution: .p720, status: .supported(loadTime: 0.025)),
            .init(resolution: .p1080, status: .unsupported),
            .init(resolution: .p1440, status: .capabilityRejected)
        ]
        let report = runner.generateReport()
        #expect(report.contains("Maximum edge: 1920 px; maximum input pixels: 2073600"))
        #expect(report.contains("Produced frames | 0.025 s"))
        #expect(report.contains("Timed out | No processed output before timeout"))
        #expect(report.contains("Skipped: OS limits | Model not started"))
        #expect(report.contains("model execution and throughput were not tested"))
    }

    @Test("Legacy reports do not claim that missing queries imply unsupported hardware")
    @MainActor func legacyQueriesRemainUnknown() {
        let runner = DiagnosticsRunner()
        runner.interpolationCapability = .unavailable
        runner.spatialInterpolationCapability = .unavailable
        let report = runner.generateReport()
        #expect(report.contains("Per-scale limits unavailable on this OS; using runtime checks."))
    }
}
