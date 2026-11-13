# MetalDuck

A macOS menu-bar app that captures any game window or display via **ScreenCaptureKit** and applies **real-time frame interpolation** (e.g. 30 fps → 60+ fps) using Apple's on-device VideoToolbox ML models (`VTLowLatencyFrameInterpolation`). The output is rendered as a transparent, click-through overlay that sits precisely on top of the original window — no game modifications required.

## Features

- **Frame interpolation** — doubles (or triples/quadruples) the frame rate of any window using Apple's VideoToolbox neural interpolation model
- **Transparent overlay** — borderless, click-through window rendered with `AVSampleBufferDisplayLayer` so the game remains fully interactive underneath
- **Auto-fallback** — if a chosen processing resolution is unsupported on the current device, MetalDuck automatically steps down to the next lower resolution
- **Device diagnostics** — built-in diagnostics runner that tests model capabilities on your specific chip and generates a markdown report for GitHub issues
- **Menu bar app** — lives in the menu bar; no Dock icon, no interference with your workflow
- **Content picker** — uses `SCContentSharingPicker` to visually select any window or display

## Requirements

| Requirement | Minimum |
|---|---|
| macOS | 26.0 |
| Xcode | 27.0 (builds against the macOS 27 SDK) |

> Frame interpolation uses `VTLowLatencyFrameInterpolation`, available on Apple Silicon. On macOS 27 the app asks the OS for its processing limits before starting the model; on macOS 26 it falls back to a lower resolution at runtime. On an M1 Pro, macOS 26 supported up to **720p**, while macOS 27.2 advertises and produced frames at **1080p** in a synthetic test (see `docs/validation/`).

## Build

```bash
cd MetalDuck
xcodebuild build -scheme MetalDuck -destination 'platform=macOS'
```

Or open `MetalDuck/MetalDuck.xcodeproj` in Xcode and press **Run**.

### Permissions

On first launch MetalDuck will request **Screen Recording** permission. Grant it in **System Settings → Privacy & Security → Screen Recording**.

## Usage

1. Launch MetalDuck — a videogame controller icon appears in the menu bar.
2. Click the icon → **Preferences**.
3. Select a **Capture Type** (Window or Display) and pick your target.
4. Set **Mode** to *Frame Interpolation* and choose a **Processing Resolution** (720p is currently the most tested).
5. Click **Start** in the menu — the overlay appears on top of your window.
6. To stop, click the menu bar icon → **Stop**.

### Processing Resolutions

| Resolution | Dimensions | M1 Pro |
|---|---|---|
| 360p | 640 × 360 | Supported |
| 720p | 1280 × 720 | Supported |
| 1080p | 1920 × 1080 | Unsupported (auto-fallback) |
| 1440p | 2560 × 1440 | Unsupported (auto-fallback) |

If the model fails to produce a frame within 5 seconds at the selected resolution, MetalDuck automatically falls back to the next lower resolution.

## Architecture

```
SCStream
  └─ AsyncThrowingStream<CapturedFrame>   (CaptureSession)
       └─ AppCoordinator
            └─ RealTimeFrameInterpolation  (actor, optional)
                 └─ OverlayManager.enqueueBuffer()
                      └─ AVSampleBufferDisplayLayer  (timed via CMTimebase)
```

**Key components:**

| File | Role |
|---|---|
| `App/AppCoordinator.swift` | Central singleton — owns capture, interpolation, overlay |
| `Capture/CaptureSession.swift` | `SCStream` → `AsyncThrowingStream<CapturedFrame>` |
| `Metal/RealTimeFrameInterpolation.swift` | `VTLowLatencyFrameInterpolation` actor |
| `Overlay/OverlayManager.swift` | Borderless `NSWindow` + `AVSampleBufferDisplayLayer` |
| `Diagnostics/DiagnosticsRunner.swift` | Device capability tests + markdown report generator |
| `Models/DeviceCapabilityDatabase.swift` | Community-sourced chip compatibility database |

## Device Diagnostics

MetalDuck includes a diagnostics tool to map which processing resolutions work on your chip. Run it via **Preferences → Debug → Run Device Diagnostics**. It will:

1. Detect your chip, CPU cores, RAM, and macOS version
2. Test each `ProcessingResolution` with the VideoToolbox interpolation model
3. Query super-resolution scaler capabilities
4. Generate a markdown report you can paste into a GitHub issue

This helps build the community compatibility database (`Resources/DeviceCapabilities.json`).

## Contributing Compatibility Data

If you run the diagnostics on a chip that isn't in the database yet, please [open a GitHub issue](../../issues/new) and paste the generated report. This data improves the resolution recommendations shown in Preferences for all users.

## Known Limitations

- Capture is fixed at **1920×1080** regardless of the target window size — some system APIs return incorrect dimensions for game windows.
- SCStream's capture buffer contains ~3% black padding on the right edge; MetalDuck clips this automatically using the content-width ratio computed on the first frame.
- Super-resolution (`VTLowLatencySuperResolutionScaler`) on M1 Pro only supports 2× upscale at inputs ≤ 960×540.
- Multipliers above 2× may introduce latency or quality artifacts; 2× is recommended.