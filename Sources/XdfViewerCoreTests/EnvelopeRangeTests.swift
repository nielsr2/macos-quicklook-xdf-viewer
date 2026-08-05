import XCTest
@testable import XdfViewerCore

/// Covers the cached `dataMin`/`dataMax`/`peakToPeak` on `XdfChannelEnvelope`
/// (the perf fix that replaced per-redraw `mins.min()`/`maxs.max()` scans) and
/// the `mostInformative()` selection that now relies on the cached range.
final class EnvelopeRangeTests: XCTestCase {

    func testCachedRangeMatchesArrayExtremes() {
        let env = XdfChannelEnvelope(mins: [-3, -1, -7, 2], maxs: [4, 9, 1, 5])
        XCTAssertEqual(env.dataMin, -7)
        XCTAssertEqual(env.dataMax, 9)
        XCTAssertEqual(env.peakToPeak, 16)
    }

    func testFlatEnvelopeHasZeroRange() {
        let env = XdfChannelEnvelope.flat(columns: 32)
        XCTAssertEqual(env.dataMin, 0)
        XCTAssertEqual(env.dataMax, 0)
        XCTAssertEqual(env.peakToPeak, 0)
    }

    func testMostInformativePicksLargestPeakToPeak() {
        let flat = XdfChannelEnvelope.flat(columns: 8)
        let small = XdfChannelEnvelope(mins: [-1, -1], maxs: [1, 1])       // p2p 2
        let big = XdfChannelEnvelope(mins: [-50, -40], maxs: [40, 60])     // p2p 110
        let picked = [flat, small, big].mostInformative()
        XCTAssertEqual(picked, big)
    }

    func testMostInformativeReturnsNilForEmptyArray() {
        let none: [XdfChannelEnvelope] = []
        XCTAssertNil(none.mostInformative())
    }
}
