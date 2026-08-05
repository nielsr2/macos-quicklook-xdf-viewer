import SwiftUI

/// Vertical value-tick axis shown alongside a single-channel plot (e.g.
/// `SoloChannelView`): the Y-axis counterpart to `TimeAxis` — three labels
/// (top/center/bottom of the plot's currently-visible auto-scaled range,
/// accounting for `amplitudeScale`) so exact values are readable at a
/// glance instead of only via the hover crosshair.
///
/// Deliberately simple: unlike `ChannelLaneView`'s drawing (which pads the
/// waveform 15% from each edge so peaks don't touch the frame), this labels
/// the value at the very top/middle/bottom of the view's height. That's a
/// small, consistent approximation — matching the original Windows
/// plugin's Y-axis closely enough for "read the value at a glance" without
/// needing pixel-exact agreement with the padded waveform drawing.
public struct ValueAxis: View {
    public var envelope: XdfChannelEnvelope
    public var amplitudeScale: CGFloat
    public var unit: String?

    public init(envelope: XdfChannelEnvelope, amplitudeScale: CGFloat = 1, unit: String? = nil) {
        self.envelope = envelope
        self.amplitudeScale = amplitudeScale
        self.unit = unit
    }

    /// Value shown at the top and bottom of the view, plus the center
    /// (unaffected by `amplitudeScale` — zooming narrows the visible range
    /// symmetrically around the same center, it doesn't shift it).
    private var scaleValues: (top: Double, center: Double, bottom: Double) {
        let dataMin = Double(envelope.dataMin)
        let dataMax = Double(envelope.dataMax)
        let dataRange = max(dataMax - dataMin, .ulpOfOne)
        let center = (dataMax + dataMin) / 2
        let halfVisible = (dataRange / 2) / Double(max(amplitudeScale, 0.0001))
        return (center + halfVisible, center, center - halfVisible)
    }

    public var body: some View {
        let values = scaleValues
        VStack(spacing: 0) {
            label(values.top)
            Spacer(minLength: 0)
            label(values.center)
            Spacer(minLength: 0)
            label(values.bottom)
        }
        .frame(width: 64)
        .allowsHitTesting(false)
    }

    private func label(_ value: Double) -> some View {
        Text(Self.format(value) + (unit.map { $0.isEmpty ? "" : " \($0)" } ?? ""))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// Scientific notation for very small/large magnitudes (typical of raw
    /// EMG/EEG voltages), otherwise a plain 4-significant-figure number.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        return String(format: "%.4g", value)
    }
}

#Preview {
    let cols = 8
    let envelope = XdfChannelEnvelope(mins: [Float](repeating: -0.00109, count: cols),
                                       maxs: [Float](repeating: 0.001031, count: cols))
    return ValueAxis(envelope: envelope, amplitudeScale: 1, unit: "V")
        .frame(height: 240)
        .padding()
        .background(Color(nsColor: .textBackgroundColor))
}
