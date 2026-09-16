import Foundation

/// One enqueue in flight, plus at most one four-frame interpolation batch.
/// Under backpressure, discard the oldest pending frame to favor live content.
@MainActor
final class FramePresentationQueue<Frame> {
    enum Result {
        case accepted
        case cancelled
        case needsFlush
        case failed(String)
    }

    private var pending: [Frame] = []
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var stopped = false
    private let enqueue: (Frame) async throws -> Result
    private let flushRenderer: () -> Void
    private let onFailure: (String) -> Void

    init(enqueue: @escaping (Frame) async throws -> Result,
         flush: @escaping () -> Void,
         onFailure: @escaping (String) -> Void) {
        self.enqueue = enqueue
        self.flushRenderer = flush
        self.onFailure = onFailure
    }

    func submit(_ frame: Frame) {
        guard !stopped else { return }
        if pending.count == 4 { pending.removeFirst() }
        pending.append(frame)
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    func flush() {
        generation += 1
        pending.removeAll()
        flushRenderer()
    }

    func stop() {
        stopped = true
        worker?.cancel()
        flush()
    }

    private func drain() async {
        defer { worker = nil }
        while !stopped, !Task.isCancelled, !pending.isEmpty {
            let frame = pending.removeFirst()
            let enqueueGeneration = generation
            let result: Result
            do {
                result = try await enqueue(frame)
            } catch {
                guard !stopped, enqueueGeneration == generation else { continue }
                result = .failed(error.localizedDescription)
            }
            // A flush/close may have occurred while enqueue was suspended.
            guard !stopped, enqueueGeneration == generation else { continue }
            switch result {
            case .accepted, .cancelled:
                break
            case .needsFlush:
                flush() // Discard stale frames; resume with the next captured frame.
            case .failed(let message):
                stop()
                onFailure(message)
            }
        }
    }
}
