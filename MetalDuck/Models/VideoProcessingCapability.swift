import Foundation

/// Advertised limits are a preflight check, not proof of successful real-time processing.
enum VideoProcessingCapability: Sendable, Equatable {
    case unavailable
    case unsupported
    case limits(maximumDimension: Int, maximumPixelCount: Int)

    nonisolated static func reported(maximumDimension: Int?, maximumPixelCount: Int?) -> Self {
        guard let maximumDimension, let maximumPixelCount,
              maximumDimension > 0, maximumPixelCount > 0 else {
            return .unsupported
        }
        return .limits(maximumDimension: maximumDimension, maximumPixelCount: maximumPixelCount)
    }

    /// nil means the OS cannot answer; callers must retain their legacy runtime checks.
    nonisolated func allows(width: Int, height: Int) -> Bool? {
        guard width > 0, height > 0 else { return false }
        switch self {
        case .unavailable: return nil
        case .unsupported: return false
        case .limits(let edge, let pixels):
            // Division avoids overflow when validating malformed dimensions.
            return width <= edge && height <= edge && width <= pixels / height
        }
    }

    nonisolated var summary: String {
        switch self {
        case .unavailable: return "Per-scale limits unavailable on this OS; using runtime checks."
        case .unsupported: return "Processor or scale unsupported according to macOS."
        case .limits(let edge, let pixels):
            return "Maximum edge: \(edge) px; maximum input pixels: \(pixels)."
        }
    }
}
