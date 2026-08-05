import XCTest
import CoreGraphics
@testable import XdfViewerCore

/// Exercises the pure `MarkerLabelLayout.place` stagger used by
/// `MarkerOverlay` (the Windows 1.1.0 legibility fix).
final class MarkerLabelLayoutTests: XCTestCase {

    func testSpreadOutCandidatesAllStayInTopRow() {
        let xs: [CGFloat] = [0, 30, 60]
        let widths: [CGFloat] = [20, 20, 20]
        let placed = MarkerLabelLayout.place(xs: xs, widths: widths, rowCount: 3, maxLabels: 100, gap: 0)
        XCTAssertEqual(placed.count, 3)
        XCTAssertTrue(placed.allSatisfy { $0.row == 0 })
        XCTAssertEqual(placed.map { $0.index }, [0, 1, 2])
        XCTAssertEqual(placed.map { $0.x }, xs)
    }

    func testOverlappingCandidatesFillRowsTopFirst() {
        // Three mutually overlapping wide labels -> one per row, top-first.
        let xs: [CGFloat] = [0, 5, 10]
        let widths: [CGFloat] = [40, 40, 40]
        let placed = MarkerLabelLayout.place(xs: xs, widths: widths, rowCount: 3, maxLabels: 100, gap: 0)
        XCTAssertEqual(placed.count, 3)
        XCTAssertEqual(placed[0].row, 0)
        XCTAssertEqual(placed[1].row, 1)
        XCTAssertEqual(placed[2].row, 2)
    }

    func testCandidatesBeyondRowCapacityAreDropped() {
        // rowCount 2, three overlapping labels -> the third can't fit anywhere.
        let xs: [CGFloat] = [0, 1, 2]
        let widths: [CGFloat] = [100, 100, 100]
        let placed = MarkerLabelLayout.place(xs: xs, widths: widths, rowCount: 2, maxLabels: 100, gap: 0)
        XCTAssertEqual(placed.count, 2)
        XCTAssertEqual(placed.map { $0.index }, [0, 1])
        XCTAssertEqual(placed.map { $0.row }, [0, 1])
    }

    func testGapForcesFollowerToNextRow() {
        // Without a gap the second would fit in row 0 (30 >= 0+20); the gap
        // pushes the row-0 occupancy past it so it lands in row 1.
        let xs: [CGFloat] = [0, 25]
        let widths: [CGFloat] = [20, 20]
        let placed = MarkerLabelLayout.place(xs: xs, widths: widths, rowCount: 2, maxLabels: 100, gap: 10)
        XCTAssertEqual(placed.count, 2)
        XCTAssertEqual(placed[0].row, 0) // occupies up to 0+20+10 = 30
        XCTAssertEqual(placed[1].row, 1) // 25 < 30, so bumped down a row
    }

    func testMaxLabelsCapsTotalPlacements() {
        let xs: [CGFloat] = [0, 30, 60, 90]
        let widths: [CGFloat] = [10, 10, 10, 10]
        let placed = MarkerLabelLayout.place(xs: xs, widths: widths, rowCount: 3, maxLabels: 2, gap: 0)
        XCTAssertEqual(placed.count, 2)
        XCTAssertEqual(placed.map { $0.index }, [0, 1])
    }

    func testRowCountBelowOneIsTreatedAsOne() {
        let xs: [CGFloat] = [0, 5]
        let widths: [CGFloat] = [40, 40]
        let placed = MarkerLabelLayout.place(xs: xs, widths: widths, rowCount: 0, maxLabels: 100, gap: 0)
        // Single row -> the overlapping second candidate is dropped.
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed[0].row, 0)
        XCTAssertEqual(placed[0].index, 0)
    }

    func testNegativeGapIsTreatedAsZero() {
        // With gap clamped to 0, a follower exactly at the previous right edge
        // still fits in row 0.
        let xs: [CGFloat] = [0, 20]
        let widths: [CGFloat] = [20, 20]
        let placed = MarkerLabelLayout.place(xs: xs, widths: widths, rowCount: 2, maxLabels: 100, gap: -100)
        XCTAssertEqual(placed.count, 2)
        XCTAssertTrue(placed.allSatisfy { $0.row == 0 })
    }

    func testNonPositiveMaxLabelsPlacesNothing() {
        let xs: [CGFloat] = [0, 30]
        let widths: [CGFloat] = [10, 10]
        XCTAssertTrue(MarkerLabelLayout.place(xs: xs, widths: widths, rowCount: 3, maxLabels: 0, gap: 0).isEmpty)
        XCTAssertTrue(MarkerLabelLayout.place(xs: xs, widths: widths, rowCount: 3, maxLabels: -1, gap: 0).isEmpty)
    }

    func testEmptyInputProducesNoPlacements() {
        XCTAssertTrue(MarkerLabelLayout.place(xs: [], widths: [], rowCount: 3, maxLabels: 10, gap: 4).isEmpty)
    }

    func testMissingWidthTreatedAsZero() {
        // Fewer widths than xs: the short entry is treated as zero-width and
        // still placed.
        let xs: [CGFloat] = [0, 5]
        let widths: [CGFloat] = [10] // width for index 1 missing
        let placed = MarkerLabelLayout.place(xs: xs, widths: widths, rowCount: 2, maxLabels: 100, gap: 0)
        XCTAssertEqual(placed.count, 2)
        XCTAssertEqual(placed[1].index, 1)
    }
}
