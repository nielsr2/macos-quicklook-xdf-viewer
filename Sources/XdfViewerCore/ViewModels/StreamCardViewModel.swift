import Foundation

/// Per-stream display state for one `StreamCardView`, derived from an
/// `XdfStreamInfo`. Pure/value-derived (no I/O), so it's cheap to rebuild
/// whenever the underlying document changes.
public struct StreamCardViewModel: Identifiable, Sendable, Equatable {
    public var id: UInt32 { streamID }

    public var streamID: UInt32
    public var name: String
    public var typeLabel: String
    public var iconSystemName: String
    public var channelCount: Int
    public var nominalSampleRateText: String
    public var durationText: String

    /// Per-channel display state — the channel-centric unit driving this
    /// stream's `ChannelRowView`s. One entry per `stream.channelCount`, in
    /// channel order (see `ChannelViewModel.index`). Empty for marker
    /// streams (see `isMarkerStream`), which render `events` instead.
    public var channels: [ChannelViewModel]

    /// `true` for a marker/event stream — single-channel string format, the
    /// XDF convention for LSL "Markers"-style streams (see
    /// `XdfMarkerReader`). `StreamCardView` renders these as a scrollable
    /// events list (`events`) instead of per-channel `ChannelRowView`s,
    /// matching the Windows original's events box rather than showing a
    /// meaningless flat "Ch 1" sparkline for string-typed samples.
    public var isMarkerStream: Bool

    /// This marker stream's decoded events, filled in once
    /// `XdfOverviewViewModel.startMarkerEventLoading()` resolves. Always
    /// empty for non-marker streams, and empty here until that async pass
    /// completes (mirrors `channels[].sparkline` starting flat until
    /// `startDecimation()` resolves).
    public var events: [MarkerEventRow] = []

    /// One decoded marker event, display-ready for the overview's events
    /// list — a formatted counterpart to `XdfMarkerReader`'s `XdfMarkerEvent`.
    public struct MarkerEventRow: Identifiable, Sendable, Equatable {
        public var id: Int { index }

        /// Position within the owning stream's timestamp-sorted event list.
        public let index: Int
        /// Raw XDF timestamp (same clock as `XdfStreamInfo.firstTimestamp`).
        public let timestamp: Double
        /// Pre-formatted time label, relative to the recording's start (see
        /// `XdfOverviewViewModel.startMarkerEventLoading()` for how "start"
        /// is chosen) — ready to display directly, no further formatting.
        public let timeLabel: String
        /// The marker's label/value text.
        public let value: String

        public init(index: Int, timestamp: Double, timeLabel: String, value: String) {
            self.index = index
            self.timestamp = timestamp
            self.timeLabel = timeLabel
            self.value = value
        }
    }

    /// Stream-level expander state (mirrors the original WPF app's
    /// `Expander.IsExpanded`). Always starts open, matching the Windows
    /// original: every channel (or every event, for a marker stream) is
    /// visible directly on the overview without extra navigation, regardless
    /// of channel count.
    public var isExpanded: Bool

    /// `true` once `XdfOverviewViewModel.loadDetail(forStream:)` has
    /// resolved one whole-stream tier-2 decode pass and fanned the results
    /// into every channel's `detail`. Guards against re-decoding when a
    /// sibling channel in the same stream is expanded later.
    public var detailLoaded: Bool = false

    public init(stream: XdfStreamInfo) {
        self.streamID = stream.streamID
        self.name = stream.name.isEmpty ? "Untitled stream" : stream.name
        self.channelCount = stream.channelCount

        let classification = StreamKindClassifier.classify(type: stream.type)
        self.typeLabel = classification.label
        self.iconSystemName = classification.iconSystemName

        self.nominalSampleRateText = Self.formatSampleRate(stream.nominalSampleRate)
        self.durationText = Self.formatDuration(stream.duration)

        self.isMarkerStream = stream.channelFormat == .string && stream.channelCount == 1
        self.channels = (0..<stream.channelCount).map { ChannelViewModel(index: $0, stream: stream) }
        self.isExpanded = true
    }

    /// Formats a nominal sample rate, or "Irregular" for marker-style streams
    /// (rate == 0, per the XDF convention for irregularly-sampled streams).
    static func formatSampleRate(_ rate: Double) -> String {
        guard rate > 0, rate.isFinite else { return "Irregular rate" }
        if rate.rounded() == rate {
            // `%.0f` (not `Int(rate)`) so an absurd but integral rate can't trap.
            return String(format: "%.0f Hz", rate)
        }
        return String(format: "%.2f Hz", rate)
    }

    /// Formats a duration (seconds) as `h:mm:ss` or `m:ss`, or a placeholder
    /// when the footer (and thus duration) is unavailable.
    static func formatDuration(_ duration: Double?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "Unknown duration" }
        let totalSeconds = safeInt(duration.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            // `%ld` (not `%d`) so a large hours value isn't truncated to 32 bits
            // and rendered negative.
            return String(format: "%ld:%02ld:%02ld", hours, minutes, seconds)
        }
        return String(format: "%ld:%02ld", minutes, seconds)
    }

    /// Pure, case-insensitive substring filter over a stream's channels by
    /// label — the numeric-stream half of the overview's unified search
    /// field (see `XdfOverviewViewModel.searchText`). An empty or
    /// whitespace-only query matches everything. `StreamCardView` calls this
    /// directly so the predicate has one implementation, testable
    /// independently of any SwiftUI view.
    public static func filterChannels(_ channels: [ChannelViewModel], matching query: String) -> [ChannelViewModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return channels }
        return channels.filter { $0.label.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Pure, case-insensitive substring filter over a marker stream's events
    /// by value — the marker-stream half of the overview's unified search
    /// field. An empty or whitespace-only query matches everything.
    public static func filterEvents(_ events: [MarkerEventRow], matching query: String) -> [MarkerEventRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return events }
        return events.filter { $0.value.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Formats a marker event's time (seconds, relative to the recording's
    /// start — see `XdfOverviewViewModel.startMarkerEventLoading()`) as
    /// `h:mm:ss` or `m:ss`. Kept distinct from `formatDuration` (event times
    /// are always a concrete, non-negative offset — never "unknown") and
    /// from `TimeAxis.formatTime` (that file belongs to the full-waveform
    /// view and is out of scope here).
    static func formatEventTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let totalSeconds = safeInt(max(0, seconds).rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%ld:%02ld:%02ld", hours, minutes, secs)
        }
        return String(format: "%ld:%02ld", minutes, secs)
    }
}
