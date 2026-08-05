# XdfViewer — a Quick Look extension for macOS

[![CI](https://github.com/nielsr2/macos-quicklook-xdf-viewer/actions/workflows/ci.yml/badge.svg)](https://github.com/nielsr2/macos-quicklook-xdf-viewer/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

<!-- Add a preview screenshot or GIF here — it makes a Quick Look tool much
     easier to grasp at a glance, e.g.:
![XdfViewer previewing an .xdf recording](docs/screenshot.png)
-->

A macOS **Quick Look** (press **Space** in Finder) preview + thumbnail extension
for **`.xdf`** files — the [Extensible Data Format](https://github.com/sccn/xdf)
used by [Lab Streaming Layer](https://labstreaminglayer.readthedocs.io/) (LSL)
and tools like LabRecorder to record synchronized, multi-modal experiment data.
One `.xdf` file can bundle several independently-timestamped **streams** —
EEG/ECG/EMG/EOG, eye-gaze, accelerometer/IMU, audio, video-frame metadata,
and free-form event/marker streams — each with its own channel count, sample
format, and (often irregular) sample rate.

It ships as a host app (`XdfViewer.app`) embedding its own preview + thumbnail
extensions, built from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## What the preview shows

- **Overview grid** — one card per stream: kind icon (EEG/ECG/EMG/EOG/GSR/
  accelerometer/gaze/markers/audio/video/mocap, with a generic fallback for
  unrecognized types), name, channel count, nominal sample rate, duration, and
  an inline **sparkline** of its most informative channel (the channel with
  the largest peak-to-peak range — some recordings only feed one of many
  declared channels, so always showing channel 0 would look flat for those).
  The overview renders immediately from a fast, sample-free structural pass
  over the file; sparklines fill in shortly after as a background decimation
  pass resolves per stream.
- **Full waveform view** — tap a stream card to open every channel in its own
  auto-scaled lane (a µV EEG channel and a normalized 0–1 gaze channel each
  fill their lane independently), with horizontal pan (drag) and zoom
  (pinch/magnification) over a single fixed-resolution envelope covering the
  whole stream.
- **Thumbnail provider** — Finder icon/list/gallery views get a compact
  stacked mini-envelope (up to 4 numeric streams).

Marker/event streams (single string-format channel, one label per event) are
decoded into timestamped labels for future use in the full waveform view;
overlaying them on the timeline is tracked as follow-on polish rather than
shipped yet in this pass — check `Sources/XdfViewerCore/Views/FullWaveformView.swift`
for current status. Minimap, crosshair readout, channel search, and
per-kind/per-channel color customization are likewise deferred past this MVP.

## Supported channel formats

XDF's `channel_format` is per-stream: `int8`, `int16`, `int32`, `int64`,
`float32`, `double64`, or `string`.

- The six numeric formats decode into min/max envelopes for sparklines and the
  full waveform view.
- `string`-format channels have no meaningful numeric envelope and are skipped
  there — but they **are** used for marker/event streams (XDF's convention:
  a single string channel, one value per event), decoded separately into
  timestamped labels.
- A stream with an unsupported/garbled format, or a decode failure partway
  through, degrades to a flat placeholder envelope rather than breaking the
  rest of the preview — one bad stream can't blank the whole file.

## Guardrails for pathological files

A preview extension has to stay fast and bounded no matter what a file
declares, so decimation work is capped in two places:

- **Per-stream:** `XdfEnvelopeReader.readEnvelopes` caps how many samples it
  will actually walk (5,000,000 by default). A stream that declares far more
  samples than that gets a uniformly-strided subset of its chunks decoded
  instead of every chunk — spread across the whole recording rather than just
  the start — trading envelope precision for a bounded, sub-second decode.
- **Per-file:** `XdfOverviewViewModel` caps how many streams get a real
  background decimation pass (32 by default); a file declaring more streams
  than that leaves the rest with a flat placeholder sparkline in the overview
  grid (tapping into any individual stream still decimates it fresh,
  unaffected by this cap). When this happens, a small "Truncated" indicator
  appears in the title bar with a tooltip explaining why.

## Targets

- `XdfViewerCore.framework` — the XDF binary parser, decimation, models, and
  SwiftUI views. Bundle ID `com.nielsr2.XdfViewerCore`.
- `XdfViewer.app` — a small host app (About + enable instructions). Bundle ID
  `com.nielsr2.XdfViewer`.
- `XdfViewer.app/Contents/PlugIns/XdfPreviewExtension.appex` — the
  `QLPreviewingController` preview. Bundle ID `com.nielsr2.XdfViewer.Preview`.
- `XdfViewer.app/Contents/PlugIns/XdfThumbnailExtension.appex` — the
  `QLThumbnailProvider` mini-envelope icon. Bundle ID `com.nielsr2.XdfViewer.Thumbnail`.
- `XdfViewerCoreTests` — unit tests for the binary parser and decimation
  guardrails, against hand-crafted `.xdf` byte fixtures.

`.xdf` has no system-declared UTI, so the host app exports one
(`com.nielsr2.xdf`, conforming to `public.data`, filename extension `xdf`) that
both extensions target — there's no competing native previewer for `.xdf`, so a
launched, enabled XdfViewer should win cleanly.

## Build & install

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The `.xcodeproj` (`XdfViewer.xcodeproj`) is generated
from `project.yml` and is git-ignored.

```bash
xcodegen generate
xcodebuild -project XdfViewer.xcodeproj -scheme XdfViewer -configuration Release build
# or: open XdfViewer.xcodeproj  and build the "XdfViewer" scheme
```

1. Copy `XdfViewer.app` to **`/Applications`** (or `~/Applications`).
2. **Launch it once.**
3. Open **System Settings → General → Login Items & Extensions → Quick Look** and
   **enable XdfViewer**.
4. Select an `.xdf` file in Finder and press **Space**.

Run the parser/decimation unit tests:

```bash
xcodebuild test -project XdfViewer.xcodeproj -scheme XdfViewerCoreTests -destination 'platform=macOS'
```

Debug via logging (the extension runs outside Xcode's debugger):

```bash
log stream --predicate 'subsystem == "com.nielsr2.XdfViewer"' --level debug
```

If a preview looks stale after rebuilding:

```bash
qlmanage -r cache && killall Finder
# See which extension is registered and from where:
pluginkit -mAvvv -p com.apple.quicklook.preview | grep -i xdfviewer
```

## Notes

The project is set up for **local/personal use**: ad-hoc code signing, App Sandbox
on, no network entitlement, no notarization. To distribute to others you'd add a
Developer ID identity + hardened runtime and notarize the app.

The parsing/decimation/rendering core has no UI dependencies, so it can be
exercised in isolation (decode → envelope/waveform → metadata) — the fastest
way to iterate on the renderer without going through Quick Look.

## License

Released under the [MIT License](LICENSE) © 2026 Niels Erik Raursø.
