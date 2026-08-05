# XdfViewer

[![CI](https://github.com/nielsr2/macos-quicklook-xdf-viewer/actions/workflows/ci.yml/badge.svg)](https://github.com/nielsr2/macos-quicklook-xdf-viewer/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Preview **`.xdf`** recording files right in the macOS Finder — just select a file
and press **Space**. No need to launch a heavy analysis tool to see what's inside.

`.xdf` ([Extensible Data Format](https://github.com/sccn/xdf)) is the recording
format used by [Lab Streaming Layer](https://labstreaminglayer.readthedocs.io/)
(LSL) and LabRecorder to capture synchronized experiment data — EEG, ECG/EMG,
eye-gaze, motion/IMU, audio, event markers, and more — often many streams in a
single file.

![XdfViewer previewing an .xdf recording — a 37-channel EEG stream with per-channel
sparklines next to a marker/event stream](docs/preview-overview.png)

*Pressing Space on an EEG recording: a 37-channel EEG stream (right) with a live
sparkline per channel, alongside a marker/event stream (left).*

## Features

- **Instant Finder preview** — press Space on any `.xdf` file to see every stream
  at a glance: one card per stream with its type, channel count, sample rate,
  duration, and a live waveform sparkline.
- **Zoom into any stream** — click a stream to open its channels in a full
  waveform view you can pan and zoom (drag to scroll, pinch to zoom).
- **Finder thumbnails** — `.xdf` files show a mini waveform thumbnail in icon,
  list, and gallery views instead of a blank document icon.
- **Knows your signals** — EEG, ECG, EMG, EOG, GSR, accelerometer/IMU, eye-gaze,
  audio, video, motion-capture, and marker streams are recognized with their own
  icons; unfamiliar stream types still preview fine.
- **Fast and robust** — previews stay responsive even on huge or malformed files,
  and one bad stream never blanks the whole preview.

## Install

Requires macOS 14 (Sonoma) or later.

### Option A — Download (easiest)

1. Download the latest **`XdfViewer-vX.Y.Z.zip`** from the
   [Releases page](https://github.com/nielsr2/macos-quicklook-xdf-viewer/releases/latest)
   and unzip it.
2. Move **`XdfViewer.app`** into your **Applications** folder.
3. The app is open-source and ad-hoc signed (not notarized by Apple), so macOS
   quarantines the download. Clear the quarantine flag once:
   ```bash
   xattr -cr /Applications/XdfViewer.app
   ```
4. **Launch `XdfViewer.app` once** — this registers the Quick Look extensions.
5. Open **System Settings → General → Login Items & Extensions → Quick Look** and
   turn on **XdfViewer**.
6. Select any `.xdf` file in Finder and press **Space**.

### Option B — Build from source

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`):

```bash
xcodegen generate
xcodebuild -project XdfViewer.xcodeproj -scheme XdfViewer -configuration Release build
```

Then follow steps 4–6 above. (You can also `open XdfViewer.xcodeproj` and run the
**XdfViewer** scheme.)

## Using it

- **Press Space** on an `.xdf` file to open the overview.
- **Click a stream card** to open its channels, then **drag** to pan and **pinch**
  to zoom the waveforms.
- **Press Space** again (or Esc) to close.

![Full waveform view of a single EMG channel, with an overview minimap and zoom
controls](docs/waveform-view.png)

*Zoomed into a single EMG channel — the strip at the top is a whole-recording
minimap, and the slider zooms the main waveform.*

## Good to know

- **Stream types:** numeric streams (int8–int64, float32, double64) render as
  waveforms; string streams are shown as event/marker tracks. Unrecognized or
  partly-corrupt streams fall back to a flat placeholder instead of breaking the
  preview.
- **Very large or unusual files:** to keep previews snappy, the extension samples
  down enormous streams and limits how many it renders at once — a small
  "Truncated" note explains when this happens. Opening an individual stream always
  renders it fresh at full detail.
- **Not yet implemented:** marker overlays on the timeline, a minimap, crosshair
  value readout, channel search, and color customization.

## Troubleshooting

If a preview looks stale after reinstalling or rebuilding:

```bash
qlmanage -r cache && killall Finder
```

See which extension macOS has registered:

```bash
pluginkit -mAvvv -p com.apple.quicklook.preview | grep -i xdfviewer
```

Watch the extension's logs (it runs outside Xcode's debugger):

```bash
log stream --predicate 'subsystem == "com.nielsr2.XdfViewer"' --level debug
```

## Development

The project is built with [XcodeGen](https://github.com/yonaskolb/XcodeGen): the
`.xcodeproj` is generated from `project.yml` and is git-ignored, so run
`xcodegen generate` after cloning.

Targets:

- **XdfViewerCore** (framework) — the `.xdf` parser, waveform decimation, models,
  and SwiftUI views. Has no Quick Look/UI-host dependencies, so it can be
  exercised in isolation.
- **XdfViewer** (app) — a small host app (About + enable instructions) that embeds
  the two extensions.
- **XdfPreviewExtension** — the Quick Look preview (`QLPreviewingController`).
- **XdfThumbnailExtension** — the Finder thumbnail (`QLThumbnailProvider`).
- **XdfViewerCoreTests** — unit tests over hand-crafted `.xdf` byte fixtures.

Run the tests:

```bash
xcodebuild test -project XdfViewer.xcodeproj -scheme XdfViewerCoreTests -destination 'platform=macOS'
```

`.xdf` has no system-declared UTI, so the app exports one (`com.nielsr2.xdf`,
filename extension `xdf`) that both extensions target. The project uses ad-hoc
signing and the App Sandbox with no network access; shipping a notarized build
would require a Developer ID identity and hardened runtime.

Releases are automated: pushing a `vX.Y.Z` tag builds the app in CI and attaches
it to a matching GitHub Release.

## License

MIT — see [LICENSE](LICENSE). © 2026 Niels Erik Raursø.
