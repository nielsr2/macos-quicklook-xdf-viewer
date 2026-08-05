import Foundation
import Combine

/// Owns the decoded `XdfDocument` structure and derived per-stream display
/// state for one previewed `.xdf` file. Mirrors `AudioViewerModel`'s
/// phased-loading pattern: the structural pass (Stage 1's fast, sample-free
/// `XdfReader.readStructure`) is done once up front by the caller (typically
/// off the main thread), and this model tracks which phase of loading the
/// preview is currently in.
@MainActor
public final class XdfOverviewViewModel: ObservableObject {

    /// Coarse load-phase tracking for the preview, following
    /// `AudioViewerModel`'s pattern of exposing clear, observable state for
    /// each stage of the two-phase load.
    ///
    /// Stage 2 (this pass) only ever reaches `.structureReady` — the overview
    /// is built entirely from `XdfReader.readStructure`'s fast, sample-free
    /// pass. `.decimating`/`.detailReady` are defined now so Stage 3 (envelope
    /// decimation + full waveform view) can drive this same published phase
    /// without changing the enum's shape.
    public enum LoadPhase: Equatable, Sendable {
        /// The fast structural pass has completed; stream cards are ready to display.
        case structureReady
        /// (Stage 3) Background envelope decimation is in progress for one or more streams.
        case decimating
        /// (Stage 3) Decimated envelopes are available for the detail/full-waveform view.
        case detailReady
    }

    public let fileURL: URL
    public let title: String
    public let document: XdfDocument

    @Published public private(set) var streamCards: [StreamCardViewModel]
    @Published public private(set) var loadPhase: LoadPhase = .structureReady

    /// Unified search query, filtering both channel rows (by label) and
    /// marker event rows (by value) across every card — see
    /// `XdfPreviewView`'s top-bar search field. Empty matches everything.
    /// Pure substring filtering happens in `StreamCardView`; this model just
    /// holds the query so every card can react to the same one.
    @Published public var searchText: String = ""

    /// `true` once `startDecimation()` has run for a file with more streams
    /// than `maxStreamsToDecimate` — i.e. one or more streams were left with
    /// their flat placeholder sparkline instead of a real decimated one.
    /// `XdfPreviewView` surfaces this as a small, unobtrusive title-bar
    /// indicator rather than silently under-representing the recording.
    @Published public private(set) var decimationTruncated = false

    /// Streams whose sparkline decimation hasn't resolved yet (success or
    /// fallback-flat both count as "resolved" — `XdfEnvelopeReader` never
    /// throws). Empty once `loadPhase` reaches `.detailReady`.
    private var pendingSparklineStreamIDs: Set<UInt32> = []

    /// Streams currently running a `loadDetail` pass. Guards against
    /// spawning a second concurrent whole-stream decode when a user
    /// double-taps (or expands two sibling channels in quick succession)
    /// before the first pass resolves.
    private var detailLoadingStreamIDs: Set<UInt32> = []

    /// Number of sparkline columns requested per stream — matches
    /// `WaveformSparkline`'s prior placeholder default.
    private let sparklineColumns = 48

    /// Ceiling on how many streams get a real background decimation pass for
    /// their sparkline. `startDecimation()` used to spawn one unconditional
    /// `Task.detached` per stream, so a file declaring hundreds of streams
    /// (pathological, but not impossible for a malformed or synthetic XDF
    /// file) could pile up hundreds of concurrent decode tasks. 32 is well
    /// above any real multi-modal LSL session we've seen (the reference file
    /// had 2 streams) while keeping worst-case concurrent decode work
    /// bounded; streams beyond the cap keep their flat placeholder envelope
    /// in the overview grid — the per-stream ceiling in
    /// `XdfEnvelopeReader.readEnvelopes` is a separate, independent guardrail
    /// for the *size* of any one stream, and applies unconditionally
    /// (including to whichever stream a user later taps into for the full
    /// waveform view, which always decimates that one stream fresh
    /// regardless of this cap).
    private let maxStreamsToDecimate = 32

