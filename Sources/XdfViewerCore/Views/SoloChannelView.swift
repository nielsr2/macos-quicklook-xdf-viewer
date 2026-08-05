import SwiftUI
import AppKit

/// Single-channel full-window detail view — the third disclosure tier
/// (sparkline -> inline detail -> solo), matching the original WPF app's
/// `ShowFullChannel`/`FullView`. Reached by tapping an expanded channel row's
/// inline detail plot in `ChannelRowView`.
///
/// Layout: header (close, channel label/unit, amplitude control) ->
/// `MinimapView` (this channel's envelope, seekable) -> one large
/// `ChannelLaneView` filling the remaining height, with drag-pan,
/// cursor-anchored pinch-zoom, a hover crosshair readout and a
/// `MarkerOverlay` -> `TimeAxis`. Mirrors `FullWaveformView`'s interaction
/// model (pan/zoom math, hover-crosshair pattern, minimap/marker/time-axis
/// wiring) but for exactly one channel instead of every channel in the
/// stream, with an added vertical-amplitude control that
/// `FullWaveformView` doesn't need (every lane there auto-scales
/// independently and permanently; here the user can push the single lane's
/// scale beyond its own auto-fit).
public struct SoloChannelView: View {
    public let document: XdfDocument
    public let stream: XdfStreamInfo
    public let channelIndex: Int
    public let fileURL: URL
    public var onClose: () -> Void
    /// Shared across the preview session so switching channels / re-entering
    /// this view reuses a prior whole-stream decode instead of re-reading disk.
    public var envelopeCache: XdfEnvelopeCache

    @State private var envelope: XdfChannelEnvelope?
    @State private var isLoading: Bool

    @State private var markerEvents: [XdfMarkerEvent]
    @State private var markersLoaded: Bool

    @State private var manualOffset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var zoom: CGFloat = 1
    @State private var zoomGestureBase: CGFloat?
    /// Set once the first time `soloArea`'s `GeometryReader` reports a real
    /// size, so the initial `zoom` can be computed to fit the whole
    /// duration into the available width (start fully zoomed out, matching
    /// the minimap's implied full-range viewport) instead of the arbitrary
    /// fixed `basePointsPerSecond` density, which only happens to fit by
    /// coincidence depending on window width and recording length.
    @State private var didFitToWindow = false
    /// The zoom that exactly fits the whole recording into the viewport,
    /// recorded at first layout. For a long recording this is far below the
    /// fixed `minZoom` floor, so the floor is widened to it (see
    /// `effectiveMinZoom`) — otherwise "fully zoomed out" would still crop most
    /// of the recording and it could never be zoomed out to fit.
    @State private var fittedZoom: CGFloat?

    /// Local x (points, within the lane's `contentWidth`-sized frame) of the
    /// current mouse hover, or `nil` when the pointer isn't over the lane.
    /// Also doubles as the cursor-anchor for pinch-zoom, since
    /// `MagnificationGesture` alone reports no position.
    @State private var hoverX: CGFloat?

    @State private var amplitudeScale: CGFloat = 1

    /// Whether the right-edge events panel is expanded. Collapsed by default
    /// (only its toggle strip shows) so the plot keeps full width.
    @State private var eventsPanelExpanded = false

    /// Local monitor token for the Esc/Home/End keyboard-nav fallback (see
    /// `installKeyMonitor`). Installed on appear, removed on disappear.
    @State private var keyMonitor: Any?
    /// Local monitor token for trackpad scroll pan/zoom (see
    /// `installScrollMonitor`) — SwiftUI has no scroll-wheel gesture, so
    /// this bridges via `NSEvent`, same approach as the keyboard monitor.
    @State private var scrollMonitor: Any?
    /// Latest `avail` (plot width, minus the value-axis gutter) reported by
    /// `soloArea`'s `GeometryReader`, cached so the scroll monitor's closure
    /// — which runs outside the view body and has no access to `geo` — can
    /// compute the current content width/max offset on demand.
    @State private var cachedAvail: CGFloat = 0

