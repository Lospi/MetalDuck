import AVFoundation
import CoreMedia

@available(macOS 27.0, *)
@MainActor
final class ReceiverFramePresenter {
    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let receiver: AVSampleBufferVideoRenderer.Receiver
    private let queue: FramePresentationQueue<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>

    init(renderer: AVSampleBufferVideoRenderer, onFailure: @escaping (String) -> Void) {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        let receiver = synchronizer.sampleBufferReceiver(adding: renderer)
        self.synchronizer = synchronizer
        self.receiver = receiver
        queue = FramePresentationQueue(enqueue: { sample in
            switch try await receiver.enqueue(sample) {
            case .enqueued, .enqueuedWithDecodeFailures:
                return .accepted
            case .cancelledDueToFlush:
                return .cancelled
            case .cancelledDueToFlushRequiredToResume:
                return .needsFlush
            case .cancelledDueToError(let error):
                return .failed(error.localizedDescription)
            @unknown default:
                return .failed("Unknown video receiver result")
            }
        }, flush: { receiver.flush() }, onFailure: onFailure)
        // Live video must not wait for a playback pre-roll buffer.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.setRate(1, time: .zero)
    }

    var currentTime: CMTime { synchronizer.currentTime() }

    func enqueue(_ sample: sending CMSampleBuffer) {
        // OverlayManager creates a ready image sample and relinquishes it here.
        queue.submit(CMReadySampleBuffer(unsafeBuffer: sample))
    }

    func flush() { queue.flush() }

    func stop() {
        queue.stop()
        synchronizer.setRate(0, time: .invalid)
    }
}
