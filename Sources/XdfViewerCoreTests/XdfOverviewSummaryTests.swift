import XCTest
@testable import XdfViewerCore

/// Exercises `XdfOverviewViewModel.summary`, the Windows-style top-bar line
/// that replaced the redundant filename display: `"{n} stream(s) ·
/// {duration} · XDF v{version}"`, where the duration and version clauses are
/// each omitted (not shown as a placeholder) when unknown.
@MainActor
final class XdfOverviewSummaryTests: XCTestCase {

    private func stream(id: UInt32,
                         firstTimestamp: Double? = nil,
                         lastTimestamp: Double? = nil) -> XdfStreamInfo {
        XdfStreamInfo(streamID: id,
                      name: "Stream\(id)",
                      type: "EEG",
                      channelCount: 1,
                      nominalSampleRate: 100,
                      channelFormat: .float32,
                      firstTimestamp: firstTimestamp,
                      lastTimestamp: lastTimestamp)
    }

    func testZeroStreamsPluralizesAndOmitsDurationAndVersion() {
        let document = XdfDocument(version: nil, streams: [], chunkIndex: [])
        let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/empty.xdf"), document: document)
        XCTAssertEqual(model.summary, "0 streams")
    }

    func testOneStreamUsesSingularNoun() {
        let document = XdfDocument(version: nil, streams: [stream(id: 1)], chunkIndex: [])
        let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/one.xdf"), document: document)
        XCTAssertEqual(model.summary, "1 stream")
    }

    func testTwoStreamsUsesPluralNoun() {
        let document = XdfDocument(version: nil, streams: [stream(id: 1), stream(id: 2)], chunkIndex: [])
        let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/two.xdf"), document: document)
        XCTAssertEqual(model.summary, "2 streams")
    }

    func testIncludesVersionWhenPresent() {
        let document = XdfDocument(version: "1.0", streams: [stream(id: 1)], chunkIndex: [])
        let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/v.xdf"), document: document)
        XCTAssertEqual(model.summary, "1 stream · XDF v1.0")
    }

    func testOmitsVersionClauseWhenNilOrEmpty() {
        let nilVersionDoc = XdfDocument(version: nil, streams: [stream(id: 1)], chunkIndex: [])
        let nilModel = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/nilv.xdf"), document: nilVersionDoc)
        XCTAssertFalse(nilModel.summary.contains("XDF v"))

        let emptyVersionDoc = XdfDocument(version: "", streams: [stream(id: 1)], chunkIndex: [])
        let emptyModel = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/emptyv.xdf"), document: emptyVersionDoc)
        XCTAssertFalse(emptyModel.summary.contains("XDF v"))
    }

    func testIncludesLongestStreamDuration() {
        let document = XdfDocument(version: "1.0",
                                    streams: [
                                        stream(id: 1, firstTimestamp: 0, lastTimestamp: 65),
                                        stream(id: 2, firstTimestamp: 0, lastTimestamp: 305),
                                    ],
                                    chunkIndex: [])
        let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/dur.xdf"), document: document)
        // Longest is stream 2's 305s -> "5:05" per StreamCardViewModel.formatDuration.
        XCTAssertEqual(model.summary, "2 streams · 5:05 · XDF v1.0")
    }

    func testOmitsDurationClauseWhenNoStreamHasAFooter() {
        let document = XdfDocument(version: "1.0", streams: [stream(id: 1)], chunkIndex: [])
        let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/nodur.xdf"), document: document)
        XCTAssertEqual(model.summary, "1 stream · XDF v1.0")
    }
}
