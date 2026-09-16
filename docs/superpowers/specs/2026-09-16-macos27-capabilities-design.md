# macOS 27 processing capabilities

Use a shared, immutable capability value to distinguish unavailable queries (macOS 26), explicitly unsupported scales, and advertised edge/pixel limits (macOS 27). Validate both dimensions and total pixels before creating VideoToolbox interpolation configurations or selecting super-resolution scales. Keep capture at 1920×1080, user settings and defaults unchanged, and preserve the existing bounded runtime fallback.

Diagnostics show OS/build information, advertised limits per scale, and synthetic processing results separately. A rejected preflight is not a failed processing test; a timeout is not proof of permanent hardware incompatibility. Standalone super-resolution results remain capability queries, not throughput tests. Prefer current OS limits over historical chip-only warnings on macOS 27.

Require the Xcode 27 SDK for compilation and use runtime availability guards to retain the current macOS 26 deployment target. Update the CI runner accordingly. Test the pure bounds policy, unavailable/unsupported distinction, and diagnostic report wording without depending on GPU hardware. Run a separate synthetic diagnostic probe on the local Mac and record its OS/build and limitations.

Out of scope: new defaults, AVFoundation receiver migration, gameplay benchmarks, capture resolution changes, publishing or releasing.
