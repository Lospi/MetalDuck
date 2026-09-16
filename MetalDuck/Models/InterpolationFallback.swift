import Foundation

/// A bounded recovery ladder shared by model timeouts and thrown processor errors.
struct InterpolationFallback {
    let resolution: ProcessingResolution
    let spatialUpscaleEnabled: Bool

    func next(plainResolution: ProcessingResolution) -> Self? {
        if let lower = resolution.lowerResolution {
            return Self(resolution: lower, spatialUpscaleEnabled: spatialUpscaleEnabled)
        }
        if spatialUpscaleEnabled {
            return Self(resolution: plainResolution, spatialUpscaleEnabled: false)
        }
        return nil
    }
}
