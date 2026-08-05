import Foundation

/// Per-channel display state for one row inside an expanded
/// `StreamCardView` — the channel-centric unit the original WPF app is
/// built around. Each channel carries its own compact tier-1 sparkline,
/// an optional higher-resolution tier-2 "detail" envelope loaded lazily on
/// first expand, and this row's own expand/loading state.
///
/// `index` is this channel's position within the owning stream's
/// `channels`/envelope arrays — the same indexing convention used
/// elsewhere in the codebase (e.g. `FullWaveformView.channelLabel(at:)`),
/// so it lines up directly with `XdfStreamInfo.channels[index]` and every
/// per-channel `XdfChannelEnvelope` array `XdfEnvelopeReader.readEnvelopes`
/// returns.
public struct ChannelViewModel: Identifiable, Sendable, Equatable {
    public var id: Int { index }

    public let index: Int
    public let label: String
    public let unit: String?

    /// Compact tier-1 envelope. Starts flat (Stage 2-style placeholder
    /// shape) until `XdfOverviewViewModel.startDecimation()` resolves for
    /// the owning stream.
    public var sparkline: XdfChannelEnvelope
    /// Higher-resolution tier-2 envelope for the inline expanded row,
    /// loaded on first expand of any channel in this stream (see
    /// `XdfOverviewViewModel.loadDetail(forStream:)`, which decodes the
    /// whole stream once and caches the result for every sibling channel).
    /// `nil` until it resolves.
    public var detail: XdfChannelEnvelope?
    public var isExpanded: Bool
    public var isLoadingDetail: Bool

    public init(index: Int,
                label: String,
                unit: String?,
                sparkline: XdfChannelEnvelope = .flat(columns: 48),
                detail: XdfChannelEnvelope? = nil,
                isExpanded: Bool = false,
                isLoadingDetail: Bool = false) {
        self.index = index
        self.label = label
        self.unit = unit
        self.sparkline = sparkline
        self.detail = detail
        self.isExpanded = isExpanded
        self.isLoadingDetail = isLoadingDetail
    }

    /// Resolves this channel's label/unit from `stream.channels[index]`:
    /// the header's declared label when present and non-empty, otherwise a
    /// positional fallback (`"Ch \(index+1)"`, matching
    /// `FullWaveformView.channelLabel(at:)`) — headers don't always declare
    /// as many `<channel>` entries as `channelCount`, or leave labels blank.
    public init(index: Int, stream: XdfStreamInfo, sparkline: XdfChannelEnvelope = .flat(columns: 48)) {
        let info: XdfChannelInfo? = index < stream.channels.count ? stream.channels[index] : nil
        let resolvedLabel = info?.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Ch \(index + 1)"
        self.init(index: index, label: resolvedLabel, unit: info?.unit, sparkline: sparkline)
    }
}
