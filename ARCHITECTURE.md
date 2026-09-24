# Working on Sharp

The app owns connection and process lifetime. It keeps its Ethernet control connection and heartbeat alive when you pause sharing. Pausing stops the screen and audio engines. Disconnecting clears the live peer state; a remembered device alone does not mean a cable connection exists.
Sleep stops both engines and blocks new sessions until wake. The awake peer also stops its engine when it receives a sleep notice or loses the control connection. Sharp keeps the sharing preference, then reconnects after wake.

`app/Diagnostics.swift` creates a single report with compatibility checks, link details, recent control events, engine output, and available log and crash excerpts. The control trace stays in memory when continuous logging is off.
`app/Benchmarks.swift` runs the bundled `tools/benchmark-scene.m` workloads on the streamed display and saves scene-tagged sender and receiver telemetry. Engine rates may be rolling or cumulative; a scene tag identifies when a sample was taken, not a scene-only aggregate.
Extend uses macOS's undocumented `CGVirtualDisplay` classes. Mirror does not depend on them; contributors should treat Extend as OS-version-sensitive.

## Source map

| Directory | Responsibility |
| --- | --- |
| `app/` | SwiftUI views, MainActor session state, discovery/control messages, helper processes and Core Audio routing |
| `src/core/` and `include/sharp/` | Portable C protocol, hybrid version state, tile codecs, framebuffer, packet queues and video reassembly |
| `src/sender/` | Capture, VideoToolbox encoding, hybrid scheduling, transport, feedback and virtual display setup |
| `src/receiver/` | Packet ingestion, decoding, frame ownership, hybrid acknowledgements and OpenGL presentation |
| `src/platform/` | Shared macOS cursor image handling |
| `tests/` | Hybrid, lossless tile, audio ring and app-state checks |
| `tools/` | Visual benchmark scenes used by the app |

The Objective-C files compile as separate translation units. Internal categories divide each engine by responsibility while retaining its existing state owner and synchronization. `Internal.h` is private to each executable. This extraction preserves the working queue/lock model; further ownership changes need their own review and checks. The older regional-motion compatibility path remains available.

## Rules to preserve

A displayed lossless tile must belong to the displayed capture. For video capture F, cached tile capture C and last-change version V, the core permits the overlay only when V ≤ C ≤ F under its wrap-aware ordering. Missing maps and unknown sessions leave video visible.

The receiver must present a complete current lossless snapshot before acknowledging video exit. Sending the last packet does not complete that transition. A newer capture supersedes an older pending settle.

Keep Core Audio callbacks free of allocation, network IO and locks. Stopping a route restores local sound but preserves the user's audio preference. Permission setup uses a short unmuted tap and does not claim that tap creation proves permission.

## Thread ownership

The Swift model and UI run on MainActor. Network callbacks return there before changing session state. Each engine owns its existing capture, encode, transport and render queues. Preserve the sender's send/timing locks and receiver's state/ring locks when moving operations across files. Decoder callbacks must recheck session identity before publishing pixels.

Keep wire changes compatible across both endpoints. Avoid adding another mode or tuning preference when the existing automatic policy covers the case.

Cursor edits use a `cursor-style` control message. The receiver app forwards bounded scale/hue commands to its running helper over stdin. The renderer updates only cursor state/textures under its OpenGL context lock; it does not reset video or session state.
