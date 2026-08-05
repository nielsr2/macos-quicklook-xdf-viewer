import XCTest
@testable import XdfViewerCore

/// Exercises the Stage 5 stream-count guardrail in
/// `XdfOverviewViewModel.startDecimation()`: a file declaring far more
/// streams than any real multi-modal LSL session should still resolve
/// (rather than spawning an unbounded number of concurrent decode tasks),
/// and should surface `decimationTruncated` so the UI can flag it.
@MainActor
final class XdfOverviewViewModelTests: XCTestCase {

    private func stream(id: UInt32) -> XdfStreamInfo {
        // channelCount 0 (and no sample count/chunks) makes
        // `XdfEnvelopeReader.readEnvelopes` fall into its flat-envelope guard
        // immediately, so this test isn't relying on real sample decoding —
        // only on the stream-count cap and phase bookkeeping around it.
        XdfStreamInfo(streamID: id,
                      name: "Stream\(id)",
                      type: "EEG",
                      channelCount: 0,
                      nominalSampleRate: 0,
                      channelFormat: .float32)
    }

    func testStreamCountBeyondCeilingSetsTruncatedAndStillResolves() async throws {
        let streams = (1...40).map(stream(id:))
        let document = XdfDocument(version: "1.0", streams: streams, chunkIndex: [])
        let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/many-streams.xdf"), document: document)

        model.startDecimation()
        XCTAssertTrue(model.decimationTruncated, "40 streams exceeds the decimation cap; truncation should be flagged")

        let deadline = Date().addingTimeInterval(5)
        while model.loadPhase != .detailReady, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.loadPhase, .detailReady, "capped streams must not prevent the phase from resolving")
    }

    func testStreamCountWithinCeilingIsNotTruncated() {
        let streams = (1...3).map(stream(id:))
        let document = XdfDocument(version: "1.0", streams: streams, chunkIndex: [])
        let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/few-streams.xdf"), document: document)

        model.startDecimation()
        XCTAssertFalse(model.decimationTruncated)
    }
}
