# Adaptive DCT performance and validation

Measured locally on an arm64 Mac with Swift 6.3.2, September 8, 2026.
Each workload covers a 2976 × 1860 framebuffer (86,676 tiles). Times below
are milliseconds per rectangle with pixel generation enabled: median of three
iterations after one warm-up. Stream construction and framebuffer construction
are outside the timer. Refinement/cache setup is also outside its timed region.
These are deterministic synthetic workloads, not live-server frame-rate measurements.

The baseline is the implementation at `f202e39`. "Forced Debug" includes its
Swift `-O` and C `-O3` overrides. Both final configurations use normal package
build settings, with no unsafe optimization flags.

| Workload | Before: forced Debug | Before: normal Debug | After: normal Debug | Before: Release | After: Release |
| --- | ---: | ---: | ---: | ---: | ---: |
| fresh | 28.8 | 772.5 | 133.4 | 28.6 | 7.9 |
| dc | 23.1 | 699.3 | 71.3 | 22.9 | 4.7 |
| reuse | 4.9 | 470.1 | 13.6 | 5.3 | 2.8 |
| copy | 4.2 | 48.6 | 11.1 | 5.1 | 2.1 |
| solid | 2.8 | 435.5 | 21.8 | 3.1 | 1.8 |
| palette | 6.2 | 492.1 | 54.5 | 5.7 | 2.5 |
| refine | 36.6 | 1511.2 | 157.1 | 35.2 | 9.3 |
| cache | 14.2 | 658.5 | 73.8 | 14.0 | 3.9 |

Fresh tiles are approximately 5.8× faster in normal Debug and 3.6× faster in
Release. Refinement is approximately 9.6× faster in normal Debug and 3.8× faster
in Release. **The goal of matching the old forced-optimized Debug speed is not
met**: fresh/refinement rectangles still take roughly four to five times longer
than that baseline. The speed improvements do remove the package's dependency
on unsafe target optimization flags.

## Changes

- Swift parsing borrows stream buffers once per rectangle and specializes
  single-bit reads. Tight integer loops avoid unoptimized iterator overhead.
- Connection-owned coefficient/map buffers replace per-tile allocations;
  metadata and lazily allocated cache pages retain independent snapshots.
- Quantization/pixel buffers are borrowed once, with bulk framebuffer row copies.
- The kernel skips DC-only transforms, vectorizes dequantization, and shares
  color conversion work across constant-chroma tiles. Unoptimized ARM builds
  use the existing scalar transform for conservatively bounded coefficients;
  other blocks retain ARM narrowing behavior. Scalar 32-bit wrap is explicit.

## Verification

- Debug and Release: 271-test DCT/transport regression selection passes
  (four opt-in tests skipped in Debug; three in Release with the benchmark enabled).
- Swift address sanitizer: 29 tests, one opt-in benchmark skipped, no failures.
- Kernel address/undefined-behavior sanitizers: native and forced scalar at
  both `-O0` and `-O3`; 336,072 tiles per configuration match pre-change golden
  hashes, covering exhaustive DC values, sparse/dense coefficients, every
  constant-chroma pair, and wide quantization values.
- An external consumer resolved version `0.1.2` from the local repository.
  Its temporary checkout was overlaid with the working sources/manifest;
  both the `RFBRendering` and full `rootshellVNC` products built and ran.
  No commit or tag was created. This checks version-selected consumption of
  the proposed files; the existing published `0.1.2` remains unchanged and
  still needs its old workaround. A new release containing the fix is needed.

## Reproduce

```sh
VNC_DCT_BENCHMARK=1 swift test --filter AppleDCTPerformanceTests
VNC_DCT_BENCHMARK=1 swift test -c release --filter AppleDCTPerformanceTests
swift test --filter 'AppleDCT|DCT|RFBTransportTests'
swift test -c release --filter 'AppleDCT|DCT|RFBTransportTests'
swift test --sanitize=address --filter 'AppleDCTPerformanceTests|AppleAdaptiveDCTDecoderTests'
Tools/Diagnostics/check_apple_dct_kernel.sh --sanitize
```

Run benchmarks without other builds or CPU-heavy tasks in flight. `draw=false`
suppresses DCT pixel generation but retains existing solid/palette/copy writes.
