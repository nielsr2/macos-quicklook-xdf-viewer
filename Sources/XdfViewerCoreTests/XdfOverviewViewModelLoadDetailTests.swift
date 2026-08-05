import XCTest
@testable import XdfViewerCore

/// Exercises `XdfOverviewViewModel.loadDetail(forStream:)`'s cache-once-per-
/// stream behavior: the whole-stream tier-2 decode pass must resolve
/// exactly once per stream (`detailLoaded` flips true, every channel gets a
/// non-nil `detail` and `isLoadingDetail` clears), and rapid duplicate calls
/// — before the first pass resolves, or after it already has — must not
/// disturb that state or re-trigger loading, following the same
/// `channelCount: 0`/no-chunks pattern `XdfOverviewViewModelTests` uses so
/// this doesn't depend on real sample decoding, only on the guard/caching
/// logic around it (`XdfEnvelopeReader.readEnvelopes` never throws and
/// degrades to a flat envelope when there's nothing to decode).
@MainActor
final class XdfOverviewViewModelLoadDetailTests: XCTestCase {

    private func stream(id: UInt32, channelCount: Int = 1) -> XdfStreamInfo {
        XdfStreamInfo(streamID: id,
                      name: "Stream\(id)",
                      type: "EEG",
                      channelCount: channelCount,
                      nominalSampleRate: 0,
                      channelFormat: .float32)
    }

    private func waitUntilDetailLoaded(_ model: XdfOverviewViewModel, streamID: UInt32, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.streamCards.first(where: { $0.streamID == streamID })?.detailLoaded != true, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testLoadDetailResolvesAndFillsEveryChannel() async throws {
        let document = XdfDocument(version: "1.0", streams: [stream(id: 1, channelCount: 2)], chunkIndex: [])
        let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/detail-basic.xdf"), document: document)

        model.loadDetail(forStream: 1)
        try await waitUntilDetailLoaded(model, streamID: 1)

        let card = try XCTUnwrap(model.streamCards.first(where: { $0.streamID == 1 }))
        XCTAssertTrue(card.detailLoaded)
        XCTAssertEqual(card.channels.count, 2)
        XCTAssertTrue(card.channels.allSatisfy { $0.detail != nil })
        XCTAssertTrue(card.channels.allSatisfy { !$0.isLoadingDetail })
    }

    func testDuplicateCallWhileInFlightDoesNotResetLoadedState() async throws {
        let document = XdfDocument(version: "1.0", streams: [stream(id: 1)], chunkIndex: [])
        let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/detail-inflight.xdf"), document: document)

        // Fire twice back-to-back, before the first Task.detached pass has a
        // chance to resolve — the second call must be a no-op (the in-flight
        // guard, `detailLoadingStreamIDs`), not a second concurrent decode.
        model.loadDetail(forStream: 1)
        model.loadDetail(forStream: 1)

        try await waitUntilDetailLoaded(model, streamID: 1)

        let card = try XCTUnwrap(model.streamCards.first(where: { $0.streamID == 1 }))
        XCTAssertTrue(card.detailLoaded)
        XCTAssertTrue(card.channels.allSatisfy { $0.detail != nil && !$0.isLoadingDetail })
    }

    func testCallAfterAlreadyLoadedIsNoOp() async throws {
        let document = XdfDocument(version: "1.0", streams: [stream(id: 1)], chunkIndex: [])
        let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/detail-cached.xdf"), document: document)

        model.loadDetail(forStream: 1)
        try await waitUntilDetailLoaded(model, streamID: 1)

        let detailBefore = model.streamCards.first(where: { $0.streamID == 1 })?.channels.first?.detail

        // Calling again after the stream is already cached must not flip
        // isLoadingDetail back on or otherwise disturb the resolved state.
        model.loadDetail(forStream: 1)

        let card = try XCTUnwrap(model.streamCards.first(where: { $0.streamID == 1 }))
        XCTAssertTrue(card.detailLoaded)
        XCTAssertFalse(card.channels.contains { $0.isLoadingDetail })
        XCTAssertEqual(card.channels.first?.detail, detailBefore)
    }

    func testUnknownStreamIsNoOp() {
        let document = XdfDocument(version: "1.0", streams: [stream(id: 1)], chunkIndex: [])
        let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/detail-unknown.xdf"), document: document)

        model.loadDetail(forStream: 999) // no matching stream — must not crash or affect stream 1
        XCTAssertFalse(model.streamCards.first(where: { $0.streamID == 1 })?.detailLoaded ?? true)
    }
}
