import SwiftUI
import AppKit

/// Multi-channel detail view for one selected stream: every channel stacked
/// in its own lane, each auto-scaled to its own min/max range (a µV EEG
/// channel and a normalized 0-1 gaze channel each fill their lane
/// independently — there is no shared/global Y-scale). Supports horizontal
/// pan (drag) and horizontal zoom (pinch/magnification) over a single
/// fixed-resolution decimation pass covering the whole stream duration.
///
/// Stage 5 polish adds: a marker/event overlay (`MarkerOverlay`, sourced from
/// any single-channel string-format stream in `document`), a hover crosshair
/// with a nearest-column value readout, a whole-recording `MinimapView`, and
/// a channel label search filter. Still no multi-resolution level-of-detail
/// pyramid — that remains out of scope.
public struct FullWaveformView: View {
    public let document: XdfDocument
    public let stream: XdfStreamInfo
    public let fileURL: URL
    public var onBack: () -> Void
    /// Shared across the preview session so re-entering this view (or having
    /// already visited a channel's solo view at the same column budget) reuses
    /// a prior whole-stream decode instead of re-reading disk.
    public var envelopeCache: XdfEnvelopeCache

    @State private var channelEnvelopes: [XdfChannelEnvelope]?
    @State private var isLoading = true

    @State private var markerEvents: [XdfMarkerEvent] = []
    @State private var markersLoaded = false

    @State private var manualOffset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var zoom: CGFloat = 1
    @State private var zoomGestureBase: CGFloat?
    /// Set once the first time `waveformArea`'s `GeometryReader` reports a
    /// real size, so the initial `zoom` can be computed to fit the whole
    /// duration into the available width (start fully zoomed out, matching
    /// the minimap's implied full-range viewport) instead of the arbitrary
    /// fixed `basePointsPerSecond` density.
    @State private var didFitToWindow = false
    /// The zoom that exactly fits the whole recording into the viewport. For a
    /// long recording this is far below the fixed `minZoom`, so the floor is
    /// widened to it (see `effectiveMinZoom`) — otherwise "fully zoomed out"
    /// still crops most of the recording and it can't be zoomed out to fit.
    @State private var fittedZoom: CGFloat?

    /// Local x (points, within a lane's `contentWidth`-sized frame) of the
    /// current mouse hover, or `nil` when the pointer isn't over any lane.
    /// All lanes share the same width/offset, so one value positions the
    /// crosshair line across every lane.
    @State private var hoverX: CGFloat?
    @State private var hoverLaneIndex: Int?

    @State private var searchText: String = ""

    /// Derived state, recomputed only when the envelopes load or the search
    /// text changes — NOT on every body re-evaluation. The view body is
    /// re-evaluated on every pan/zoom/hover tick; recomputing
    /// `mostInformative()` (O(channels)) and the filtered index list (plus its
    /// allocation) inline on each of those was pure waste. See `refreshDerived`.
    @State private var minimapEnvelope: XdfChannelEnvelope?
    @State private var visibleIndices: [Int] = []

    /// Whether the right-edge events panel is expanded. Collapsed by default
    /// (only its toggle strip shows) so the plot keeps full width.
    @State private var eventsPanelExpanded = false

    /// Local monitor token for trackpad scroll pan/zoom (see
    /// `installScrollMonitor`) — SwiftUI has no scroll-wheel gesture, so
    /// this bridges via `NSEvent`.
    @State private var scrollMonitor: Any?
    /// Latest `avail` reported by `waveformArea`'s `GeometryReader`, cached
    /// so the scroll monitor's closure (which runs outside the view body)
    /// can compute the current content width/max offset on demand.
    @State private var cachedAvail: CGFloat = 0

    /// Horizontal density of the timeline at zoom == 1.
    private let basePointsPerSecond: CGFloat = 80
    private let minZoom: CGFloat = 0.1
    /// Lowest reachable zoom: the fixed floor, or the fit-the-whole-recording
    /// zoom when smaller, so zooming all the way out always shows the whole
    /// stream (a long recording's fit zoom is well below `minZoom`).
    private var effectiveMinZoom: CGFloat { min(minZoom, fittedZoom ?? minZoom) }
    private let maxZoom: CGFloat = 60
    /// Fixed height per channel lane.
    private let laneHeight: CGFloat = 56

