# macOS 27 receiver presentation validation

The macOS 27 overlay uses `AVSampleBufferVideoRenderer.Receiver` with an
`AVSampleBufferRenderSynchronizer`. The synchronizer runs at rate 1 without
waiting for pre-roll. Existing presentation timestamps and interpolation offsets
remain intact. macOS 26 retains its display-layer timebase and renderer path.

A single async enqueue worker applies receiver backpressure. It retains at most
four pending samples plus one in flight; overload drops the oldest pending sample.
Flush invalidates pending samples and ignores completions from the old generation.
A required-flush result discards stale samples and resumes on fresh input. Terminal
errors stop the worker and appear in the debug HUD with a restart-capture message.
Close cancels the worker, flushes the receiver, stops the clock, and removes the
layer. Borderless windows still use `orderOut`.

## Automated checks

Xcode 27 RC, macOS 27.2 (26B5086k), M1 Pro:

```sh
xcodebuild test -scheme MetalDuck -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/metalduck-receiver-build \
  -only-testing:MetalDuckTests CODE_SIGNING_ALLOWED=NO
```

Passed: 48 reported test cases, including five new tests for bounded backpressure,
flush during enqueue, required-flush recovery, terminal failure, and close during
enqueue. Existing VideoToolbox attachment/cast and capability-test actor-isolation
warnings remain; the new receiver files emitted no compiler warnings.

## Actual presentation smoke test

Run from the repository root on macOS 27. This briefly opens a 64x64 test window:

```sh
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -target arm64-apple-macos26.1 \
  -module-cache-path /private/tmp/metalduck-probe-module-cache \
  MetalDuck/Overlay/FramePresentationQueue.swift \
  MetalDuck/Overlay/ReceiverFramePresenter.swift \
  scripts/validate-receiver.swift -o /private/tmp/metalduck-receiver-probe
/private/tmp/metalduck-receiver-probe
```

The test reads pixels back using `displayedPixelBuffer()` and verifies different
frame contents before and after flushing:

```text
cycle 0: displayed 64x64, byte=64
cycle 1: displayed 64x64, byte=192
Receiver presentation and flush smoke test passed
```

A preliminary test without a window returned no displayed buffer. The successful
test attaches the same presenter to a window-backed layer. This validates actual
synthetic presentation and flush recovery, not sustained game FPS, latency,
compositor cadence, resize tracking, or a macOS 26 runtime.

## API references

- [Receiver enqueue](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/receiver/enqueue(_:))
- [Required-flush result](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/receiver/enqueueresult/cancelledduetoflushrequiredtoresume(_:))
- The installed Xcode 27 SDK Swift interface was used to verify exact enum cases
  and the ready-sample-buffer conversion.
