import SwiftUI

/// One channel's row inside an expanded `StreamCardView` — the
/// channel-centric unit of the redesigned overview.
///
/// Three disclosure tiers, matching the original WPF app:
/// 1. Collapsed (default): label/unit + the compact tier-1
///    `WaveformSparkline` (unchanged component).
/// 2. Tapping the row toggles it to a taller tier-2 "detail" plot in place
///    (`ChannelLaneView`, extracted from `FullWaveformView`), fed by
///    `channel.detail` once `XdfOverviewViewModel.loadDetail(forStream:)`
///    resolves (a `ProgressView` shows while it's still loading).
/// 3. A small, separate "expand" affordance overlaid on the tier-2 plot
///    opens the tier-3 solo view (`SoloChannelView`). It's kept distinct
///    from the row's own expand/collapse tap zone so "show more detail
///    here" and "open the full single-channel view" don't compete for the
///    same tap gesture.
public struct ChannelRowView: View {
    public let channel: ChannelViewModel
    public var accentColor: Color

    /// Toggles this row's inline expand state. `StreamCardView` wires this
    /// to `XdfOverviewViewModel.toggleChannelExpanded(streamID:channelIndex:)`,
    /// which also kicks off the tier-2 detail load on first expand.
    public var onToggleExpand: () -> Void
    /// Opens the tier-3 solo view for this channel.
    public var onOpenSolo: () -> Void

    public init(channel: ChannelViewModel,
                accentColor: Color = XdfViewerSettings.shared.accentColor.color,
                onToggleExpand: @escaping () -> Void = {},
                onOpenSolo: @escaping () -> Void = {}) {
        self.channel = channel
        self.accentColor = accentColor
        self.onToggleExpand = onToggleExpand
        self.onOpenSolo = onOpenSolo
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            collapsedRow
            if channel.isExpanded {
                expandedDetail
            }
        }
        .padding(.vertical, 4)
    }

    private var collapsedRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.label)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let unit = channel.unit, !unit.isEmpty {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 100, alignment: .leading)

            WaveformSparkline(envelope: channel.sparkline, color: accentColor)
                .frame(height: 30)

            Image(systemName: channel.isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggleExpand() }
    }

    @ViewBuilder
    private var expandedDetail: some View {
        ZStack(alignment: .topTrailing) {
            ChannelLaneView(envelope: channel.detail ?? .flat(columns: 48),
                             label: channel.label,
                             color: accentColor)
                .frame(height: 120)
                .overlay {
                    if channel.isLoadingDetail, channel.detail == nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

            Button(action: onOpenSolo) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2)
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("Open single-channel view")
        }
    }
}

#Preview {
    let quietSparkline: XdfChannelEnvelope = {
        let cols = 48
        let mins = (0..<cols).map { Float(sin(Double($0) / 6)) * 0.1 - 0.02 }
        let maxs = (0..<cols).map { Float(sin(Double($0) / 6)) * 0.1 + 0.02 }
        return XdfChannelEnvelope(mins: mins, maxs: maxs)
    }()
    let detailEnvelope: XdfChannelEnvelope = {
        let cols = 200
        let mins = (0..<cols).map { Float(sin(Double($0) / 5)) * 40 - 5 }
        let maxs = (0..<cols).map { Float(sin(Double($0) / 5)) * 40 + 5 }
        return XdfChannelEnvelope(mins: mins, maxs: maxs)
    }()

    let collapsedChannel = ChannelViewModel(index: 0, label: "Fp1", unit: "microvolts", sparkline: quietSparkline)
    let expandedChannel = ChannelViewModel(index: 1,
                                            label: "Fp2",
                                            unit: "microvolts",
                                            sparkline: quietSparkline,
                                            detail: detailEnvelope,
                                            isExpanded: true)
    let loadingChannel = ChannelViewModel(index: 2,
                                           label: "Cz",
                                           unit: "microvolts",
                                           sparkline: quietSparkline,
                                           isExpanded: true,
                                           isLoadingDetail: true)

    return VStack(alignment: .leading, spacing: 0) {
        ChannelRowView(channel: collapsedChannel)
        Divider()
        ChannelRowView(channel: expandedChannel)
        Divider()
        ChannelRowView(channel: loadingChannel)
    }
    .padding()
    .frame(width: 420)
}