    public init(fileURL: URL, document: XdfDocument) {
        self.fileURL = fileURL
        self.title = fileURL.lastPathComponent
        self.document = document
        self.streamCards = document.streams.map(StreamCardViewModel.init(stream:))
    }

    public var streamCount: Int { streamCards.count }

    /// The longest duration across every stream in the file (footer
    /// `lastTimestamp - firstTimestamp`), or `nil` if no stream has a usable
    /// footer — used by `summary` and, if a duration is known, formatted
    /// with `StreamCardViewModel.formatDuration`.
    private var longestStreamDuration: Double? {
        document.streams.compactMap(\.duration).max()
    }

    /// A Windows-style one-line summary for the overview's top bar, replacing
    /// the redundant filename (Quick Look's window chrome already shows
    /// that): `"{n} stream(s) · {duration} · XDF v{version}"`. Any clause
    /// whose value is unknown (no footer duration anywhere in the file, no
    /// declared XDF version) is simply omitted rather than shown as a
    /// placeholder, so the line stays honest about what's actually known.
    public var summary: String {
        var parts = ["\(streamCount) stream\(streamCount == 1 ? "" : "s")"]
        if let longestStreamDuration {
            parts.append(StreamCardViewModel.formatDuration(longestStreamDuration))
        }
        if let version = document.version, !version.isEmpty {
            parts.append("XDF v\(version)")
        }
        return parts.joined(separator: " · ")
    }

    /// Kicks a background envelope-decimation pass for every stream's most
    /// informative channel (largest peak-to-peak range — some recordings
    /// only feed one of many declared channels) so `StreamCardView` can
    /// replace its flat placeholder sparkline with real data. Each stream is
    /// decoded independently on a detached
    /// task (see `XdfEnvelopeReader.readEnvelopes`) so one slow or malformed
    /// stream can't block the others from resolving; results are published
    /// back on the main actor as each stream finishes. Safe to call once
    /// `loadPhase` is `.structureReady`; a no-op otherwise (e.g. if already
    /// called).
    public func startDecimation() {
        guard loadPhase == .structureReady else { return }

        let streams = document.streams
        guard !streams.isEmpty else {
            loadPhase = .detailReady
            return
        }

        loadPhase = .decimating
        startMarkerEventLoading()

        // Cap how many streams get a real decimation pass; the rest keep
        // their flat placeholder sparkline (see `maxStreamsToDecimate`).
        let streamsToDecimate = streams.prefix(maxStreamsToDecimate)
        decimationTruncated = streams.count > maxStreamsToDecimate
        pendingSparklineStreamIDs = Set(streamsToDecimate.map(\.streamID))

        let url = fileURL
        let columns = sparklineColumns
        let doc = document

        for stream in streamsToDecimate {
            let streamID = stream.streamID
            let chunks = doc.chunks(forStream: streamID)
            let channelCount = stream.channelCount
            let channelFormat = stream.channelFormat
            let totalSampleCount = stream.sampleCount ?? chunks.reduce(0) { $0 + $1.declaredSampleCount }

            Task.detached(priority: .utility) { [weak self] in
                let envelopes = XdfEnvelopeReader.readEnvelopes(url: url,
                                                                 chunks: chunks,
                                                                 channelCount: channelCount,
                                                                 channelFormat: channelFormat,
                                                                 totalSampleCount: totalSampleCount,
                                                                 columns: columns)
                await MainActor.run {
                    self?.applySparklineEnvelopes(envelopes, forStream: streamID)
                }
            }
        }
    }

