import AppKit
import AVFoundation
import CoreVideo
import CoreMedia

@main
struct ReceiverProbe {
    @MainActor static func main() async throws {
        guard #available(macOS 27.0, *) else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 64, height: 64),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        view.wantsLayer = true
        window.contentView = view
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = view.bounds
        view.layer!.addSublayer(layer)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let renderer = layer.sampleBufferRenderer
        var errors: [String] = []
        let presenter = ReceiverFramePresenter(renderer: renderer) { errors.append($0) }
        defer { presenter.stop() }
        for cycle in 0..<2 {
            if cycle == 1 { presenter.flush() }
            var image: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image)
            let pixel = image!
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), cycle == 0 ? 64 : 192,
                   CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                        imageBuffer: pixel, formatDescriptionOut: &format)
            var timing = CMSampleTimingInfo(duration: .invalid,
                presentationTimeStamp: CMTimeAdd(presenter.currentTime, CMTime(seconds: 0.02, preferredTimescale: 600)),
                decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
            presenter.enqueue(sample!)
            try await Task.sleep(for: .milliseconds(500))
            guard let displayed = renderer.displayedPixelBuffer() else {
                fatalError("No displayed frame for cycle \(cycle); errors=\(errors)")
            }
            CVPixelBufferLockBaseAddress(displayed, .readOnly)
            let value = CVPixelBufferGetBaseAddress(displayed)!.load(as: UInt8.self)
            CVPixelBufferUnlockBaseAddress(displayed, .readOnly)
            precondition(value == (cycle == 0 ? 64 : 192), "Unexpected frame content")
            print("cycle \(cycle): displayed \(CVPixelBufferGetWidth(displayed))x\(CVPixelBufferGetHeight(displayed)), byte=\(value)")
        }
        precondition(errors.isEmpty)
        precondition(presenter.currentTime.seconds > 0)
        print("Receiver presentation and flush smoke test passed")
    }
}
