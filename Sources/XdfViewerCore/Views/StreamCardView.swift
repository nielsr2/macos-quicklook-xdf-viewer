import SwiftUI

/// Expandable card summarizing one stream: a header (kind icon, name, type,
/// channel/event count, nominal rate, duration, a "view all channels"
/// shortcut, and an expand chevron) over an internally-scrollable list when
/// expanded — matching the original Windows plugin's card layout (see its
/// README screenshot), which keeps cards side-by-side in a grid with each
/// card's own list scrolling internally rather than the whole page growing.
/// Marker/event streams (`viewModel.isMarkerStream`) render a scrollable
/// events list instead of per-channel rows, matching the Windows original's
/// events box.
///
/// Replaces the old single-sparkline-per-stream card whose only action was
/// jumping straight into the all-channels-stacked `FullWaveformView`. That
/// navigation is kept (confirmed per the plan, not removed) but demoted to
/// the header's "view all channels" button — per-channel rows are now the
/// primary way to inspect a stream.
public struct StreamCardView: View {
    public let viewModel: StreamCardViewModel

    /// Toggles this stream's own expander (header tap).
    public var onToggleExpanded: () -> Void
    /// Toggles one channel row's inline expand state (triggers the tier-2
    /// detail load on first expand in this stream). Passed the channel's
    /// `index`.
    public var onExpandChannel: (Int) -> Void
    /// Opens the tier-3 solo view for one channel. Passed the channel's `index`.
    public var onOpenSolo: (Int) -> Void
    /// Opens the legacy all-channels-stacked `FullWaveformView` for this
    /// stream — confirmed kept as a secondary entry point.
    public var onViewAll: () -> Void

    /// Accent used for the kind icon and every channel row's
    /// sparkline/detail plot. Defaults to the user's chosen
    /// `XdfViewerSettings.accentColor`; callers (and `#Preview`s) can still
    /// override it.
    public var accentColor: Color

    /// Max height of the expanded channel/events list before it scrolls
    /// internally. Callers (`XdfPreviewView`) compute this from the actual
    /// window height via a `GeometryReader` so an expanded card fills the
    /// available vertical space instead of stopping at an arbitrary fixed
    /// height — the list still scrolls internally if its content is taller
    /// than this. Defaults to a reasonable fixed value for callers (and
    /// `#Preview`s) that don't otherwise constrain it.
    public var maxContentHeight: CGFloat

    /// Unified search query (see `XdfOverviewViewModel.searchText`):
    /// filters channel rows by label and event rows by value,
    /// case-insensitive substring match. Empty matches everything.
    public var searchText: String

    public init(viewModel: StreamCardViewModel,
                maxContentHeight: CGFloat = 360,
                searchText: String = "",
                onToggleExpanded: @escaping () -> Void = {},
                onExpandChannel: @escaping (Int) -> Void = { _ in },
                onOpenSolo: @escaping (Int) -> Void = { _ in },
                onViewAll: @escaping () -> Void = {},
                accentColor: Color = XdfViewerSettings.shared.accentColor.color) {
        self.viewModel = viewModel
        self.maxContentHeight = maxContentHeight
        self.searchText = searchText
        self.onToggleExpanded = onToggleExpanded
        self.onExpandChannel = onExpandChannel
        self.onOpenSolo = onOpenSolo
        self.onViewAll = onViewAll
        self.accentColor = accentColor
    }

    /// Trimmed search query, or `nil` when empty (matches everything) — used
    /// only to pick between "no channels"/"no matching channels" wording.
    /// The actual filtering is `StreamCardViewModel.filterChannels`/
    /// `filterEvents`, shared with the model layer so the predicate is
    /// testable independently of this view.
    private var query: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Channels whose label matches `searchText` (all of them when empty).
    private var filteredChannels: [ChannelViewModel] {
        StreamCardViewModel.filterChannels(viewModel.channels, matching: searchText)
    }

