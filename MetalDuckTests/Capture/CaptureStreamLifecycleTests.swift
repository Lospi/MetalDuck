//
//  CaptureStreamLifecycleTests.swift
//  MetalDuckTests
//

import Foundation
import ScreenCaptureKit
import Testing
@testable import MetalDuck

@MainActor
struct CaptureStreamLifecycleTests {
    private enum DummyError: Error, Equatable {
        case unexpected
    }

    @Test("SCStreamError.userStopped is classified as a quiet stop", .tags(.capture))
    func userStoppedIsQuiet() {
        let error = NSError(domain: SCStreamErrorDomain, code: SCStreamError.userStopped.rawValue)
        #expect(CaptureStreamStopDisposition.disposition(for: error) == .quiet)
    }

    @Test("System stops and other errors are classified as failures", .tags(.capture))
    func systemStopAndOtherErrorsAreFailures() {
        let systemStopped = NSError(domain: SCStreamErrorDomain, code: SCStreamError.systemStoppedStream.rawValue)
        let internalError = NSError(domain: SCStreamErrorDomain, code: SCStreamError.internalError.rawValue)
        let other = DummyError.unexpected

        #expect(CaptureStreamStopDisposition.disposition(for: systemStopped) == .failure)
        #expect(CaptureStreamStopDisposition.disposition(for: internalError) == .failure)
        #expect(CaptureStreamStopDisposition.disposition(for: other) == .failure)
    }

    @Test("Delegate finishes stream cleanly on userStopped and marks external stop", .tags(.capture))
    func delegateFinishesQuietlyOnUserStopped() async throws {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: CapturedFrame.self)
        let delegate = CaptureStreamDelegate(continuation: continuation)

        #expect(!delegate.didStopExternally)
        delegate.handleStreamStop(error: NSError(domain: SCStreamErrorDomain, code: SCStreamError.userStopped.rawValue))
        #expect(delegate.didStopExternally)

        var frameCount = 0
        for try await _ in stream {
            frameCount += 1
        }
        #expect(frameCount == 0)
    }

    @Test("Delegate throws error on system stop and ignores duplicate stop callbacks", .tags(.capture))
    func delegateThrowsOnSystemStopAndIsIdempotent() async {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: CapturedFrame.self)
        let delegate = CaptureStreamDelegate(continuation: continuation)

        let systemStop = NSError(domain: SCStreamErrorDomain, code: SCStreamError.systemStoppedStream.rawValue)
        delegate.handleStreamStop(error: systemStop)
        delegate.handleStreamStop(error: NSError(domain: SCStreamErrorDomain, code: SCStreamError.userStopped.rawValue))
        #expect(delegate.didStopExternally)

        var caughtError: NSError?
        do {
            for try await _ in stream {}
        } catch {
            caughtError = error as NSError
        }
        #expect(caughtError?.domain == SCStreamErrorDomain)
        #expect(caughtError?.code == SCStreamError.systemStoppedStream.rawValue)
    }

    @Test("Capture loop stops session quietly when stream ends cleanly", .tags(.capture))
    func captureLoopStopsQuietlyOnCleanFinish() async {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Int.self)
        var frames: [Int] = []
        var errors: [Error] = []
        var stopCount = 0

        let loopTask = Task {
            await AppCoordinator.runCaptureLoop(
                stream: stream,
                isCurrentSession: { true },
                onFrame: { frames.append($0) },
                onError: { errors.append($0) },
                onStop: { stopCount += 1 }
            )
        }

        continuation.yield(1)
        continuation.yield(2)
        continuation.finish()
        await loopTask.value

        #expect(frames == [1, 2])
        #expect(errors.isEmpty)
        #expect(stopCount == 1)
    }

    @Test("Capture loop records error and stops session when stream throws", .tags(.capture))
    func captureLoopReportsErrorAndStops() async {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Int.self)
        var errors: [Error] = []
        var stopCount = 0

        let loopTask = Task {
            await AppCoordinator.runCaptureLoop(
                stream: stream,
                isCurrentSession: { true },
                onFrame: { _ in },
                onError: { errors.append($0) },
                onStop: { stopCount += 1 }
            )
        }

        continuation.finish(throwing: DummyError.unexpected)
        await loopTask.value

        #expect(errors.count == 1)
        #expect(errors.first as? DummyError == .unexpected)
        #expect(stopCount == 1)
    }

    @Test("Cancelled capture loop does not stop a subsequent session when its stream finishes", .tags(.capture))
    func cancelledCaptureLoopSkipsTeardown() async {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Int.self)
        var errors: [Error] = []
        var stopCount = 0

        let loopTask = Task {
            await AppCoordinator.runCaptureLoop(
                stream: stream,
                isCurrentSession: { true },
                onFrame: { _ in },
                onError: { errors.append($0) },
                onStop: { stopCount += 1 }
            )
        }

        await Task.yield()
        loopTask.cancel()
        continuation.finish(throwing: DummyError.unexpected)
        await loopTask.value

        #expect(errors.isEmpty)
        #expect(stopCount == 0)
    }

    @Test("Stale session identity prevents old stream from stopping a newer session", .tags(.capture))
    func staleSessionSkipsTeardownAndError() async {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Int.self)
        var isCurrent = true
        var errors: [Error] = []
        var stopCount = 0

        let loopTask = Task {
            await AppCoordinator.runCaptureLoop(
                stream: stream,
                isCurrentSession: { isCurrent },
                onFrame: { _ in },
                onError: { errors.append($0) },
                onStop: { stopCount += 1 }
            )
        }

        await Task.yield()
        isCurrent = false
        continuation.finish(throwing: DummyError.unexpected)
        await loopTask.value

        #expect(errors.isEmpty)
        #expect(stopCount == 0)
    }
}