    /// Fans one stream's full per-channel envelope array (already computed
    /// by `startDecimation()` — every channel is decoded together
    /// regardless of how many the caller actually wants, see
    /// `XdfSampleDecoder`) into each `ChannelViewModel.sparkline` in that
    /// stream, in index order. Previously this collapsed to a single
    /// `.mostInformative()` envelope shared across the whole card; now every
    /// channel keeps its own, at zero added decode cost.
    private func applySparklineEnvelopes(_ envelopes: [XdfChannelEnvelope], forStream streamID: UInt32) {
        if let index = streamCards.firstIndex(where: { $0.streamID == streamID }) {
            let count = streamCards[index].channels.count
            for c in 0..<count {
                // Defensive guard: pad with a flat placeholder rather than
                // crash if `envelopes` came back shorter than the channel
                // list for any reason (e.g. a malformed header declaring
                // more channels than the decoder actually saw).
                streamCards[index].channels[c].sparkline = c < envelopes.count ? envelopes[c] : .flat(columns: sparklineColumns)
            }
        }
        pendingSparklineStreamIDs.remove(streamID)
        if pendingSparklineStreamIDs.isEmpty {
            loadPhase = .detailReady
        }
    }

    /// Loads one whole-stream, higher-resolution tier-2 "detail" pass (every
    /// channel, since `XdfSampleDecoder.decodeSamples` must parse every
    /// channel's value on every sample just to advance the byte cursor —
    /// decoding "one channel" costs the same as decoding all of them) and
    /// fans the results into each channel's `detail`, caching via
    /// `StreamCardViewModel.detailLoaded` so every channel row in the
    /// stream shares one decode pass. No-op if this stream's detail is
    /// already loaded, already loading, or the stream isn't known.
    public func loadDetail(forStream streamID: UInt32) {
        guard let index = streamCards.firstIndex(where: { $0.streamID == streamID }) else { return }
        guard !streamCards[index].detailLoaded, !detailLoadingStreamIDs.contains(streamID) else { return }
        guard let stream = document.streams.first(where: { $0.streamID == streamID }) else { return }

        detailLoadingStreamIDs.insert(streamID)
        for c in streamCards[index].channels.indices {
            streamCards[index].channels[c].isLoadingDetail = true
        }

        let url = fileURL
        let doc = document
        let chunks = doc.chunks(forStream: streamID)
        let channelCount = stream.channelCount
        let channelFormat = stream.channelFormat
        let totalSampleCount = stream.sampleCount ?? chunks.reduce(0) { $0 + $1.declaredSampleCount }
        // Mirrors FullWaveformView.loadEnvelopes' targetColumns shape (a
        // per-second column density clamped to a sane range) rather than
        // inventing unrelated constants — the inline detail plot renders
        // smaller than the full waveform view, so a lower ceiling suffices.
        let columns = min(2000, max(600, Int((stream.duration ?? 0) * 40)))

        Task.detached(priority: .userInitiated) { [weak self] in
            let envelopes = XdfEnvelopeReader.readEnvelopes(url: url,
                                                             chunks: chunks,
                                                             channelCount: channelCount,
                                                             channelFormat: channelFormat,
                                                             totalSampleCount: totalSampleCount,
                                                             columns: columns)
            await MainActor.run {
                self?.applyDetailEnvelopes(envelopes, forStream: streamID)
            }
        }
    }

    private func applyDetailEnvelopes(_ envelopes: [XdfChannelEnvelope], forStream streamID: UInt32) {
        detailLoadingStreamIDs.remove(streamID)
        guard let index = streamCards.firstIndex(where: { $0.streamID == streamID }) else { return }
        let fallbackColumns = envelopes.first?.columnCount ?? 1
        let count = streamCards[index].channels.count
        for c in 0..<count {
            streamCards[index].channels[c].detail = c < envelopes.count ? envelopes[c] : .flat(columns: fallbackColumns)
            streamCards[index].channels[c].isLoadingDetail = false
        }
        streamCards[index].detailLoaded = true
    }

