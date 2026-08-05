import SwiftUI

/// Root Quick Look preview UI for `.xdf` recordings: a title bar (a
/// Windows-style summary line + a unified channel/event search field) over a
/// side-by-side grid of expandable `StreamCardView` sections, one per stream
/// — matching the original Windows plugin's side-by-side card layout (see
/// its README screenshot). Each card's internal channel/events list scrolls
/// on its own (`StreamCardView`), sized to fill the window's available
/// height (see `cardContentHeight(availableHeight:)`) rather than a fixed
/// cap, so cards stay aligned in the grid and make full use of the window
/// regardless of how many channels are expanded, instead of the whole page
/// growing.
///
/// Three-way navigation via simple `@State` selection + conditional view
/// swap (no `NavigationStack` — this is hosted inside an `NSHostingView` in
/// a Quick Look extension, so the simplest thing that works is preferred):
/// the per-channel solo view (`SoloChannelView`, tier 3), the legacy
/// all-channels-stacked `FullWaveformView` (kept as a secondary "view all
/// channels" entry point), or the overview itself. No marker overlays in
/// the overview (deferred — a human decision, not just an MVP cut).
public struct XdfPreviewView: View {
    @StateObject private var model: XdfOverviewViewModel
    @State private var selectedStreamID: UInt32?
    @State private var soloSelection: (streamID: UInt32, channelIndex: Int)?
    /// One decode cache for the whole preview session, shared by the full and
    /// solo views so navigating between them (or switching soloed channels)
    /// reuses a stream's decoded envelopes instead of re-reading from disk.
    @State private var envelopeCache = XdfEnvelopeCache()

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: 12, alignment: .top)]

    public init(model: XdfOverviewViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        Group {
            if let soloSelection, let stream = model.document.streams.first(where: { $0.streamID == soloSelection.streamID }) {
                SoloChannelView(document: model.document,
                                 stream: stream,
                                 channelIndex: soloSelection.channelIndex,
                                 fileURL: model.fileURL,
                                 envelopeCache: envelopeCache,
                                 onClose: { self.soloSelection = nil })
            } else if let selectedStreamID, let stream = model.document.streams.first(where: { $0.streamID == selectedStreamID }) {
                FullWaveformView(document: model.document,
                                  stream: stream,
                                  fileURL: model.fileURL,
                                  envelopeCache: envelopeCache,
                                  onBack: { self.selectedStreamID = nil })
            } else {
                overview
            }
        }
        .onAppear { model.startDecimation() }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            GeometryReader { geo in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(model.streamCards) { card in
                            StreamCardView(viewModel: card,
                                            maxContentHeight: cardContentHeight(availableHeight: geo.size.height),
                                            searchText: model.searchText,
                                            onToggleExpanded: { model.toggleStreamExpanded(card.streamID) },
                                            onExpandChannel: { channelIndex in
                                                model.toggleChannelExpanded(streamID: card.streamID, channelIndex: channelIndex)
                                            },
                                            onOpenSolo: { channelIndex in
                                                soloSelection = (card.streamID, channelIndex)
                                            },
                                            onViewAll: { selectedStreamID = card.streamID })
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Approximate height of a card's own header + its outer grid
    /// padding — subtracted from the window's available height so an
    /// expanded card's internal channel/events list fills the rest of the
    /// window instead of stopping at an arbitrary fixed cap (see
    /// `StreamCardView.maxContentHeight`). This is a coarse estimate (every
    /// card gets the same cap, regardless of its own header's actual
    /// measured height, and a multi-row grid over-allocates since every row
    /// gets a cap sized for a single row) — good enough for the common case
    /// this redesign targets (a handful of streams filling one row), and the
    /// list still scrolls internally if a card's real content is taller.
    private func cardContentHeight(availableHeight: CGFloat) -> CGFloat {
        max(availableHeight - cardChromeHeight, minCardContentHeight)
    }
    private let cardChromeHeight: CGFloat = 90
    private let minCardContentHeight: CGFloat = 160

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(Color(nsColor: .controlAccentColor))
            Text(model.summary)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if model.decimationTruncated {
                Label("Truncated", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .help("This recording has a lot of streams, so only a subset were rendered with real sparkline detail; the rest show a placeholder. Open any stream to see its own full waveform in full detail.")
            }
            Spacer()
            searchField
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Unified search field filtering both channel labels and event values
    /// across every card (see `XdfOverviewViewModel.searchText`), styled
    /// like `FullWaveformView.channelSearchField` for visual consistency
    /// between the overview and the full-waveform view.
    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("Search channels & events", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 160)
            if !model.searchText.isEmpty {
                Button(action: { model.searchText = "" }) {
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
}

#Preview {
    let streams: [XdfStreamInfo] = [
        XdfStreamInfo(streamID: 1,
                       name: "EEG-Sensor-1",
                       type: "EEG",
                       channelCount: 32,
                       nominalSampleRate: 256,
                       channelFormat: .float32,
                       channels: (1...32).map { XdfChannelInfo(label: "Ch\($0)", unit: "microvolts", type: "EEG") },
                       firstTimestamp: 0,
                       lastTimestamp: 305.5,
                       sampleCount: 78208,
                       effectiveSampleRate: 256.1),
        XdfStreamInfo(streamID: 2,
                       name: "Gaze-Tracker",
                       type: "Gaze",
                       channelCount: 4,
                       nominalSampleRate: 120,
                       channelFormat: .double64,
                       channels: [
                        XdfChannelInfo(label: "x", unit: "normalized", type: "Gaze"),
                        XdfChannelInfo(label: "y", unit: "normalized", type: "Gaze"),
                        XdfChannelInfo(label: "pupil_left", unit: "mm", type: "Gaze"),
                        XdfChannelInfo(label: "pupil_right", unit: "mm", type: "Gaze"),
                       ],
                       firstTimestamp: 0.2,
                       lastTimestamp: 304.9,
                       sampleCount: 36564,
                       effectiveSampleRate: 119.9),
        XdfStreamInfo(streamID: 3,
                       name: "Session-Markers",
                       type: "Markers",
                       channelCount: 1,
                       nominalSampleRate: 0,
                       channelFormat: .string,
                       channels: [XdfChannelInfo(label: "marker", unit: nil, type: "Markers")],
                       firstTimestamp: 1.0,
                       lastTimestamp: 300.0,
                       sampleCount: 42,
                       effectiveSampleRate: nil),
    ]
    let document = XdfDocument(version: "1.0", streams: streams, chunkIndex: [])
    let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/sample-recording.xdf"), document: document)
    // Expand one channel row so the preview shows all three disclosure
    // tiers at once (collapsed sparkline rows, an expanded inline detail
    // row, and the stream-level expander itself).
    model.toggleChannelExpanded(streamID: 1, channelIndex: 0)
    // Seed the marker stream's events directly (bypassing the real async
    // decode pass, which would read from the nonexistent preview file URL)
    // so the preview illustrates the new events list, not an empty state.
    model.previewSeedEvents([
        StreamCardViewModel.MarkerEventRow(index: 0, timestamp: 1.0, timeLabel: "0:00", value: "session_start"),
        StreamCardViewModel.MarkerEventRow(index: 1, timestamp: 45.5, timeLabel: "0:45", value: "block_1_start"),
        StreamCardViewModel.MarkerEventRow(index: 2, timestamp: 180.0, timeLabel: "2:59", value: "block_1_end"),
    ], forStream: 3)
    return XdfPreviewView(model: model)
        .frame(width: 780, height: 520)
}
