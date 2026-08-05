import SwiftUI

/// Compact whole-recording overview strip for `FullWaveformView`: renders
/// the already-decimated envelope for one representative channel (typically
/// `Array<XdfChannelEnvelope>.mostInformative()`, from `EnvelopeDecimator.swift`)
/// across the full duration at a glance, with a draggable/tappable viewport
/// rectangle showing the current pan/zoom window. No second decimation pass —
/// this reuses the same fixed-resolution envelope `FullWaveformView` already
/// loaded for the lanes.
public struct MinimapView: View {
    public var envelope: XdfChannelEnvelope
    /// Current visible window, expressed as a 0...1 fraction of the total
    /// duration (e.g. `0.2...0.35` means the viewport shows the 20%-35%
    /// span of the recording). Matches `offset`/`contentWidth` math in
    /// `FullWaveformView.waveformArea`.
    public var viewportRange: ClosedRange<Double>
    /// Called with a 0...1 fraction of the total duration representing
    /// where the viewport's *center* should move to, on tap or drag.
    public var onSeek: (Double) -> Void

    public var color: Color = Color(nsColor: .controlAccentColor)

    public init(envelope: XdfChannelEnvelope,
                viewportRange: ClosedRange<Double>,
                color: Color = Color(nsColor: .controlAccentColor),
                onSeek: @escaping (Double) -> Void) {
        self.envelope = envelope
        self.viewportRange = viewportRange
        self.color = color
        self.onSeek = onSeek
    }

    public var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)
            let viewportX = width * CGFloat(viewportRange.lowerBound)
            let viewportWidth = max(3, width * CGFloat(viewportRange.upperBound - viewportRange.lowerBound))

            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)

                Canvas { ctx, size in
                    let cols = envelope.columnCount
                    guard cols > 0, size.width > 0, size.height > 0 else { return }
                    let dataMin = envelope.dataMin
                    let dataMax = envelope.dataMax
                    let dataRange = CGFloat(max(dataMax - dataMin, .ulpOfOne))
                    let mid = size.height / 2
                    let center = CGFloat((dataMax + dataMin) / 2)
                    let scale = (size.height / 2 * 0.9) / (dataRange / 2)

                    var path = Path()
                    for i in 0..<cols {
                        let x = size.width * CGFloat(i) / CGFloat(cols)
                        var top = mid - (CGFloat(envelope.maxs[i]) - center) * scale
                        var bot = mid - (CGFloat(envelope.mins[i]) - center) * scale
                        if bot - top < 1 { top -= 0.5; bot += 0.5 }
                        path.move(to: CGPoint(x: x, y: top))
                        path.addLine(to: CGPoint(x: x, y: bot))
                    }
                    ctx.stroke(path, with: .color(.secondary), lineWidth: 1)
                }

                // Viewport rectangle showing the current pan/zoom window.
                Rectangle()
                    .fill(color.opacity(0.18))
                    .overlay(Rectangle().stroke(color, lineWidth: 1.5))
                    .frame(width: viewportWidth, height: height)
                    .offset(x: viewportX)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = Double(min(max(value.location.x / width, 0), 1))
                        onSeek(fraction)
                    }
            )
            .clipped()
        }
        .frame(height: 30)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }
}

#Preview {
    func wave(amplitude: Float, phase: Float, cols: Int) -> XdfChannelEnvelope {
        var mins = [Float](repeating: 0, count: cols)
        var maxs = [Float](repeating: 0, count: cols)
        for i in 0..<cols {
            let v = sin(Float(i) / 12 + phase) * amplitude
            mins[i] = v - amplitude * 0.1
            maxs[i] = v + amplitude * 0.1
        }
        return XdfChannelEnvelope(mins: mins, maxs: maxs)
    }

    return MinimapView(envelope: wave(amplitude: 40, phase: 0, cols: 300),
                        viewportRange: 0.2...0.35,
                        onSeek: { _ in })
        .frame(width: 780)
        .padding()
}