    /// Decodes every marker stream's events (see
    /// `StreamCardViewModel.isMarkerStream`) off the main actor, in one
    /// detached pass covering every marker stream in the file together —
    /// rather than one independent task per stream, like
    /// `startDecimation()` — so every stream's event times can be normalized
    /// against the *same* "recording start" reference: the earliest marker
    /// timestamp seen anywhere in the file (falling back to the earliest
    /// declared stream `firstTimestamp` if there are no marker events at
    /// all). Using a shared, file-wide zero rather than each stream's own
    /// possibly-later first timestamp keeps events from multiple marker
    /// streams comparable/orderable by their displayed time. Calls
    /// `XdfMarkerReader` directly (not `XdfFileMarkerLoader`, which merges
    /// every stream's events into one flat list for the full-waveform
    /// overlay — the overview keeps them grouped per stream instead). A
    /// no-op if the file has no marker streams.
    private func startMarkerEventLoading() {
        let markerStreams = document.streams.filter { $0.channelFormat == .string && $0.channelCount == 1 }
        guard !markerStreams.isEmpty else { return }

        let url = fileURL
        let doc = document

        Task.detached(priority: .utility) { [weak self] in
            var perStream: [(streamID: UInt32, events: [XdfMarkerEvent])] = []
            for stream in markerStreams {
                let chunks = doc.chunks(forStream: stream.streamID)
                let events = XdfMarkerReader.readMarkers(url: url,
                                                          chunks: chunks,
                                                          channelCount: stream.channelCount,
                                                          channelFormat: stream.channelFormat)
                perStream.append((stream.streamID, events))
            }

            let zero = perStream.flatMap { $0.events.map(\.timestamp) }.min()
                ?? doc.streams.compactMap(\.firstTimestamp).min()
                ?? 0

            for (streamID, events) in perStream {
                let rows = events.enumerated().map { offset, event in
                    StreamCardViewModel.MarkerEventRow(index: offset,
                                                        timestamp: event.timestamp,
                                                        timeLabel: StreamCardViewModel.formatEventTime(event.timestamp - zero),
                                                        value: event.label)
                }
                await MainActor.run {
                    self?.applyMarkerEvents(rows, forStream: streamID)
                }
            }
        }
    }

    private func applyMarkerEvents(_ events: [StreamCardViewModel.MarkerEventRow], forStream streamID: UInt32) {
        guard let index = streamCards.firstIndex(where: { $0.streamID == streamID }) else { return }
        streamCards[index].events = events
    }

    /// Test/preview-only hook to seed a marker stream's `events` directly,
    /// bypassing the real async `XdfMarkerReader` decode pass — mirrors how
    /// `StreamCardView`'s own `#Preview` hand-builds `sparkline`/`detail`
    /// envelopes rather than reading real file bytes. Not called from any
    /// production code path.
    public func previewSeedEvents(_ events: [StreamCardViewModel.MarkerEventRow], forStream streamID: UInt32) {
        applyMarkerEvents(events, forStream: streamID)
    }

    /// Toggles a stream's own expander (header chevron/tap). Centralizing
    /// the mutation here — rather than exposing a mutable `streamCards`
    /// setter — matches the existing pattern of the model owning all state
    /// transitions and the view only reporting what happened.
    public func toggleStreamExpanded(_ streamID: UInt32) {
        guard let index = streamCards.firstIndex(where: { $0.streamID == streamID }) else { return }
        streamCards[index].isExpanded.toggle()
    }

    /// Toggles one channel row's inline expand state, triggering
    /// `loadDetail(forStream:)` for the owning stream whenever a row is
    /// being expanded (a no-op if detail is already loaded or loading).
    public func toggleChannelExpanded(streamID: UInt32, channelIndex: Int) {
        guard let streamIndex = streamCards.firstIndex(where: { $0.streamID == streamID }) else { return }
        guard channelIndex >= 0, channelIndex < streamCards[streamIndex].channels.count else { return }
        let expanding = !streamCards[streamIndex].channels[channelIndex].isExpanded
        streamCards[streamIndex].channels[channelIndex].isExpanded = expanding
        if expanding {
            loadDetail(forStream: streamID)
        }
    }
}
