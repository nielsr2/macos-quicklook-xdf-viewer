import SwiftUI

/// Renders marker/event ticks over `FullWaveformView`'s stacked channel
/// lanes: a thin vertical line at each marker's x-position plus a small,
/// decluttered label. Markers belong to the *file* (any single-channel
/// string-format stream, per `XdfMarkerReader`), not the currently selected
/// data stream — this view positions them against whichever stream's
/// timeline is currently on screen by taking that stream's
/// `firstTimestamp` as the zero point, using the exact same
/// `pointsPerSecond`/`offset` math `FullWaveformView.waveformArea` uses for
/// the lanes and `TimeAxis`.
///
/// Purely presentational: it draws into a `Canvas` sized to fill its parent
/// and does not participate in hit-testing, so it never competes with the
/// pan/zoom/hover gestures on the lanes underneath.
public struct MarkerOverlay: View {
    public var markers: [XdfMarkerEvent]
    /// Zero point on the timeline — typically the selected stream's
    /// `firstTimestamp`. Marker timestamps are absolute; this converts them
    /// to the same stream-relative seconds the lanes/axis use.
    public var streamStartTimestamp: Double
    /// Horizontal density of the timeline at the current zoom level (points
    /// per second) — matches `waveformArea`'s `pointsPerSecond`.
    public var pointsPerSecond: CGFloat
    /// Current horizontal scroll offset, in points — matches `waveformArea`'s
    /// `offset`.
    public var offset: CGFloat
    public var lineColor: Color = .orange
    /// Number of stagger rows the labels may occupy (Windows 1.1.0 legibility
    /// fix). Not part of the memberwise init below so existing call sites are
    /// untouched; overridable via `.rowCount` if ever needed.
    public var rowCount: Int = 3
    /// Hard cap on how many labels are drawn at once, regardless of stagger.
    public var maxLabels: Int = 80
    /// Minimum horizontal gap enforced between labels sharing a row.
    public var labelGap: CGFloat = 6

    public init(markers: [XdfMarkerEvent],
                streamStartTimestamp: Double,
                pointsPerSecond: CGFloat,
                offset: CGFloat,
                lineColor: Color = .orange) {
        self.markers = markers
        self.streamStartTimestamp = streamStartTimestamp
        self.pointsPerSecond = pointsPerSecond
        self.offset = offset
        self.lineColor = lineColor
    }

    /// One in-window labeled marker awaiting placement.
    private struct Candidate {
        let center: CGFloat
        let leftEdge: CGFloat
        let width: CGFloat
        let text: String
    }

    public var body: some View {
        Canvas { ctx, size in
            guard !markers.isEmpty, pointsPerSecond > 0, size.width > 0, size.height > 0 else { return }

            // First pass: draw every in-window tick line (always shown, even
            // if its label ends up dropped) and collect label candidates.
            var candidates: [Candidate] = []
            for marker in markers {
                let relativeSeconds = marker.timestamp - streamStartTimestamp
                guard relativeSeconds.isFinite else { continue }
                let x = CGFloat(relativeSeconds) * pointsPerSecond - offset
                guard x >= -20, x <= size.width + 20 else { continue }

                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(line, with: .color(lineColor.opacity(0.55)), lineWidth: 1)

                let label = marker.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { continue }
                let truncated = label.count > 22 ? String(label.prefix(21)) + "…" : label
                // Cheap width estimate (caption2 monospaced-ish average glyph
                // width) — avoids the cost of a real text-measurement pass
                // for what's just a decluttering heuristic.
                let estimatedWidth = CGFloat(truncated.count) * 5.4 + 8
                candidates.append(Candidate(center: x,
                                            leftEdge: x - estimatedWidth / 2,
                                            width: estimatedWidth,
                                            text: truncated))
            }

            guard !candidates.isEmpty else { return }
            // The layout helper expects ascending xs; sort defensively (marker
            // timestamps are usually already sorted, so this is near-free).
            candidates.sort { $0.leftEdge < $1.leftEdge }

            // Second pass: stagger labels across rows, dropping any that can't
            // fit in any row at their x.
            let placements = MarkerLabelLayout.place(xs: candidates.map { $0.leftEdge },
                                                     widths: candidates.map { $0.width },
                                                     rowCount: rowCount,
                                                     maxLabels: maxLabels,
                                                     gap: labelGap)

            let rowHeight: CGFloat = 13
            let rowSpacing: CGFloat = 1
            for placement in placements {
                let cand = candidates[placement.index]
                let y = 1 + CGFloat(placement.row) * (rowHeight + rowSpacing)
                let chipRect = CGRect(x: cand.leftEdge, y: y, width: cand.width, height: rowHeight)
                ctx.fill(Path(roundedRect: chipRect, cornerRadius: 3), with: .color(lineColor.opacity(0.85)))
                ctx.draw(Text(cand.text).font(.caption2).foregroundStyle(.white),
                          at: CGPoint(x: cand.center, y: y + rowHeight / 2),
                          anchor: .center)
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    MarkerOverlay(markers: [
        XdfMarkerEvent(timestamp: 1.5, label: "trial_start"),
        XdfMarkerEvent(timestamp: 4.25, label: "stimulus_on"),
        XdfMarkerEvent(timestamp: 4.4, label: "fixation"),
        XdfMarkerEvent(timestamp: 9.0, label: "trial_end"),
        XdfMarkerEvent(timestamp: 18.0, label: "block_2_start_with_a_long_label"),
    ], streamStartTimestamp: 0, pointsPerSecond: 80, offset: 0)
        .frame(width: 780, height: 240)
        .background(Color(nsColor: .textBackgroundColor))
}
