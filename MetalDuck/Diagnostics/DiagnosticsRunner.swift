//
//  DiagnosticsRunner.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 25/03/26.
//
//  Runs hardware capability tests for frame interpolation and super-resolution,
//  collects device info, and generates a standardized markdown report for bug reports.
//

import CoreMedia
import CoreVideo
import Darwin
import Foundation
import IOKit
import Metal
@preconcurrency import VideoToolbox

// MARK: - sysctl helpers

private func sysctlInt(_ name: String) -> Int? {
    var value = 0
    var size = MemoryLayout<Int>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

// MARK: - DiagnosticsRunner

@available(macOS 14.0, *)
@Observable @MainActor
final class DiagnosticsRunner {

    // MARK: - Types

    enum TestStatus: Equatable {
        case pending
        case running
        case supported(loadTime: Double)
        case unsupported
        case hardwareUnsupported
        case failed(String)
    }

    struct FrameInterpolationResult: Identifiable {
        let id = UUID()
        let resolution: ProcessingResolution
        var status: TestStatus = .pending
    }

    struct SuperResolutionEntry: Identifiable {
        let id = UUID()
        let inputLabel: String
        let inputWidth: Int
        let inputHeight: Int
        var isSupported: Bool = false
        var supportedScaleFactors: [Float] = []
    }

    struct DeviceInfo {
        let chip: String
        let physicalCPUs: Int
        let performanceCores: Int?
        let efficiencyCores: Int?
        let gpuCores: Int?
        let memoryGB: Int
        let macOSVersion: String
    }

    // MARK: - Published State

    var isRunning = false
    var currentStep = ""
    var deviceInfo: DeviceInfo?
    var frameInterpIsSupported = VTLowLatencyFrameInterpolationConfiguration.isSupported
    var superResIsSupported = VTLowLatencySuperResolutionScalerConfiguration.isSupported
    var frameInterpolationResults: [FrameInterpolationResult] = ProcessingResolution.allCases.map { .init(resolution: $0) }
    var spatialFrameInterpolationResults: [FrameInterpolationResult] = ProcessingResolution.allCases.map { .init(resolution: $0) }
    var superResolutionEntries: [SuperResolutionEntry] = []
    var reportText = ""

    // MARK: - Run

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        reportText = ""
        frameInterpolationResults = ProcessingResolution.allCases.map { .init(resolution: $0) }
        spatialFrameInterpolationResults = ProcessingResolution.allCases.map { .init(resolution: $0) }
        superResolutionEntries = []

        currentStep = "Collecting device info..."
        deviceInfo = collectDeviceInfo()

        if frameInterpIsSupported {
            for i in frameInterpolationResults.indices {
                let res = frameInterpolationResults[i].resolution
                frameInterpolationResults[i].status = .running
                currentStep = "Testing Frame Interpolation @ \(res.rawValue)..."
                frameInterpolationResults[i].status = await testFrameInterpolation(resolution: res)
            }

            for i in spatialFrameInterpolationResults.indices {
                let res = spatialFrameInterpolationResults[i].resolution
                spatialFrameInterpolationResults[i].status = .running
                currentStep = "Testing Frame Interpolation + 2x Upscale @ \(res.rawValue)..."
                spatialFrameInterpolationResults[i].status = await testFrameInterpolation(
                    resolution: res,
                    spatialUpscale: true
                )
            }
        } else {
            for i in frameInterpolationResults.indices {
                frameInterpolationResults[i].status = .hardwareUnsupported
            }
            for i in spatialFrameInterpolationResults.indices {
                spatialFrameInterpolationResults[i].status = .hardwareUnsupported
            }
        }

        currentStep = "Querying Super Resolution capabilities..."
        superResolutionEntries = querySuperResolutionCapabilities()

        currentStep = "Generating report..."
        reportText = generateReport()
        currentStep = "Complete"
        isRunning = false
    }

    // MARK: - Device Info

    private func collectDeviceInfo() -> DeviceInfo {
        // MTLDevice.name gives the chip name on Apple Silicon (e.g. "Apple M1 Pro")
        // and GPU name on Intel (e.g. "Intel UHD Graphics 630")
        let chip = MTLCreateSystemDefaultDevice()?.name
            ?? sysctlString("machdep.cpu.brand_string")
            ?? "Unknown"

        let physicalCPUs = sysctlInt("hw.physicalcpu") ?? 0
        let pCores = sysctlInt("hw.perflevel0.physicalcpu")   // Apple Silicon only
        let eCores = sysctlInt("hw.perflevel1.physicalcpu")   // Apple Silicon only

        // hw.memsize is uint64_t; Int is 64-bit on all supported platforms
        let memBytes = sysctlInt("hw.memsize") ?? 0
        let memGB = max(1, memBytes / (1024 * 1024 * 1024))

        return DeviceInfo(
            chip: chip,
            physicalCPUs: physicalCPUs,
            performanceCores: pCores,
            efficiencyCores: eCores,
            gpuCores: Self.gpuCoreCount(),
            memoryGB: memGB,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    /// Reads `gpu-core-count` from the AGXAccelerator IOKit service (Apple Silicon only).
    private static func gpuCoreCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { return nil }

        return props["gpu-core-count"] as? Int
    }

    // MARK: - Frame Interpolation Test

    /// Loads the VT frame interpolation model at the given resolution and measures load time.
    /// Feeds synthetic (black) frames in a loop until the model reports ready or failed.
    private func testFrameInterpolation(
        resolution: ProcessingResolution,
        spatialUpscale: Bool = false
    ) async -> TestStatus {
        let dims = resolution.dimensions
        let inputDims = CMVideoDimensions(width: Int32(dims.width), height: Int32(dims.height))

        let interpolator: RealTimeFrameInterpolation
        do {
            interpolator = try RealTimeFrameInterpolation(
                numFrames: 1,
                inputDimensions: inputDims,
                maxWidth: dims.width,
                maxHeight: dims.height,
                spatialUpscale: spatialUpscale
            )
            try await interpolator.start()
        } catch {
            return .failed(error.localizedDescription)
        }

        let startTime = Date()
        var pts = CMTime(value: 0, timescale: 600)
        let stepTime = CMTime(value: 10, timescale: 600) // ~60fps cadence

        while !Task.isCancelled {
            pts = CMTimeAdd(pts, stepTime)

            let srcBuffer: CVPixelBuffer
            do {
                srcBuffer = try await interpolator.createSyntheticSourceBuffer()
            } catch {
                await interpolator.stop()
                return .failed("Buffer allocation failed")
            }

            do {
                _ = try await interpolator.process(currentBuffer: srcBuffer, currentTimestamp: pts)
            } catch {
                await interpolator.stop()
                return .failed(error.localizedDescription)
            }

            if await interpolator.modelReady {
                let elapsed = Date().timeIntervalSince(startTime)
                await interpolator.stop()
                return .supported(loadTime: elapsed)
            }

            if await interpolator.modelFailed {
                await interpolator.stop()
                return .unsupported
            }

            try? await Task.sleep(nanoseconds: 16_000_000) // ~60fps pacing
        }

        await interpolator.stop()
        return .failed("Cancelled")
    }

    // MARK: - Super Resolution Capabilities

    /// Queries static VT API to determine which input sizes and scale factors are supported.
    /// No model loading is needed — this is instant.
    private func querySuperResolutionCapabilities() -> [SuperResolutionEntry] {
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else { return [] }

        let maxDims = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions
        let minDims = VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions

        let testInputs: [(label: String, w: Int, h: Int)] = [
            ("360p (640×360)", 640, 360),
            ("540p (960×540)", 960, 540),
            ("720p (1280×720)", 1280, 720),
            ("1080p (1920×1080)", 1920, 1080),
        ]

        return testInputs.map { input in
            var entry = SuperResolutionEntry(
                inputLabel: input.label,
                inputWidth: input.w,
                inputHeight: input.h
            )

            if let max = maxDims, Int32(input.w) > max.width || Int32(input.h) > max.height {
                return entry // isSupported stays false
            }
            if let min = minDims, Int32(input.w) < min.width || Int32(input.h) < min.height {
                return entry
            }

            let factors = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
                frameWidth: input.w,
                frameHeight: input.h
            )
            entry.supportedScaleFactors = factors
            entry.isSupported = !factors.isEmpty
            return entry
        }
    }

    // MARK: - Report Generation

    func generateReport() -> String {
        var lines: [String] = []

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        lines.append("## MetalDuck Device Diagnostics")
        lines.append("")
        lines.append("**Generated:** \(formatter.string(from: Date()))")
        lines.append("")

        // Device section
        if let info = deviceInfo {
            lines.append("### Device")
            lines.append("- **Chip:** \(info.chip)")
            var cpuLine = "- **CPU Cores:** \(info.physicalCPUs)"
            if let p = info.performanceCores, let e = info.efficiencyCores {
                cpuLine += " (\(p)P + \(e)E)"
            }
            lines.append(cpuLine)
            if let gpu = info.gpuCores {
                lines.append("- **GPU Cores:** \(gpu)")
            }
            lines.append("- **Memory:** \(info.memoryGB) GB")
            lines.append("- **macOS:** \(info.macOSVersion)")
            lines.append("")
        }

        // Frame interpolation section
        lines.append("### Frame Interpolation (`VTLowLatencyFrameInterpolation`)")
        if !frameInterpIsSupported {
            lines.append("")
            lines.append("❌ Not supported on this hardware/OS version.")
        } else {
            lines.append("")
            lines.append("| Resolution | Dimensions | Status | Model Load Time |")
            lines.append("|-----------|-----------|--------|----------------|")
            for result in frameInterpolationResults {
                let dims = result.resolution.dimensions
                let dimStr = "\(dims.width)×\(dims.height)"
                let (statusStr, noteStr) = reportStatus(result.status)
                lines.append("| \(result.resolution.rawValue) | \(dimStr) | \(statusStr) | \(noteStr) |")
            }
        }
        lines.append("")

        // Frame interpolation + spatial upscale section
        lines.append("### Frame Interpolation + 2x Upscale (`VTLowLatencyFrameInterpolation`)")
        if !frameInterpIsSupported {
            lines.append("")
            lines.append("❌ Not supported on this hardware/OS version.")
        } else {
            lines.append("")
            lines.append("| Resolution | Input | Output | Status | Model Load Time |")
            lines.append("|-----------|-------|--------|--------|----------------|")
            for result in spatialFrameInterpolationResults {
                let dims = result.resolution.dimensions
                let inputStr = "\(dims.width)×\(dims.height)"
                let outputStr = "\(dims.width * 2)×\(dims.height * 2)"
                let (statusStr, noteStr) = reportStatus(result.status)
                lines.append("| \(result.resolution.rawValue) | \(inputStr) | \(outputStr) | \(statusStr) | \(noteStr) |")
            }
        }
        lines.append("")

        // Super resolution section
        lines.append("### Super Resolution (`VTLowLatencySuperResolutionScaler`)")
        if !superResIsSupported {
            lines.append("")
            lines.append("❌ Not supported on this hardware/OS version.")
        } else if superResolutionEntries.isEmpty {
            lines.append("")
            lines.append("No results available.")
        } else {
            if let maxDims = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions {
                lines.append("")
                lines.append("**Maximum input dimensions:** \(maxDims.width)×\(maxDims.height)")
            }
            lines.append("")
            lines.append("| Input | Supported | Scale Factors |")
            lines.append("|-------|-----------|--------------|")
            for entry in superResolutionEntries {
                let icon = entry.isSupported ? "✅" : "❌"
                let factors = entry.isSupported
                    ? entry.supportedScaleFactors.map { String(format: "%.1fx", $0) }.joined(separator: ", ")
                    : "—"
                lines.append("| \(entry.inputLabel) | \(icon) | \(factors) |")
            }
        }
        lines.append("")
        lines.append("---")
        lines.append("*Generated by MetalDuck Diagnostics — paste this into a GitHub issue*")

        return lines.joined(separator: "\n")
    }

    private func reportStatus(_ status: TestStatus) -> (String, String) {
        switch status {
        case .pending:              return ("⏳ Pending", "—")
        case .running:              return ("🔄 Running", "—")
        case .supported(let t):     return ("✅ Supported", String(format: "%.1f s", t))
        case .unsupported:          return ("❌ Unsupported", "—")
        case .hardwareUnsupported:  return ("⚫ N/A", "—")
        case .failed(let msg):      return ("⚠️ Error", msg)
        }
    }
}
