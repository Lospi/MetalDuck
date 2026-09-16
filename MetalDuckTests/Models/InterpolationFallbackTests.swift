import Testing
@testable import MetalDuck

struct InterpolationFallbackTests {
    @Test("Failures lower spatial resolution, then retry plain interpolation", .tags(.upscaling))
    func spatialFailuresReachPlainInterpolation() throws {
        var state = InterpolationFallback(resolution: .p720, spatialUpscaleEnabled: true)
        state = try #require(state.next(plainResolution: .p720))
        #expect(state.resolution == .p360)
        #expect(state.spatialUpscaleEnabled)
        state = try #require(state.next(plainResolution: .p720))
        #expect(state.resolution == .p720)
        #expect(state.spatialUpscaleEnabled == false)
        state = try #require(state.next(plainResolution: .p720))
        #expect(state.resolution == .p360)
        #expect(state.next(plainResolution: .p720) == nil)
    }

    @Test("Plain interpolation failure at the lowest resolution terminates", .tags(.upscaling))
    func plainFailureTerminates() {
        let state = InterpolationFallback(resolution: .p360, spatialUpscaleEnabled: false)
        #expect(state.next(plainResolution: .p720) == nil)
    }
}
