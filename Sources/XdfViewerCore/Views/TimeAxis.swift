import SwiftUI

/// Horizontal time-tick axis shown under `FullWaveformView`, drawn to match
/// its current pan/zoom window: given the same `contentWidth` (the whole
/// stream duration mapped to pixels) and `offset` (current horizontal scroll
/// position) the waveform lanes use, this draws evenly spaced tick marks and
/// seconds/mm:ss labels across the visible span.
///
/// MVP scope only — no crosshair readout or scrubber, both deferred.
public struct TimeAxis: View {
    /// Total stream duration in seconds.
    public var duration: Double
    /// Width, in points, that `duration` seconds maps to at the current zoom
    /// level (i.e. the full unclipped content width of the waveform lanes).
    public var contentWidth: CGFloat
    /// Width, in points, of the visible viewport (matches the waveform
    /// area's `GeometryReader` width).
    public var visibleWidth: CGFloat
    /// Current horizontal scroll offset, in points, into `contentWidth`.
    public var offset: CGFloat

    public init(duration: Double, contentWidth: CGFloat, visibleWidth: CGFloat, offset: CGFloat) {
        self.duration = duration
        self.contentWidth = contentWidth
        self.visibleWidth = visibleWidth
        self.offset = offset
    }

    public var body: some View {
        Canvas { ctx, size in
            guard duration > 0, contentWidth > 0, size.width > 0 else { return }
            let pixelsPerSecond = contentWidth / CGFloat(duration)
            guard pixelsPerSecond > 0 else { return }

            let visibleStart = Double(offset / pixelsPerSecond)
            let visibleEnd = Double((offset + visibleWidth) / pixelsPerSecond)
            let visibleSpan = max(visibleEnd - visibleStart, 0.001)

            let step = Self.niceStep(forSpan: visibleSpan, targetTicks: 6)
            guard step > 0 else { return }

            var top = Path()
            top.move(to: CGPoint(x: 0, y: 0))
            top.addLine(to: CGPoint(x: size.width, y: 0))
            ctx.stroke(top, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)

            var t = (visibleStart / step).rounded(.down) * step
            while t <= visibleEnd + step {
                if t >= -step {
                    let x = CGFloat(t) * pixelsPerSecond - offset
                    if x >= -40 && x <= size.width + 40 {
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: 0))
                        tick.addLine(to: CGPoint(x: x, y: 5))
                        ctx.stroke(tick, with: .color(.secondary), lineWidth: 1)

                        let label = Self.formatTime(max(0, t), step: step)
                        ctx.draw(Text(label).font(.caption2).foregroundStyle(.secondary),
                                  at: CGPoint(x: x, y: size.height - 2),
                                  anchor: .bottom)
                    }
                }
                t += step
            }
        }
    }

    /// Picks a "nice" tick spacing (1/2/5 × a power of ten) that yields
    /// roughly `targetTicks` ticks across `span` seconds.
    static func niceStep(forSpan span: Double, targetTicks: Int) -> Double {
        guard span > 0, targetTicks > 0 else { return 1 }
        let rawStep = span / Double(targetTicks)
        guard rawStep > 0, rawStep.isFinite else { return 1 }
        let magnitude = pow(10, (log10(rawStep)).rounded(.down))
        let residual = rawStep / magnitude
        let niceResidual: Double
        if residual < 1.5 { niceResidual = 1 }
        else if residual < 3 { niceResidual = 2 }
        else if residual < 7 { niceResidual = 5 }
        else { niceResidual = 10 }
        return niceResidual * magnitude
    }

    /// Formats seconds as `m:ss` or `h:mm:ss` for longer spans (whole-second
    /// precision). Used by the crosshair readouts and, via `formatTime(_:step:)`,
    /// by the axis when the tick step is >= 1 second.
    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 { return String(format: "%d:%02d:%02d", hrs, mins, secs) }
        return String(format: "%d:%02d", mins, secs)
    }

    /// Number of fractional-second digits needed to tell two ticks `step`
    /// seconds apart from each other: `ceil(-log10(step))`, clamped to 0...9.
    /// A step >= 1 s needs no decimals (0); a 0.5 s step needs 1; a 0.02 s
    /// step needs 2; a 0.001 s step needs 3.
    static func decimalsFor(step: Double) -> Int {
        guard step > 0, step.isFinite else { return 0 }
        if step >= 1 { return 0 }
        // Nudge down by an epsilon so a step that is mathematically 10^-n
        // (e.g. 0.01 -> 2.0) doesn't round up to n+1 on a tiny FP overshoot.
        let raw = -log10(step) - 1e-9
        return min(9, max(0, Int(raw.rounded(.up))))
    }

    /// Axis label formatter that respects the tick `step`: whole-second
    /// `m:ss` / `h:mm:ss` when `step >= 1`, otherwise `m:ss.ddd` with just
    /// enough fractional digits (from `decimalsFor`) that adjacent sub-second
    /// ticks read as distinct values — the Windows 1.1.0 sub-second fix.
    static func formatTime(_ seconds: Double, step: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let decimals = decimalsFor(step: step)
        guard decimals > 0 else { return formatTime(seconds) }

        let whole = Int(seconds)
        let hrs = whole / 3600
        let mins = (whole % 3600) / 60
        let secs = seconds - Double(hrs * 3600 + mins * 60)
        // "SS.ddd": 2 integer digits + '.' + `decimals` fractional digits.
        let secStr = String(format: "%0\(decimals + 3).\(decimals)f", secs)
        if hrs > 0 { return String(format: "%d:%02d:", hrs, mins) + secStr }
        return String(format: "%d:", mins) + secStr
    }
}

#Preview {
    TimeAxis(duration: 305.5, contentWidth: 2000, visibleWidth: 600, offset: 400)
        .frame(width: 600, height: 22)
        .padding()
}
