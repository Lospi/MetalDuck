//
//  ProcessingResolutionTests.swift
//  MetalDuckTests
//
//  Tests the deterministic fallback ladder used by VideoToolbox processing.
//

import Testing
@testable import MetalDuck

struct ProcessingResolutionTests {

    @Test(
        "Processing resolutions expose their expected dimensions",
        .tags(.upscaling),
        arguments: [
            ResolutionDimensionCase(resolution: .p360, width: 640, height: 360),
            ResolutionDimensionCase(resolution: .p720, width: 1280, height: 720),
            ResolutionDimensionCase(resolution: .p1080, width: 1920, height: 1080),
            ResolutionDimensionCase(resolution: .p1440, width: 2560, height: 1440)
        ]
    )
    func dimensionsMatchProcessingPreset(sample: ResolutionDimensionCase) {
        let dimensions = sample.resolution.dimensions

        #expect(dimensions.width == sample.width)
        #expect(dimensions.height == sample.height)
    }

    @Test(
        "Lower resolution fallback follows the expected order",
        .tags(.upscaling),
        arguments: [
            ResolutionFallbackCase(resolution: .p1440, expectedLowerResolution: .p1080),
            ResolutionFallbackCase(resolution: .p1080, expectedLowerResolution: .p720),
            ResolutionFallbackCase(resolution: .p720, expectedLowerResolution: .p360),
            ResolutionFallbackCase(resolution: .p360, expectedLowerResolution: nil)
        ]
    )
    func lowerResolutionFollowsFallbackOrder(sample: ResolutionFallbackCase) {
        #expect(sample.resolution.lowerResolution == sample.expectedLowerResolution)
    }
}

struct ResolutionDimensionCase: Sendable, CustomTestStringConvertible {
    let resolution: ProcessingResolution
    let width: Int
    let height: Int

    var testDescription: String {
        "\(resolution.rawValue) -> \(width)x\(height)"
    }
}

struct ResolutionFallbackCase: Sendable, CustomTestStringConvertible {
    let resolution: ProcessingResolution
    let expectedLowerResolution: ProcessingResolution?

    var testDescription: String {
        "\(resolution.rawValue) -> \(expectedLowerResolution?.rawValue ?? "none")"
    }
}
