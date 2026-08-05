import SwiftUI

/// One auto-scaled channel lane: draws its envelope normalized to its own
/// data range (independent of every other lane) with a small label overlay.
/// The hover crosshair is intentionally NOT drawn here — the timeline views
/// draw a single cheap crosshair overlay across all lanes instead, so moving
/// the pointer doesn't invalidate (and re-stroke) every lane's `Canvas`.
///
/// Extracted from `FullWaveformView` (Stage 5 channel-centric redesign,
/// Phase 0) so both the all-channels-stacked view and the new per-channel
/// inline detail rows / single-channel solo view can reuse the exact same
/// tested rendering.
public struct ChannelLaneView: View {
    public let envelope: XdfChannelEnvelope
    public let label: String
    public var color: Color
    /// Multiplies the lane's auto-computed vertical scale — lets a caller
    /// (e.g. the solo view's amplitude control) zoom the waveform vertically
    /// without touching the underlying envelope data. `1` (default)
    /// reproduces the original auto-scale exactly.
    public var amplitudeScale: CGFloat
    /// Draws faint top/bottom gridlines in addition to the always-present
    /// center baseline — meant to pair with a `ValueAxis` alongside this
    /// lane (e.g. in `SoloChannelView`) so its three value labels line up
    /// with visible lines across the plot. Off by default: the compact
    /// inline-detail row and the multi-channel stacked view are too short
    /// for this to read as anything but clutter.
    public var showValueGridlines: Bool
    /// The sub-window of the envelope to draw, as a `0...1` fraction of the
    /// whole recording, mapped across this lane's full frame width. `nil`
    /// (default) draws the *entire* envelope across the frame — the original
    /// behaviour, still used by the compact overview rows (`ChannelRowView`,
    /// owned elsewhere) which always render the whole envelope at a small
    /// width.
    ///
    /// This is the crux of the "windowed rendering" zoom-crash fix: the
    /// timeline views now size this lane to the *visible viewport* (not the
    /// giant `contentWidth`) and pass the visible fraction here, so the
    /// `Canvas` never grows past the screen no matter how deep the zoom —
    /// and only the visible envelope columns are drawn, stretched to fill,
    /// which also improves zoom fidelity over the old "stretch fixed columns
    /// into huge blocks" approach.
    public var visibleFraction: ClosedRange<Double>?

    public init(envelope: XdfChannelEnvelope,
                label: String,
                color: Color = Color(nsColor: .controlAccentColor),
                amplitudeScale: CGFloat = 1,
                showValueGridlines: Bool = false,
                visibleFraction: ClosedRange<Double>? = nil) {
        self.envelope = envelope
        self.label = label
        self.color = color
        self.amplitudeScale = amplitudeScale
        self.showValueGridlines = showValueGridlines
        self.visibleFraction = visibleFraction
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .textBackgroundColor)
            Canvas { ctx, size in
                let cols = envelope.columnCount
                guard cols > 0, size.width > 0, size.height > 0 else { return }
                let mid = size.height / 2

                let dataMin = envelope.dataMin
                let dataMax = envelope.dataMax
                let dataRange = CGFloat(max(dataMax - dataMin, .ulpOfOne))
                let center = CGFloat((dataMax + dataMin) / 2)
                let scale = (size.height / 2 * 0.85) / (dataRange / 2) * amplitudeScale

                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: mid))
                baseline.addLine(to: CGPoint(x: size.width, y: mid))
                ctx.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)

                if showValueGridlines {
                    // Matches ValueAxis's top/bottom label positions exactly
                    // (the view's very top/bottom edge), so the lines and
                    // labels line up when the two are placed side by side.
                    for y in [CGFloat(0.5), size.height - 0.5] {
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: y))
                        line.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(line, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                    }
                }

                // Windowed draw: only the envelope columns inside
                // `visibleFraction` (defaulting to the whole 0...1 range) are
                // stroked, mapped across the full frame. This keeps the draw
                // cost bounded by what's on screen and, crucially, keeps the
                // frame itself viewport-sized rather than `contentWidth`-sized.
                let frac = visibleFraction ?? 0...1
                let lo = min(max(frac.lowerBound, 0), 1)
                let hi = min(max(frac.upperBound, lo), 1)
                let span = max(hi - lo, 1e-9)

                let startCol = min(cols - 1, max(0, Int((lo * Double(cols)).rounded(.down))))
                let endCol = min(cols, max(startCol + 1, Int((hi * Double(cols)).rounded(.up))))
                let visibleCols = max(1, endCol - startCol)

                var path = Path()
                let lineWidth = max(0.6, size.width / CGFloat(visibleCols))
                for i in startCol..<endCol {
                    let colFrac = Double(i) / Double(cols)
                    let x = CGFloat((colFrac - lo) / span) * size.width
                    var top = mid - (CGFloat(envelope.maxs[i]) - center) * scale
                    var bot = mid - (CGFloat(envelope.mins[i]) - center) * scale
                    if bot - top < 1 { top -= 0.5; bot += 0.5 }
                    path.move(to: CGPoint(x: x, y: top))
                    path.addLine(to: CGPoint(x: x, y: bot))
                }
                ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                .padding(4)
        }
        .overlay(Divider(), alignment: .bottom)
    }
}

#Preview {
    let cols = 64
    let envelope = XdfChannelEnvelope(
        mins: (0..<cols).map { Float(sin(Double($0) / 4)) - 0.1 },
        maxs: (0..<cols).map { Float(sin(Double($0) / 4)) + 0.1 })
    return ChannelLaneView(envelope: envelope, label: "Ch 1")
        .frame(width: 400, height: 80)
        .padding()
}