    /// Horizontal density of the timeline at zoom == 1. Matches
    /// `FullWaveformView`'s constant so pinch-zoom feels the same across
    /// both views.
    private let basePointsPerSecond: CGFloat = 80
    private let minZoom: CGFloat = 0.1
    /// Lowest zoom the user can reach: the fixed floor, or the fit-the-whole-
    /// recording zoom when that is smaller (long recordings), so zooming all
    /// the way out always shows the entire stream.
    private var effectiveMinZoom: CGFloat { min(minZoom, fittedZoom ?? minZoom) }
    /// Higher ceiling than `FullWaveformView`'s (60): this is the "zoom in
    /// deep on one channel" view, and the column budget below
    /// (`columnBudget`, up to ~30,000) supports meaningfully more zoom depth
    /// than the multi-channel view's ~8,000-column pass before samples
    /// start visibly repeating.
    private let maxZoom: CGFloat = 200
    private let minAmplitude: CGFloat = 0.25
    private let maxAmplitude: CGFloat = 8

    /// Only used by previews/tests to inject hand-built envelope/marker data
    /// and bypass the real async load.
    public init(document: XdfDocument,
                stream: XdfStreamInfo,
                channelIndex: Int,
                fileURL: URL,
                envelopeCache: XdfEnvelopeCache = XdfEnvelopeCache(),
                previewEnvelope: XdfChannelEnvelope? = nil,
                previewMarkers: [XdfMarkerEvent]? = nil,
                onClose: @escaping () -> Void = {}) {
        self.document = document
        self.stream = stream
        self.channelIndex = channelIndex
        self.fileURL = fileURL
        self.envelopeCache = envelopeCache
        self.onClose = onClose
        _envelope = State(initialValue: previewEnvelope)
        _isLoading = State(initialValue: previewEnvelope == nil)
        _markerEvents = State(initialValue: previewMarkers ?? [])
        _markersLoaded = State(initialValue: previewMarkers != nil)
    }

    private var duration: Double {
        max(stream.duration ?? 0, 0)
    }

    private var channelLabel: String {
        if channelIndex < stream.channels.count, let label = stream.channels[channelIndex].label, !label.isEmpty {
            return label
        }
        return "Ch \(channelIndex + 1)"
    }

    private var channelUnit: String {
        guard channelIndex < stream.channels.count else { return "" }
        return stream.channels[channelIndex].unit ?? ""
    }

