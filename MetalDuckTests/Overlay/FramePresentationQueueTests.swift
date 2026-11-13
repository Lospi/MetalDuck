import Testing
@testable import MetalDuck

@MainActor
struct FramePresentationQueueTests {
    @MainActor
    private final class Renderer {
        var frames: [Int] = []
        var waiting: CheckedContinuation<FramePresentationQueue<Int>.Result, Never>?
        var flushCount = 0
        var failures: [String] = []

        func enqueue(_ frame: Int) async -> FramePresentationQueue<Int>.Result {
            frames.append(frame)
            return await withCheckedContinuation { waiting = $0 }
        }

        func complete(_ result: FramePresentationQueue<Int>.Result = .accepted) {
            let continuation = waiting
            waiting = nil
            continuation?.resume(returning: result)
        }

        func makeQueue() -> FramePresentationQueue<Int> {
            FramePresentationQueue(enqueue: { await self.enqueue($0) },
                                   flush: { self.flushCount += 1 },
                                   onFailure: { self.failures.append($0) })
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(condition(), "Presentation worker did not reach expected state")
    }

    @Test("Backpressure bounds pending frames and preserves newest-frame order")
    func boundedBackpressure() async throws {
        let renderer = Renderer()
        let queue = renderer.makeQueue()
        defer { queue.stop(); renderer.complete() }
        queue.submit(0)
        try await waitFor { renderer.waiting != nil }
        for frame in 1...10 { queue.submit(frame) }
        #expect(renderer.frames == [0])
        for expected in 7...10 {
            renderer.complete()
            try await waitFor { renderer.frames.last == expected && renderer.waiting != nil }
        }
        #expect(renderer.frames == [0, 7, 8, 9, 10])
    }

    @Test("Flush discards old frames and ignores stale completion errors")
    func flushDuringEnqueue() async throws {
        let renderer = Renderer()
        let queue = renderer.makeQueue()
        defer { queue.stop(); renderer.complete() }
        queue.submit(1)
        try await waitFor { renderer.waiting != nil }
        queue.submit(2)
        queue.flush()
        queue.submit(3)
        renderer.complete(.failed("old generation"))
        try await waitFor { renderer.frames == [1, 3] && renderer.waiting != nil }
        #expect(renderer.failures.isEmpty)
        #expect(renderer.flushCount == 1)
    }

    @Test("Required flush recovers on fresh input without retrying stale frames")
    func recoverAfterFlushRequired() async throws {
        let renderer = Renderer()
        let queue = renderer.makeQueue()
        defer { queue.stop(); renderer.complete() }
        queue.submit(1)
        try await waitFor { renderer.waiting != nil }
        queue.submit(2)
        renderer.complete(.needsFlush)
        try await waitFor { renderer.flushCount == 1 }
        queue.submit(3)
        try await waitFor { renderer.frames == [1, 3] && renderer.waiting != nil }
    }

    @Test("Fatal errors stop presentation and report once")
    func terminalFailure() async throws {
        let renderer = Renderer()
        let queue = renderer.makeQueue()
        queue.submit(1)
        try await waitFor { renderer.waiting != nil }
        queue.submit(2)
        renderer.complete(.failed("renderer unavailable"))
        try await waitFor { !renderer.failures.isEmpty }
        queue.submit(3)
        #expect(renderer.frames == [1])
        #expect(renderer.failures == ["renderer unavailable"])
        #expect(renderer.flushCount == 1)
    }

    @Test("Close during suspended enqueue prevents further submissions")
    func stopDuringEnqueue() async throws {
        let renderer = Renderer()
        let queue = renderer.makeQueue()
        queue.submit(1)
        try await waitFor { renderer.waiting != nil }
        queue.submit(2)
        queue.stop()
        renderer.complete(.failed("cancelled renderer"))
        queue.submit(3)
        await Task.yield()
        #expect(renderer.frames == [1])
        #expect(renderer.failures.isEmpty)
    }
}
