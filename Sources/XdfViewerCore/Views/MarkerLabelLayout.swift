import CoreGraphics

/// One placed marker label: which candidate it is (`index` into the caller's
/// parallel `xs`/`widths` arrays), the x-position it was placed at, and which
/// stagger `row` it landed in (0 == top).
public struct LabelPlacement: Equatable {
    public let index: Int
    public let x: CGFloat
    public let row: Int

    public init(index: Int, x: CGFloat, row: Int) {
        self.index = index
        self.x = x
        self.row = row
    }
}

/// Pure, testable marker-label stagger, ported from the upstream C# viewer's
/// v1.1.0 legibility fix. Replaces the old greedy single-row declutter (which
/// dropped every label that would overlap its predecessor) with a small stack
/// of rows: each label falls into the first row that has horizontal space for
/// it, only being dropped when *every* row is already occupied at that x.
///
/// Deliberately free of SwiftUI so it can be unit-tested in isolation; the
/// tick lines themselves are still drawn by `MarkerOverlay` for every marker
/// regardless of whether its label survives this pass.
public enum MarkerLabelLayout {
    /// - Parameters:
    ///   - xs: candidate label positions (left edges), expected ASCENDING.
    ///   - widths: estimated label widths, parallel to `xs` (a missing entry
    ///     is treated as width 0).
    ///   - rowCount: number of stagger rows; values < 1 are treated as 1.
    ///   - maxLabels: hard cap on total placements (the walk stops once it is
    ///     reached); values <= 0 place nothing.
    ///   - gap: minimum horizontal gap enforced after each placed label;
    ///     values < 0 are treated as 0.
    /// - Returns: the placed labels, in walk order.
    public static func place(xs: [CGFloat],
                             widths: [CGFloat],
                             rowCount: Int,
                             maxLabels: Int,
                             gap: CGFloat) -> [LabelPlacement] {
        let rows = max(1, rowCount)
        let g = max(0, gap)
        var occupiedTo = [CGFloat](repeating: -.greatestFiniteMagnitude, count: rows)
        var result: [LabelPlacement] = []
        guard maxLabels > 0 else { return result }

        for i in xs.indices {
            if result.count >= maxLabels { break }
            let x = xs[i]
            let w = i < widths.count ? widths[i] : 0
            for r in 0..<rows where occupiedTo[r] <= x {
                occupiedTo[r] = x + w + g
                result.append(LabelPlacement(index: i, x: x, row: r))
                break
            }
        }
        return result
    }
}
