import Testing
@testable import MetalDuck

struct VideoProcessingCapabilityTests {
    @Test("Both edge and pixel-budget bounds must pass", .tags(.upscaling))
    func validatesEdgeAndPixelBudget() {
        let capability = VideoProcessingCapability.reported(
            maximumDimension: 1920, maximumPixelCount: 1920 * 1080
        )
        #expect(capability.allows(width: 1920, height: 1080) == true)
        #expect(capability.allows(width: 1080, height: 1920) == true)
        #expect(capability.allows(width: 1440, height: 1440) == true)
        #expect(capability.allows(width: 1920, height: 1920) == false)
        #expect(capability.allows(width: 1921, height: 100) == false)
        #expect(capability.allows(width: 100, height: 1921) == false)
    }

    @Test("Unavailable queries retain runtime checks; unsupported scales do not", .tags(.upscaling))
    func unavailableDiffersFromUnsupported() {
        #expect(VideoProcessingCapability.unavailable.allows(width: 1280, height: 720) == nil)
        #expect(VideoProcessingCapability.unsupported.allows(width: 1280, height: 720) == false)
        #expect(VideoProcessingCapability.reported(maximumDimension: nil, maximumPixelCount: 100) == .unsupported)
        #expect(VideoProcessingCapability.reported(maximumDimension: 100, maximumPixelCount: nil) == .unsupported)
        #expect(VideoProcessingCapability.reported(maximumDimension: 0, maximumPixelCount: 100) == .unsupported)
    }

    @Test("Invalid dimensions are rejected without overflowing", .tags(.upscaling))
    func invalidDimensionsDoNotOverflow() {
        let capability = VideoProcessingCapability.limits(maximumDimension: .max, maximumPixelCount: .max)
        #expect(capability.allows(width: .max, height: 2) == false)
        #expect(capability.allows(width: 0, height: 720) == false)
        #expect(capability.allows(width: 1280, height: -1) == false)
        #expect(capability.allows(width: .max, height: 1) == true)
    }

    @Test("Each spatial scale has independent limits", .tags(.upscaling))
    func spatialScalesAreIndependent() {
        let plain = VideoProcessingCapability.reported(maximumDimension: 1920, maximumPixelCount: 1920 * 1080)
        let upscaled = VideoProcessingCapability.reported(maximumDimension: 960, maximumPixelCount: 960 * 540)
        #expect(plain.allows(width: 1280, height: 720) == true)
        #expect(upscaled.allows(width: 1280, height: 720) == false)
        #expect(upscaled.allows(width: 960, height: 540) == true)
    }
}
