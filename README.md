# rootshellVNC

`rootshellVNC` is a native Swift VNC client for Apple platforms. It combines an
RFB protocol implementation, secure transports, Apple Screen Sharing support,
hardware-accelerated rendering, and a reusable SwiftUI remote-desktop UI.

This is the VNC package used by [rootshell](https://github.com/kitknox/rootshell),
the terminal app for iPhone, iPad, visionOS, and macOS. rootshell embeds this
package to provide remote graphical desktop access alongside its terminal and
SSH workflows. The rootshell repository remains the place for app-level
information and support; this repository contains the VNC implementation and a
small standalone viewer used to develop it.

## Features

### VNC and RFB

- RFB 3.3, 3.7, and 3.8 protocol negotiation, plus Apple's RFB extensions
- Raw, CopyRect, Zlib, ZRLE, Tight, Apple Adaptive DCT, and Apple HEVC display
  paths, selected according to the configured quality mode and server support
- Standard cursor, desktop-size, and extended-desktop-size extensions
- Configurable pixel format, encoding preference, and frame-request rate
- One display, combined physical displays, or two client-sized virtual displays
  on capable Apple servers

### Apple Screen Sharing

- High Performance mode with low-latency HEVC video over UDP
- Standard adaptive and lossless Full Quality modes over TCP
- Remote system audio with synchronized audio/video playback
- Match Client sizing and live display reconfiguration
- Apple precise scrolling and native gesture events, with portable RFB fallbacks
- Remote curtain control, shared clipboard integration, and Apple login-window
  detection with an explicit user-confirmed password-send flow

### Security and transport

- Classic VNC authentication
- Apple Remote Desktop authentication, including Apple DH and Mac/SRP flows
- VeNCrypt 0.2 with X.509 TLS and host-supplied certificate validation for
  trust-on-first-use policies
- Configurable security policy, including an encryption-required mode
- Direct TCP connections or a host-provided `RFBConnection`, allowing the
  package to run through an SSH direct-tcpip channel, tssh tunnel, or another
  application-owned transport
- Encrypted Apple control and media channels, including SRTP/SRTCP support

### Native client experience

- `VNCSession`, an observable high-level API for connection lifecycle, display
  state, input, clipboard, resizing, reconnection, and statistics
- Reusable `ConnectionView` and `RemoteDesktopView` SwiftUI components
- Touch input for pointer movement, clicking, dragging, scrolling, and gestures
- Software and hardware keyboard capture with host-reserved shortcut routing
- Zooming, panning, viewport controls, fullscreen integration, and keyboard-aware
  layout
- Automatic reconnection with bounded exponential backoff and jitter
- Protocol tracing, structured debug logging, connection diagnostics, and live
  session statistics

## Package structure

The Swift package lives in [`Packages/rootshellVNC`](Packages/rootshellVNC).

| Product | Responsibility |
| --- | --- |
| `rootshellVNC` | Public session API, SwiftUI views, input, clipboard, and diagnostics |
| `RFBProtocol` | RFB types, messages, state machine, and framebuffer encoding decoders |
| `RFBTransport` | TCP/UDP I/O, authentication, encryption, tunneling hooks, and Apple media negotiation |
| `RFBRendering` | Framebuffer composition, cursor rendering, VideoToolbox HEVC decoding, and remote audio |

The root Xcode project, `rootshell-vnc.xcodeproj`, is a lightweight standalone
viewer and integration harness for the package.

## Requirements

- Swift 6
- iOS 18 or later
- macOS 15 or later

The package uses system frameworks including SwiftUI, Network, VideoToolbox,
Core Media, and AVFoundation. Its external Swift dependencies are BigInt,
SwiftNIO, SwiftNIO SSL, and SwiftNIO Transport Services.

## Add the package to an app

This repository currently keeps its package manifest below the repository root.
Clone or vendor the repository, then add `Packages/rootshellVNC` as a local Swift
package in Xcode:

1. Choose **File → Add Package Dependencies**.
2. Choose **Add Local…**.
3. Select `Packages/rootshellVNC`.
4. Add the `rootshellVNC` product to the application target.

A neighboring Swift package can use the same checkout by path:

```swift
dependencies: [
    .package(
        name: "rootshellVNC",
        path: "../rootshell-vnc/Packages/rootshellVNC"
    ),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "rootshellVNC", package: "rootshellVNC"),
        ]
    ),
]
```

## Quick start

For a complete connection form and remote-desktop flow, create a session and
pass it to `ConnectionView`:

```swift
import SwiftUI
import rootshellVNC

@MainActor
struct VNCClientView: View {
    @State private var session = VNCSession()

    var body: some View {
        ConnectionView(session: session)
    }
}
```

For an app-owned connection flow, configure and connect the session directly,
then present `RemoteDesktopView`:

```swift
var configuration = VNCConfiguration(
    videoQualityMode: .adaptive,
    displaySizingMode: .matchClient
)
configuration.securityPolicy = .automatic

let session = VNCSession(configuration: configuration)

try await session.connect(
    credentials: VNCCredentials(
        host: "mac.example.com",
        password: "password",
        username: "username"
    )
)
```

```swift
RemoteDesktopView(session: session)
```

Use `.standard` for a reliable compressed TCP path on constrained, tunneled, or
UDP-hostile networks, and `.fullQuality` for lossless framebuffer updates on a
fast network. High Performance `.adaptive` mode requires direct UDP reachability
and is automatically unavailable when a custom transport provider is installed.

## Developing

Open `rootshell-vnc.xcodeproj` to run the standalone viewer, or build and test
the package from the command line:

```sh
cd Packages/rootshellVNC
swift test
```

The test suites cover protocol parsing and state transitions, authentication and
crypto, TCP/UDP transport behavior, Apple media negotiation and resiliency,
frame ordering and decoding, clipboard synchronization, viewport behavior, and
reconnection.

## Related project

- [rootshell](https://github.com/kitknox/rootshell) — the free,
  Metal-accelerated terminal app that uses this package
- [rootshell.com](https://www.rootshell.com) — downloads, screenshots, release
  notes, and documentation for the rootshell app
