import SwiftUI

/// Compact, single-row rendering of a min/max envelope — used inline in
/// `StreamCardView`. Deliberately simple (no playhead, no interaction) so it
/// reads as a sparkline rather than a full waveform view.
///
/// Consumes the shared `XdfChannelEnvelope` decimation contract (see
/// `Decimation/EnvelopeDecimator.swift`) rather than a Stage-2-only
/// placeholder type, so real decimated data (Stage 3) and the flat fallback
/// envelope (`XdfChannelEnvelope.flat(columns:)`) both render through the
/// same draw code, including the degenerate flat (min == max) case, which is
/// nudged apart by 0.5pt below so an all-zero flat envelope still renders as
/// a centered line rather than disappearing.
public struct WaveformSparkline: View {
    public var envelope: XdfChannelEnvelope
    public var color: Color
    public var baselineColor: Color

    public init(envelope: XdfChannelEnvelope = .flat(columns: 48),
                 color: Color = XdfViewerSettings.shared.accentColor.color,
                 baselineColor: Color = Color(nsColor: .separatorColor)) {
        self.envelope = envelope
        self.color = color
        self.baselineColor = baselineColor
    }

    public var body: some View {
        Canvas { ctx, size in
            let cols = envelope.columnCount
            guard cols > 0, size.width > 0, size.height > 0 else { return }
            let mid = size.height / 2

            // Real per-stream envelopes (Stage 3) carry raw sample-unit
            // magnitudes (µV, g, normalized 0-1, ...), not audio's
            // pre-normalized [-1, 1] range, so auto-scale to this envelope's
            // own data range. A flat (min == max, e.g. all-zero fallback)
            // envelope degrades to `range == 0`, handled by the epsilon below
            // plus the existing top/bot nudge so it still renders as a
            // centered line rather than disappearing.
            let dataMin = envelope.dataMin
            let dataMax = envelope.dataMax
            let dataRange = CGFloat(max(dataMax - dataMin, .ulpOfOne))
            let center = CGFloat((dataMax + dataMin) / 2)
            let scale = (size.height / 2 * 0.9) / (dataRange / 2)

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: mid))
            baseline.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(baseline, with: .color(baselineColor), lineWidth: 0.5)

            var path = Path()
            let lineWidth = max(0.6, size.width / CGFloat(cols))
            for i in 0..<cols {
                let x = size.width * CGFloat(i) / CGFloat(cols)
                var top = mid - (CGFloat(envelope.maxs[i]) - center) * scale
                var bot = mid - (CGFloat(envelope.mins[i]) - center) * scale
                if bot - top < 1 { top -= 0.5; bot += 0.5 }
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: bot))
            }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        }
    }
}

#Preview {
    WaveformSparkline()
        .frame(width: 240, height: 32)
        .padding()
}