    /// Events whose value matches `searchText` (all of them when empty).
    private var filteredEvents: [StreamCardViewModel.MarkerEventRow] {
        StreamCardViewModel.filterEvents(viewModel.events, matching: searchText)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if viewModel.isExpanded {
                Divider()
                contentList
                    .frame(maxHeight: maxContentHeight)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var contentList: some View {
        if viewModel.isMarkerStream {
            eventsList
        } else {
            channelsList
        }
    }

    private var channelsList: some View {
        let channels = filteredChannels
        return ScrollView {
            if channels.isEmpty {
                emptyState(query == nil ? "No channels" : "No matching channels")
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(channels) { channel in
                        ChannelRowView(channel: channel,
                                       accentColor: accentColor,
                                       onToggleExpand: { onExpandChannel(channel.index) },
                                       onOpenSolo: { onOpenSolo(channel.index) })
                        if channel.id != channels.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private var eventsList: some View {
        let events = filteredEvents
        return ScrollView {
            if events.isEmpty {
                emptyState(query == nil ? "No events" : "No matching events")
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(events) { event in
                        eventRow(event)
                        if event.id != events.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private func eventRow(_ event: StreamCardViewModel.MarkerEventRow) -> some View {
        HStack(spacing: 10) {
            Text(event.timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(event.value)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onToggleExpanded) {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.iconSystemName)
                        .font(.title3)
                        .foregroundStyle(accentColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(viewModel.name)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(viewModel.typeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    metadataRow
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(viewModel.isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onViewAll) {
                Image(systemName: "rectangle.stack")
            }
            .buttonStyle(.borderless)
            .help("View all \(viewModel.channelCount) channels stacked")
        }
        .padding(12)
    }

    private var metadataRow: some View {
        HStack(spacing: 10) {
            if viewModel.isMarkerStream {
                Label(eventCountLabel, systemImage: "flag")
            } else {
                Label(channelCountLabel, systemImage: "line.3.horizontal")
            }
            Text(viewModel.nominalSampleRateText)
            Text(viewModel.durationText)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var channelCountLabel: String {
        let total = viewModel.channelCount
        let shown = filteredChannels.count
        return shown == total ? "\(total) ch" : "\(shown)/\(total) ch"
    }

    private var eventCountLabel: String {
        let total = viewModel.events.count
        let noun = "event\(total == 1 ? "" : "s")"
        let shown = filteredEvents.count
        return shown == total ? "\(total) \(noun)" : "\(shown)/\(total) \(noun)"
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
                                    XdfChannelInfo(label: "", unit: "microvolts", type: "EEG"), // exercises "Ch 4" fallback
                                ],
                                firstTimestamp: 0,
                                lastTimestamp: 305.5,
                                sampleCount: 78208,
                                effectiveSampleRate: 256.1)

    var viewModel = StreamCardViewModel(stream: stream)
    // Hand-build per-channel envelopes so the preview shows real-looking
    // waveforms, with one channel pre-expanded (tier-2 detail visible) and
    // one still loading, matching the shape of a live decimation pass.
    func wave(amplitude: Float, phase: Float, cols: Int) -> XdfChannelEnvelope {
        let mins = (0..<cols).map { Float(sin((Float($0) + phase) / 5)) * amplitude - amplitude * 0.1 }
        let maxs = (0..<cols).map { Float(sin((Float($0) + phase) / 5)) * amplitude + amplitude * 0.1 }
        return XdfChannelEnvelope(mins: mins, maxs: maxs)
    }
    for i in viewModel.channels.indices {
        viewModel.channels[i].sparkline = wave(amplitude: Float(20 + i * 10), phase: Float(i), cols: 48)
    }
    viewModel.channels[0].isExpanded = true
    viewModel.channels[0].detail = wave(amplitude: 20, phase: 0, cols: 200)
    viewModel.channels[1].isExpanded = true
    viewModel.channels[1].isLoadingDetail = true
    viewModel.detailLoaded = false

    return StreamCardView(viewModel: viewModel, maxContentHeight: 480)
        .frame(width: 420)
        .padding()
}

#Preview("Marker stream") {
    let stream = XdfStreamInfo(streamID: 3,
                                name: "Session-Markers",
                                type: "Markers",
                                channelCount: 1,
                                nominalSampleRate: 0,
                                channelFormat: .string,
                                channels: [XdfChannelInfo(label: "marker", unit: nil, type: "Markers")],
                                firstTimestamp: 10.0,
                                lastTimestamp: 300.0,
                                sampleCount: 5,
                                effectiveSampleRate: nil)

    var viewModel = StreamCardViewModel(stream: stream)
    // Hand-build a few sample events (relative to a recording start of 10s,
    // matching what `XdfOverviewViewModel.startMarkerEventLoading()` would
    // publish) so the preview illustrates the events list without reading a
    // real file.
    viewModel.events = [
        StreamCardViewModel.MarkerEventRow(index: 0, timestamp: 10.0, timeLabel: "0:00", value: "trial_start"),
        StreamCardViewModel.MarkerEventRow(index: 1, timestamp: 24.25, timeLabel: "0:14", value: "stimulus_on"),
        StreamCardViewModel.MarkerEventRow(index: 2, timestamp: 61.0, timeLabel: "0:51", value: "response"),
        StreamCardViewModel.MarkerEventRow(index: 3, timestamp: 300.0, timeLabel: "4:50", value: "trial_end"),
    ]

    return StreamCardView(viewModel: viewModel, maxContentHeight: 260)
        .frame(width: 320)
        .padding()
}