    /// Only used by previews/tests to inject hand-built envelope/marker data
    /// and bypass the real async decimation/decode passes.
    public init(document: XdfDocument,
                stream: XdfStreamInfo,
                fileURL: URL,
                envelopeCache: XdfEnvelopeCache = XdfEnvelopeCache(),
                previewEnvelopes: [XdfChannelEnvelope]? = nil,
                previewMarkers: [XdfMarkerEvent]? = nil,
                onBack: @escaping () -> Void = {}) {
        self.document = document
        self.stream = stream
        self.fileURL = fileURL
        self.envelopeCache = envelopeCache
        self.onBack = onBack
        _channelEnvelopes = State(initialValue: previewEnvelopes)
        _isLoading = State(initialValue: previewEnvelopes == nil)
        _markerEvents = State(initialValue: previewMarkers ?? [])
        _markersLoaded = State(initialValue: previewMarkers != nil)
    }

    private var duration: Double {
        max(stream.duration ?? 0, 0)
    }

    /// Recomputes `visibleIndices` (the search-filtered channel list) — cheap,
    /// O(channels), but done only on load / search change rather than per body
    /// tick. Empty search text matches everything.
    private func computeVisibleIndices() -> [Int] {
        let count = channelEnvelopes?.count ?? 0
        guard count > 0 else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(0..<count) }
        return (0..<count).filter { channelLabel(at: $0).localizedCaseInsensitiveContains(query) }
    }

    /// Refreshes both memoized derivations from the current envelopes + search.
    private func refreshDerived() {
        minimapEnvelope = channelEnvelopes?.mostInformative()
        visibleIndices = computeVisibleIndices()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: stream.streamID) {
            guard channelEnvelopes == nil else { return }
            await loadEnvelopes()
        }
        .task(id: fileURL) {
            guard !markersLoaded else { return }
            await loadMarkers()
        }
        .onAppear {
            installScrollMonitor()
            refreshDerived()
        }
        .onChange(of: searchText) { _, _ in visibleIndices = computeVisibleIndices() }
        .onDisappear { removeScrollMonitor() }
    }

    @ViewBuilder
    private var content: some View {
        if let channelEnvelopes, !channelEnvelopes.isEmpty {
            HStack(spacing: 0) {
                waveformArea(envelopes: channelEnvelopes)
                if showEventsPanel {
                    TimelineEventsPanel(events: markerEvents,
                                        streamStartTimestamp: stream.firstTimestamp ?? 0,
                                        isExpanded: $eventsPanelExpanded,
                                        onSelect: centerOnEvent)
                }
            }
        } else if isLoading {
            ProgressView("Decimating \(stream.channelCount) channel\(stream.channelCount == 1 ? "" : "s")…")
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
            Button(action: onBack) {
                Label("Overview", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Divider().frame(height: 16)
            Image(systemName: StreamKindClassifier.classify(type: stream.type).iconSystemName)
                .foregroundStyle(Color(nsColor: .controlAccentColor))
            Text(stream.name.isEmpty ? "Untitled stream" : stream.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if stream.channelCount > 1 {
                channelSearchField
            }
            Text(channelCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var channelSearchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("Filter channels", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 110)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
    }

    private var channelCountLabel: String {
        let total = channelEnvelopes?.count ?? stream.channelCount
        let shown = visibleIndices.count
        if shown != total {
            return "\(shown)/\(total) ch"
        }
        return "\(total) ch"
    }

    // MARK: Waveform area (pan + zoom + per-channel auto-scale lanes)

    @ViewBuilder
    private func waveformArea(envelopes: [XdfChannelEnvelope]) -> some View {
        GeometryReader { geo in
            let avail = max(geo.size.width, 1)
            let pointsPerSecond = basePointsPerSecond * zoom
            let contentWidth = max(avail, CGFloat(max(duration, 0.001)) * pointsPerSecond)
            let maxOffset = max(0, contentWidth - avail)
            let offset = min(maxOffset, max(0, manualOffset))

            VStack(spacing: 6) {
                if duration > 0, let minimapEnvelope {
                    MinimapView(envelope: minimapEnvelope,
                                viewportRange: viewportRange(avail: avail, contentWidth: contentWidth, offset: offset),
                                onSeek: { fraction in
                                    let target = CGFloat(fraction) * contentWidth - avail / 2
                                    manualOffset = min(maxOffset, max(0, target))
                                })
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }

                VStack(spacing: 0) {
                    if visibleIndices.isEmpty {
                        Text(searchText.isEmpty ? "No channel data available" : "No channels match “\(searchText)”")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        let visibleFraction = viewportRange(avail: avail, contentWidth: contentWidth, offset: offset)
                        ZStack(alignment: .topLeading) {
                            ScrollView(.vertical, showsIndicators: visibleIndices.count > 6) {
                                // Lazy so only the on-screen lanes are built &
                                // laid out — now meaningful because each lane is
                                // viewport-sized (windowed rendering), not a
                                // giant contentWidth frame.
                                LazyVStack(spacing: 1) {
                                    ForEach(visibleIndices, id: \.self) { index in
                                        // Lane is sized to the visible viewport
                                        // (`avail`), NOT `contentWidth`, and draws
                                        // only the visible column slice — this is
                                        // the windowed-rendering zoom-crash fix.
                                        // `hoverX` is deliberately NOT passed: the
                                        // crosshair is one shared overlay below, so
                                        // moving the pointer doesn't re-stroke every
                                        // lane's Canvas.
                                        ChannelLaneView(envelope: envelopes[index],
                                                         label: channelLabel(at: index),
                                                         visibleFraction: visibleFraction)
                                            .frame(width: avail, height: laneHeight)
                                            .onContinuousHover { phase in
                                                switch phase {
                                                case .active(let location):
                                                    hoverX = location.x
                                                    hoverLaneIndex = index
                                                case .ended:
                                                    if hoverLaneIndex == index {
                                                        hoverX = nil
                                                        hoverLaneIndex = nil
                                                    }
                                                }
                                            }
                                    }
                                }
                                .frame(width: avail, alignment: .leading)
                            }
                            .clipped()

                            MarkerOverlay(markers: markerEvents,
                                          streamStartTimestamp: stream.firstTimestamp ?? 0,
                                          pointsPerSecond: pointsPerSecond,
                                          offset: offset)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            // One shared hover crosshair across all lanes. A
                            // Canvas that reads only `hoverX`, so a pointer move
                            // redraws just this line — not the lanes.
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
                    }

                    Divider()
                    TimeAxis(duration: duration, contentWidth: contentWidth, visibleWidth: avail, offset: offset)
                        .frame(width: avail, height: 22)
                }
                .contentShape(Rectangle())
                .gesture(panGesture(maxOffset: maxOffset))
                .simultaneousGesture(magnificationGesture)
                .onChange(of: contentWidth) { _, newWidth in
                    let newMaxOffset = max(0, newWidth - avail)
                    manualOffset = min(newMaxOffset, max(0, manualOffset))
                }
                .overlay(alignment: .topTrailing) {
                    crosshairReadout(envelopes: envelopes, contentWidth: contentWidth, offset: offset)
                        .padding(8)
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

    /// Current pan/zoom window as a 0...1 fraction of the total duration, for `MinimapView`'s viewport rectangle.
    private func viewportRange(avail: CGFloat, contentWidth: CGFloat, offset: CGFloat) -> ClosedRange<Double> {
        guard contentWidth > 0 else { return 0...1 }
        let lower = min(max(Double(offset / contentWidth), 0), 1)
        let upper = min(max(Double((offset + avail) / contentWidth), lower), 1)
        return lower...max(lower, upper)
    }

    /// Hover crosshair readout: current timestamp plus the nearest-column
    /// value for whichever lane the pointer is over. `nil` (renders nothing)
    /// when the pointer isn't hovering any lane.
    @ViewBuilder
    private func crosshairReadout(envelopes: [XdfChannelEnvelope], contentWidth: CGFloat, offset: CGFloat) -> some View {
        if let hoverX, let hoverLaneIndex, hoverLaneIndex < envelopes.count, contentWidth > 0 {
            let envelope = envelopes[hoverLaneIndex]
            let cols = envelope.columnCount
            // `hoverX` is now a viewport-local coordinate (the lane is sized to
            // `avail`, not `contentWidth`), so convert through `offset`.
            let fraction = Double(min(max((offset + hoverX) / contentWidth, 0), 1))
            let time = fraction * duration
            let col = cols > 0 ? min(cols - 1, max(0, Int(fraction * Double(cols)))) : 0
            let value = cols > 0 ? (envelope.mins[col] + envelope.maxs[col]) / 2 : 0
            let unit = hoverLaneIndex < stream.channels.count ? (stream.channels[hoverLaneIndex].unit ?? "") : ""

            VStack(alignment: .trailing, spacing: 2) {
                Text(TimeAxis.formatTime(time))
                    .font(.caption.monospacedDigit())
                Text("\(channelLabel(at: hoverLaneIndex)): \(String(format: "%.3g", value))\(unit.isEmpty ? "" : " \(unit)")")
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

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let base = zoomGestureBase ?? zoom
                if zoomGestureBase == nil { zoomGestureBase = zoom }
                zoom = min(maxZoom, max(effectiveMinZoom, base * value))
            }
            .onEnded { _ in zoomGestureBase = nil }
    }

    private func channelLabel(at index: Int) -> String {
        if index < stream.channels.count, let label = stream.channels[index].label, !label.isEmpty {
            return label
        }
        return "Ch \(index + 1)"
    }

    // MARK: Events panel (collapsible, click-to-center)

    /// The events panel is only mappable to the timeline when the stream has a
    /// real time zero and there are markers to show — mirroring the Windows
    /// original, which suppresses the events pane on the same condition.
    private var showEventsPanel: Bool {
        stream.firstTimestamp != nil && !markerEvents.isEmpty
    }

    /// Centre the plot on `event`'s time, keeping the current zoom. Uses the
    /// cached viewport width (`cachedAvail`) so it can run from the panel's
    /// click handler outside the `GeometryReader`.
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

    // MARK: Decimation (Stage 3: single fixed-resolution pass, off-main)

    private func loadEnvelopes() async {
        isLoading = true

        let url = fileURL
        let streamInfo = stream
        let doc = document
        let d = duration
        // Mirrors AudioViewerModel's targetColumns shape (~120 columns/sec,
        // clamped to a sane range) rather than inventing new constants.
        let columns = XdfEnvelopeReader.envelopeColumns(duration: d, perSecond: 120,
                                                        min: 600, max: 8000)

        let envelopes = await envelopeCache.envelopes(streamID: streamInfo.streamID, columns: columns) {
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
        channelEnvelopes = envelopes
        refreshDerived()
        isLoading = false
    }

    // MARK: Markers (Stage 5: off-main decode of file-level marker streams)

    /// Markers belong to the whole file, not the selected stream: any
    /// single-channel string-format stream in `document` is a candidate
    /// (per `XdfMarkerReader`'s contract), regardless of which data stream
    /// is currently on screen. See `XdfFileMarkerLoader`.
    private func loadMarkers() async {
        let events = await XdfFileMarkerLoader.loadMarkers(document: document, fileURL: fileURL)
        if Task.isCancelled { return }
        markerEvents = events
        markersLoaded = true
    }

    // MARK: Trackpad scroll (pan / Shift-zoom)

    /// SwiftUI has no scroll-wheel gesture, so trackpad/mouse scroll pan and
    /// zoom are bridged via an `NSEvent` local monitor. Scoped to "cursor is
    /// over a lane" by checking `hoverX` (set by each lane's
    /// `onContinuousHover`, `nil` when the pointer is elsewhere — e.g. over
    /// the vertical channel-list `ScrollView`'s own scroll area, which must
    /// keep working normally) so this never steals scroll events meant for
    /// other views. Matches the original plugin's documented controls
    /// ("scroll = pan, Shift = zoom").
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

    // Mock marker stream — a single-channel string-format stream, matching
    // the real filter `FullWaveformView.loadMarkers()` applies to
    // `document.streams`. Its chunk data is never actually decoded in the
    // preview (see `previewMarkers` below); it's included so the document
    // shape mirrors what a real multi-stream recording looks like.
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

    func wave(amplitude: Float, phase: Float) -> XdfChannelEnvelope {
        let cols = 64
        var mins = [Float](repeating: 0, count: cols)
        var maxs = [Float](repeating: 0, count: cols)
        for i in 0..<cols {
            let v = sin(Float(i) / 4 + phase) * amplitude
            mins[i] = v - amplitude * 0.1
            maxs[i] = v + amplitude * 0.1
        }
        return XdfChannelEnvelope(mins: mins, maxs: maxs)
    }

    let envelopes: [XdfChannelEnvelope] = [
        wave(amplitude: 40, phase: 0),
        wave(amplitude: 55, phase: 1),
        wave(amplitude: 25, phase: 2),
        wave(amplitude: 0.5, phase: 0.5), // normalized gaze channel, independent scale
    ]

    let markers: [XdfMarkerEvent] = [
        XdfMarkerEvent(timestamp: 1.5, label: "trial_start"),
        XdfMarkerEvent(timestamp: 6.25, label: "stimulus_on"),
        XdfMarkerEvent(timestamp: 6.4, label: "fixation"),
        XdfMarkerEvent(timestamp: 14.0, label: "trial_end"),
        XdfMarkerEvent(timestamp: 22.0, label: "block_2_start_with_a_long_label"),
    ]

    return FullWaveformView(document: document,
                             stream: stream,
                             fileURL: URL(fileURLWithPath: "/tmp/mock.xdf"),
                             previewEnvelopes: envelopes,
                             previewMarkers: markers)
        .frame(width: 780, height: 420)
}