    /// Column budget for the one-shot whole-stream decode (see
    /// `loadEnvelope`): ~400 columns per second of duration,
    /// floored at 2,000 (so short recordings still get a reasonably fine
    /// envelope) and hard-capped at 30,000 (per the plan's "up to ~30,000
    /// columns" guidance) so a very long recording still decodes in a
    /// bounded, one-shot pass rather than becoming unbounded.
    private var columnBudget: Int {
        XdfEnvelopeReader.envelopeColumns(duration: duration, perSecond: 400,
                                          min: 2_000, max: 30_000)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: envelopeTaskID) {
            guard envelope == nil else { return }
            await loadEnvelope()
        }
        .task(id: fileURL) {
            guard !markersLoaded else { return }
            await loadMarkers()
        }
        .onAppear {
            installKeyMonitor()
            installScrollMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
            removeScrollMonitor()
        }
    }

    private var envelopeTaskID: String { "\(stream.streamID)-\(channelIndex)" }

    @ViewBuilder
    private var content: some View {
        if let envelope {
            HStack(spacing: 0) {
                soloArea(envelope: envelope)
                if showEventsPanel {
                    TimelineEventsPanel(events: markerEvents,
                                        streamStartTimestamp: stream.firstTimestamp ?? 0,
                                        isExpanded: $eventsPanelExpanded,
                                        onSelect: centerOnEvent)
                }
            }
        } else if isLoading {
            ProgressView("Decoding \(channelLabel)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("No channel data available")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Label("Close", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Divider().frame(height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(channelLabel)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !channelUnit.isEmpty {
                    Text(channelUnit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            amplitudeControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var amplitudeControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.and.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(action: { amplitudeScale = max(minAmplitude, amplitudeScale / 1.5) }) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            Slider(value: $amplitudeScale, in: minAmplitude...maxAmplitude)
                .frame(width: 100)
            Button(action: { amplitudeScale = min(maxAmplitude, amplitudeScale * 1.5) }) {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            Text(String(format: "×%.2g", amplitudeScale))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }

    // MARK: Solo area (minimap + pan/zoom lane + crosshair + axis)

    /// Width of the leading `ValueAxis` gutter — the plot area (`avail`)
    /// is everything left over after this, so pan/zoom math stays in terms
    /// of the actual waveform width, not the full view width.
    private let valueAxisWidth: CGFloat = 64

    @ViewBuilder
    private func soloArea(envelope: XdfChannelEnvelope) -> some View {
        GeometryReader { geo in
            let avail = max(geo.size.width - valueAxisWidth, 1)
            let pointsPerSecond = basePointsPerSecond * zoom
            let contentWidth = max(avail, CGFloat(max(duration, 0.001)) * pointsPerSecond)
            let maxOffset = max(0, contentWidth - avail)
            let offset = min(maxOffset, max(0, manualOffset))

            VStack(spacing: 6) {
                if duration > 0 {
                    MinimapView(envelope: envelope,
                                viewportRange: viewportRange(avail: avail, contentWidth: contentWidth, offset: offset),
                                onSeek: { fraction in
                                    let target = CGFloat(fraction) * contentWidth - avail / 2
                                    manualOffset = min(maxOffset, max(0, target))
                                })
                        .padding(.leading, valueAxisWidth + 12)
                        .padding(.trailing, 12)
                        .padding(.top, 4)
                }

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ValueAxis(envelope: envelope, amplitudeScale: amplitudeScale, unit: channelUnit)
                            .frame(width: valueAxisWidth)

                        ZStack(alignment: .topLeading) {
                            // Lane is sized to the visible viewport (`avail`),
                            // NOT `contentWidth`, and draws only the visible
                            // column slice — the windowed-rendering zoom-crash
                            // fix. See `ChannelLaneView.visibleFraction`.
                            // `hoverX` is NOT passed into the lane — the crosshair
                            // is a separate cheap overlay below, so a pointer move
                            // doesn't re-stroke this (up to 30k-column) lane.
                            ChannelLaneView(envelope: envelope,
                                             label: channelLabel,
                                             amplitudeScale: amplitudeScale,
                                             showValueGridlines: true,
                                             visibleFraction: viewportRange(avail: avail, contentWidth: contentWidth, offset: offset))
                                .frame(width: avail)
                                .frame(maxHeight: .infinity)
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        hoverX = location.x
                                    case .ended:
                                        hoverX = nil
                                    }
                                }

                            MarkerOverlay(markers: markerEvents,
                                          streamStartTimestamp: stream.firstTimestamp ?? 0,
                                          pointsPerSecond: pointsPerSecond,
                                          offset: offset)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            // Shared hover crosshair — reads only `hoverX`, so a
                            // pointer move redraws just this line, not the lane.
                            if let hoverX {
                                Canvas { ctx, size in
                                    var line = Path()
                                    line.move(to: CGPoint(x: hoverX, y: 0))
                                    line.addLine(to: CGPoint(x: hoverX, y: size.height))
                                    ctx.stroke(line, with: .color(.primary.opacity(0.5)), lineWidth: 1)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .allowsHitTesting(false)
                            }
                        }
                        .frame(width: avail)
                        .clipped()
                        .contentShape(Rectangle())
                        .gesture(panGesture(maxOffset: maxOffset))
                        .simultaneousGesture(magnificationGesture(avail: avail, duration: duration, offset: offset))
                        .onChange(of: contentWidth) { _, newWidth in
                            let newMaxOffset = max(0, newWidth - avail)
                            manualOffset = min(newMaxOffset, max(0, manualOffset))
                        }
                        .overlay(alignment: .topTrailing) {
                            crosshairReadout(envelope: envelope, contentWidth: contentWidth, offset: offset)
                                .padding(8)
                        }
                    }

                    Divider()
                    HStack(spacing: 0) {
                        Color.clear.frame(width: valueAxisWidth, height: 22)
                        TimeAxis(duration: duration, contentWidth: contentWidth, visibleWidth: avail, offset: offset)
                            .frame(width: avail, height: 22)
                    }
                }
            }
            .onAppear {
                cachedAvail = avail
                guard !didFitToWindow, duration > 0, avail > 0 else { return }
                didFitToWindow = true
                let fitZoom = avail / (CGFloat(duration) * basePointsPerSecond)
                fittedZoom = fitZoom
                // Open fully zoomed out (the whole recording). `fitZoom` is by
                // definition the fully-out zoom, so just clamp the top end.
                zoom = min(maxZoom, fitZoom)
            }
            .onChange(of: avail) { _, newValue in
                cachedAvail = newValue
            }
        }
    }

    /// Current pan/zoom window as a 0...1 fraction of the total duration,
    /// for `MinimapView`'s viewport rectangle. Identical math to
    /// `FullWaveformView.viewportRange`.
    private func viewportRange(avail: CGFloat, contentWidth: CGFloat, offset: CGFloat) -> ClosedRange<Double> {
        guard contentWidth > 0 else { return 0...1 }
        let lower = min(max(Double(offset / contentWidth), 0), 1)
        let upper = min(max(Double((offset + avail) / contentWidth), lower), 1)
        return lower...max(lower, upper)
    }

    /// Hover crosshair readout: current timestamp plus the nearest-column
    /// value under the pointer. `nil` (renders nothing) when the pointer
    /// isn't hovering the lane.
    @ViewBuilder
    private func crosshairReadout(envelope: XdfChannelEnvelope, contentWidth: CGFloat, offset: CGFloat) -> some View {
        if let hoverX, contentWidth > 0 {
            let cols = envelope.columnCount
            // `hoverX` is now a viewport-local coordinate (the lane is sized to
            // `avail`, not `contentWidth`), so convert through `offset`.
            let fraction = Double(min(max((offset + hoverX) / contentWidth, 0), 1))
            let time = fraction * duration
            let col = cols > 0 ? min(cols - 1, max(0, Int(fraction * Double(cols)))) : 0
            let value = cols > 0 ? (envelope.mins[col] + envelope.maxs[col]) / 2 : 0

            VStack(alignment: .trailing, spacing: 2) {
                Text(TimeAxis.formatTime(time))
                    .font(.caption.monospacedDigit())
                Text("\(String(format: "%.3g", value))\(channelUnit.isEmpty ? "" : " \(channelUnit)")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .allowsHitTesting(false)
        }
    }

    private func panGesture(maxOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard maxOffset > 0 else { return }
                if dragStartOffset == 0 { dragStartOffset = manualOffset }
                manualOffset = min(maxOffset, max(0, dragStartOffset - value.translation.width))
            }
            .onEnded { _ in dragStartOffset = 0 }
    }

    /// Cursor-anchored pinch-zoom: `MagnificationGesture` alone only reports
    /// a scale delta, not a pointer position, so the time under `hoverX`
    /// (falling back to the viewport's horizontal center when the pointer
    /// isn't hovering, e.g. zooming via trackpad without a tracked mouse
    /// position) is kept visually fixed by solving for the new offset:
    /// `newOffset = (hoverX + offset) * (newContentWidth / oldContentWidth) - hoverX`.
    private func magnificationGesture(avail: CGFloat, duration: Double, offset: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if zoomGestureBase == nil { zoomGestureBase = zoom }
                let base = zoomGestureBase ?? zoom
                let newZoom = min(maxZoom, max(effectiveMinZoom, base * value))
                guard newZoom != zoom else { return }

                let oldPointsPerSecond = basePointsPerSecond * zoom
                let newPointsPerSecond = basePointsPerSecond * newZoom
                let oldContentWidth = max(avail, CGFloat(max(duration, 0.001)) * oldPointsPerSecond)
                let newContentWidth = max(avail, CGFloat(max(duration, 0.001)) * newPointsPerSecond)

                let anchor = hoverX ?? avail / 2
                let newOffset = (anchor + offset) * (newContentWidth / oldContentWidth) - anchor
                let newMaxOffset = max(0, newContentWidth - avail)

                zoom = newZoom
                manualOffset = min(newMaxOffset, max(0, newOffset))
            }
            .onEnded { _ in zoomGestureBase = nil }
    }

    // MARK: Events panel (collapsible, click-to-center)

    /// The events panel is only mappable to the timeline when the stream has a
    /// real time zero and there are markers to show — mirroring the Windows
    /// original, which suppresses the events pane on the same condition.
    private var showEventsPanel: Bool {
        stream.firstTimestamp != nil && !markerEvents.isEmpty
    }

    /// Centre the plot on `event`'s time, keeping the current zoom. Uses the
    /// cached plot width (`cachedAvail`, already net of the value-axis gutter)
    /// so it can run from the panel's click handler outside the
    /// `GeometryReader`.
    private func centerOnEvent(_ event: XdfMarkerEvent) {
        let avail = cachedAvail
        guard avail > 0, duration > 0 else { return }
        let relSec = event.timestamp - (stream.firstTimestamp ?? 0)
        guard relSec.isFinite else { return }
        let pointsPerSecond = basePointsPerSecond * zoom
        let contentWidth = max(avail, CGFloat(max(duration, 0.001)) * pointsPerSecond)
        let maxOffset = max(0, contentWidth - avail)
        let target = CGFloat(relSec) * pointsPerSecond - avail / 2
        manualOffset = min(maxOffset, max(0, target))
    }

    // MARK: Envelope loading (Phase B: approximate, one-shot whole-stream decode)

    /// Decodes the whole stream once (every channel — `XdfSampleDecoder` must
    /// parse them all per sample just to advance the cursor, so there is no
    /// cheaper single-channel path) through `envelopeCache`, then extracts this
    /// channel's envelope. Keying the cache on `(streamID, columns)` — not on
    /// the channel — means opening a *different* channel of the same stream is
    /// an instant cache hit instead of a fresh whole-stream decode.
    private func loadEnvelope() async {
        isLoading = true
        let columns = columnBudget
        let doc = document
        let streamInfo = stream
        let url = fileURL
        let all = await envelopeCache.envelopes(streamID: streamInfo.streamID, columns: columns) {
            let chunks = doc.chunks(forStream: streamInfo.streamID)
            let totalSampleCount = streamInfo.sampleCount ?? chunks.totalDeclaredSampleCount
            return XdfEnvelopeReader.readEnvelopes(url: url,
                                                    chunks: chunks,
                                                    channelCount: streamInfo.channelCount,
                                                    channelFormat: streamInfo.channelFormat,
                                                    totalSampleCount: totalSampleCount,
                                                    columns: columns)
        }
        if Task.isCancelled { return }
        envelope = (channelIndex >= 0 && channelIndex < all.count) ? all[channelIndex] : .flat(columns: columns)
        isLoading = false
    }

    // MARK: Markers (shared file-level marker load, same as FullWaveformView)

    private func loadMarkers() async {
        let events = await XdfFileMarkerLoader.loadMarkers(document: document, fileURL: fileURL)
        if Task.isCancelled { return }
        markerEvents = events
        markersLoaded = true
    }

    // MARK: Keyboard nav (Esc closes, Home/End jump to start/end)

    /// `.onKeyPress` (SwiftUI, macOS 14+) needs the view to actually hold
    /// first responder / SwiftUI focus, which is unreliable inside a Quick
    /// Look extension's `QLPreviewingController`-hosted `NSHostingView` (the
    /// panel's own window/responder management doesn't reliably hand focus
    /// down into an arbitrary SwiftUI subview). An `NSEvent` local monitor
    /// intercepts key-down events for the app's own windows regardless of
    /// which view currently has SwiftUI focus, so it works the same whether
    /// this view is hosted in the Quick Look panel or the standalone
    /// `XdfHostApp` viewer window — this is the fallback the plan calls out,
    /// used here as the primary (and only) mechanism rather than layered on
    /// top of `.onKeyPress`, to avoid two competing/conflicting handlers for
    /// the same keys.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: // Esc
                onClose()
                return nil
            case 115: // Home
                manualOffset = 0
                return nil
            case 119: // End
                // Render-time clamping (`offset = min(maxOffset, ...)` in
                // `soloArea`) resolves this against whatever `maxOffset`
                // turns out to be at the current zoom, without needing the
                // monitor to know the current viewport geometry.
                manualOffset = .greatestFiniteMagnitude
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    // MARK: Trackpad scroll (pan / Shift-zoom)

    /// SwiftUI has no scroll-wheel gesture, so trackpad/mouse scroll pan and
    /// zoom are bridged via an `NSEvent` local monitor — same approach as
    /// `installKeyMonitor`. Scoped to "cursor is over the plot" by checking
    /// `hoverX` (set by the lane's `onContinuousHover`, `nil` when the
    /// pointer is elsewhere) so this never steals scroll events meant for
    /// other views/windows; events are passed through unconsumed otherwise.
    /// Matches the original plugin's documented controls ("scroll = pan,
    /// Shift = zoom").
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard hoverX != nil, cachedAvail > 0 else { return event }

            if event.modifierFlags.contains(.shift) {
                applyScrollZoom(deltaY: event.scrollingDeltaY)
            } else {
                let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
                let maxOffset = max(0, currentContentWidth() - cachedAvail)
                manualOffset = min(maxOffset, max(0, manualOffset - delta))
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
    }

    private func currentContentWidth() -> CGFloat {
        max(cachedAvail, CGFloat(max(duration, 0.001)) * basePointsPerSecond * zoom)
    }

    /// Shift+scroll zoom, cursor-anchored exactly like pinch-zoom (same
    /// formula as `magnificationGesture`) — `deltaY` drives the zoom factor
    /// so scrolling "up" zooms in, matching common trackpad zoom
    /// conventions (Maps, Photoshop, etc.).
    private func applyScrollZoom(deltaY: CGFloat) {
        let oldContentWidth = currentContentWidth()
        let sensitivity: CGFloat = 0.02
        let newZoom = min(maxZoom, max(effectiveMinZoom, zoom * (1 + deltaY * sensitivity)))
        guard newZoom != zoom, oldContentWidth > 0 else { return }

        let newContentWidth = max(cachedAvail, CGFloat(max(duration, 0.001)) * basePointsPerSecond * newZoom)
        let anchor = hoverX ?? cachedAvail / 2
        let oldMaxOffset = max(0, oldContentWidth - cachedAvail)
        let oldOffset = min(oldMaxOffset, max(0, manualOffset))
        let newOffset = (anchor + oldOffset) * (newContentWidth / oldContentWidth) - anchor
        let newMaxOffset = max(0, newContentWidth - cachedAvail)

        zoom = newZoom
        manualOffset = min(newMaxOffset, max(0, newOffset))
    }
}

