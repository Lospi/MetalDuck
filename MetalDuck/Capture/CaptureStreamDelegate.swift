//
//  CaptureStreamDelegate.swift
//  MetalDuck
//

import Foundation
import os
import ScreenCaptureKit

/// Decides how an external `SCStream` stop callback should terminate the frame stream.
nonisolated enum CaptureStreamStopDisposition: Equatable, Sendable {
    /// User intentionally stopped sharing (e.g. from the macOS menu bar indicator).
    case quiet
    /// System stop or unexpected capture error that should be surfaced to the user.
    case failure

    static func disposition(for error: Error) -> CaptureStreamStopDisposition {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == SCStreamError.userStopped.rawValue {
            return .quiet
        }
        return .failure
    }
}

/// Bridges `SCStreamDelegate` callbacks onto the capture `AsyncThrowingStream`.
///
/// ScreenCaptureKit delivers delegate callbacks on an internal background queue, so all
/// delegate methods and stored state are `nonisolated` and synchronized with a lock.
nonisolated final class CaptureStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation
    private let stoppedExternally = OSAllocatedUnfairLock(initialState: false)
    private let onActivityChange: @Sendable (Bool) -> Void

    init(
        continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation,
        onActivityChange: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        self.continuation = continuation
        self.onActivityChange = onActivityChange
        super.init()
    }

    var didStopExternally: Bool {
        stoppedExternally.withLock { $0 }
    }

    func handleStreamStop(error: Error) {
        let alreadyStopped = stoppedExternally.withLock { stopped -> Bool in
            if stopped { return true }
            stopped = true
            return false
        }
        guard !alreadyStopped else { return }

        switch CaptureStreamStopDisposition.disposition(for: error) {
        case .quiet:
            print("SCStream stopped by user")
            continuation.finish()
        case .failure:
            print("SCStream stopped with error: \(error.localizedDescription)")
            continuation.finish(throwing: error)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        handleStreamStop(error: error)
    }

    func streamDidBecomeInactive(_ stream: SCStream) {
        print("SCStream became inactive (all shared windows closed)")
        onActivityChange(false)
    }

    func streamDidBecomeActive(_ stream: SCStream) {
        print("SCStream became active (shared window reopened)")
        onActivityChange(true)
    }
}
