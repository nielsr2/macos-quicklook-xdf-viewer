import XCTest
@testable import XdfViewerCore

/// Exercises `TimeAxis` label formatting, in particular the Windows 1.1.0
/// sub-second precision fix (`decimalsFor` + `formatTime(_:step:)`).
final class TimeAxisLabelTests: XCTestCase {

    // MARK: decimalsFor

    func testDecimalsForWholeSecondSteps() {
        XCTAssertEqual(TimeAxis.decimalsFor(step: 1), 0)
        XCTAssertEqual(TimeAxis.decimalsFor(step: 2), 0)
        XCTAssertEqual(TimeAxis.decimalsFor(step: 5), 0)
        XCTAssertEqual(TimeAxis.decimalsFor(step: 60), 0)
    }

    func testDecimalsForSubSecondSteps() {
        XCTAssertEqual(TimeAxis.decimalsFor(step: 0.5), 1)
        XCTAssertEqual(TimeAxis.decimalsFor(step: 0.2), 1)
        XCTAssertEqual(TimeAxis.decimalsFor(step: 0.1), 1)
        XCTAssertEqual(TimeAxis.decimalsFor(step: 0.05), 2)
        XCTAssertEqual(TimeAxis.decimalsFor(step: 0.02), 2)
        XCTAssertEqual(TimeAxis.decimalsFor(step: 0.01), 2)
        XCTAssertEqual(TimeAxis.decimalsFor(step: 0.005), 3)
        XCTAssertEqual(TimeAxis.decimalsFor(step: 0.001), 3)
    }

    func testDecimalsForClampsAndGuards() {
        XCTAssertEqual(TimeAxis.decimalsFor(step: 1e-12), 9) // clamped to 9
        XCTAssertEqual(TimeAxis.decimalsFor(step: 0), 0)
        XCTAssertEqual(TimeAxis.decimalsFor(step: -1), 0)
    }

    // MARK: formatTime with step

    func testStepAtOrAboveOneSecondMatchesWholeSecondFormat() {
        XCTAssertEqual(TimeAxis.formatTime(200, step: 1), TimeAxis.formatTime(200))
        XCTAssertEqual(TimeAxis.formatTime(200, step: 1), "3:20")
        XCTAssertEqual(TimeAxis.formatTime(200.7, step: 5), TimeAxis.formatTime(200.7))
    }

    func testSubSecondStepIncludesFractionalDigits() {
        XCTAssertEqual(TimeAxis.formatTime(200.5, step: 0.5), "3:20.5")
        XCTAssertEqual(TimeAxis.formatTime(200.52, step: 0.02), "3:20.52")
        XCTAssertEqual(TimeAxis.formatTime(3, step: 0.5), "0:03.0")
    }

    func testAdjacentSubSecondTicksReadAsDistinct() {
        // The whole bug: at whole-second precision these three ticks all
        // showed "3:20"; with the step-aware formatter they differ.
        let a = TimeAxis.formatTime(200.0, step: 0.5)
        let b = TimeAxis.formatTime(200.5, step: 0.5)
        let c = TimeAxis.formatTime(201.0, step: 0.5)
        XCTAssertEqual(a, "3:20.0")
        XCTAssertEqual(b, "3:20.5")
        XCTAssertEqual(c, "3:21.0")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
    }

    func testSubSecondFormatKeepsHoursComponent() {
        // 1h 1m 1.5s.
        XCTAssertEqual(TimeAxis.formatTime(3661.5, step: 0.5), "1:01:01.5")
    }
}