#Preview {
    let stream = XdfStreamInfo(streamID: 1,
                                name: "EEG-Sensor-1",
                                type: "EEG",
                                channelCount: 4,
                                nominalSampleRate: 256,
                                channelFormat: .float32,
                                channels: [
                                    XdfChannelInfo(label: "Fp1", unit: "microvolts", type: "EEG"),
                                    XdfChannelInfo(label: "Fp2", unit: "microvolts", type: "EEG"),
                                    XdfChannelInfo(label: "Cz", unit: "microvolts", type: "EEG"),
                                    XdfChannelInfo(label: "Gaze-x", unit: "normalized", type: "Gaze"),
                                ],
                                firstTimestamp: 0,
                                lastTimestamp: 30,
                                sampleCount: 7680,
                                effectiveSampleRate: 256.1)

    // Mock marker stream — mirrors the shape `XdfFileMarkerLoader` expects
    // (single-channel, string-format). Its chunk data is never actually
    // decoded in the preview since `previewMarkers` bypasses the load.
    let markerStream = XdfStreamInfo(streamID: 2,
                                      name: "Session-Markers",
                                      type: "Markers",
                                      channelCount: 1,
                                      nominalSampleRate: 0,
                                      channelFormat: .string,
                                      channels: [XdfChannelInfo(label: "marker", unit: nil, type: "Markers")],
                                      firstTimestamp: 0,
                                      lastTimestamp: 30,
                                      sampleCount: 6,
                                      effectiveSampleRate: nil)

    let document = XdfDocument(version: "1.0", streams: [stream, markerStream], chunkIndex: [])

    let cols = 512
    var mins = [Float](repeating: 0, count: cols)
    var maxs = [Float](repeating: 0, count: cols)
    for i in 0..<cols {
        let v = sin(Float(i) / 9) * 40 + sin(Float(i) / 1.7) * 6
        mins[i] = v - 4
        maxs[i] = v + 4
    }
    let envelope = XdfChannelEnvelope(mins: mins, maxs: maxs)

    let markers: [XdfMarkerEvent] = [
        XdfMarkerEvent(timestamp: 1.5, label: "trial_start"),
        XdfMarkerEvent(timestamp: 6.25, label: "stimulus_on"),
        XdfMarkerEvent(timestamp: 6.4, label: "fixation"),
        XdfMarkerEvent(timestamp: 14.0, label: "trial_end"),
        XdfMarkerEvent(timestamp: 22.0, label: "block_2_start_with_a_long_label"),
    ]

    return SoloChannelView(document: document,
                            stream: stream,
                            channelIndex: 0,
                            fileURL: URL(fileURLWithPath: "/tmp/mock.xdf"),
                            previewEnvelope: envelope,
                            previewMarkers: markers)
        .frame(width: 780, height: 480)
}
