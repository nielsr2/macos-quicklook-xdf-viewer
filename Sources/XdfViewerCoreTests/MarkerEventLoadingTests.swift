import XCTest
@testable import XdfViewerCore

/// Exercises `XdfOverviewViewModel.startMarkerEventLoading()` (triggered by
/// `startDecimation()`, mirroring the sparkline-decimation pattern) end to
/// end: a real single-channel string-format marker stream, decoded off the
/// main actor via `XdfMarkerReader`, published into the matching
/// `StreamCardViewModel.events` with times relative to the recording's
/// start. Also covers `StreamCardViewModel.formatEventTime` directly.
///
/// Reuses `XdfMarkerReaderTests`' minimal hand-built `.xdf` byte layout
/// (magic + one StreamHeader chunk + one Samples chunk of timestamped
/// strings) rather than duplicating a second encoder.
@MainActor
final class MarkerEventLoadingTests: XCTestCase {

    private func varLength(_ value: UInt64, width: Int = 4) -> Data {
        var data = Data([UInt8(width)])
        for i in 0..<width { data.append(UInt8((value >> (8 * i)) & 0xFF)) }
        return data
    }

    private func uint32LE(_ value: UInt32) -> Data {
        var data = Data()
        for i in 0..<4 { data.append(UInt8((value >> (8 * i)) & 0xFF)) }
        return data
    }

    private func doubleLE(_ value: Double) -> Data { uint64LE(value.bitPattern) }

    private func uint64LE(_ value: UInt64) -> Data {
        var data = Data()
        for i in 0..<8 { data.append(UInt8((value >> (8 * i)) & 0xFF)) }
        return data
    }

    private func chunk(tag: UInt16, content: Data) -> Data {
        var tagAndContent = Data()
        tagAndContent.append(UInt8(tag & 0xFF))
        tagAndContent.append(UInt8((tag >> 8) & 0xFF))
        tagAndContent.append(content)
        var result = varLength(UInt64(tagAndContent.count), width: 4)
        result.append(tagAndContent)
        return result
    }

    private var fileMagic: Data { Data("XDF:".utf8) }

    private func streamHeaderChunk(streamID: UInt32, xml: String) -> Data {
        var content = uint32LE(streamID)
        content.append(Data(xml.utf8))
        return chunk(tag: 2, content: content)
    }

    private func markerSamplesChunk(streamID: UInt32, events: [(timestamp: Double, label: String)]) -> Data {
        var content = uint32LE(streamID)
        content.append(varLength(UInt64(events.count), width: 4))
        for event in events {
            content.append(0x08) // explicit timestamp follows
            content.append(doubleLE(event.timestamp))
            let labelBytes = Data(event.label.utf8)
            content.append(varLength(UInt64(labelBytes.count), width: 1))
            content.append(labelBytes)
        }
        return chunk(tag: 3, content: content)
    }

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overview-marker-loading-test-\(UUID().uuidString).xdf")
        try data.write(to: url)
        return url
    }

    private let markerStreamHeaderXML = """
    <info>
      <name>Session-Markers</name>
      <type>Markers</type>
      <channel_count>1</channel_count>
      <nominal_srate>0</nominal_srate>
      <channel_format>string</channel_format>
    </info>
    """

    func testStartDecimationPublishesEventsRelativeToEarliestMarker() async throws {
        let events: [(timestamp: Double, label: String)] = [
            (10.0, "trial_start"),
            (24.0, "stimulus_on"),
            (70.0, "trial_end"),
        ]
        var data = fileMagic
        data.append(streamHeaderChunk(streamID: 7, xml: markerStreamHeaderXML))
        data.append(markerSamplesChunk(streamID: 7, events: events))
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try XdfReader.readStructure(url: url)
        let model = XdfOverviewViewModel(fileURL: url, document: document)
        model.startDecimation()

        let deadline = Date().addingTimeInterval(5)
        while model.streamCards.first?.events.isEmpty != false, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let card = try XCTUnwrap(model.streamCards.first)
        XCTAssertTrue(card.isMarkerStream)
        XCTAssertEqual(card.events.map(\.value), ["trial_start", "stimulus_on", "trial_end"])
        // Zero reference is the earliest marker timestamp (10.0) — so the
        // first event reads "0:00" and the rest are offset from it.
        XCTAssertEqual(card.events.map(\.timeLabel), ["0:00", "0:14", "1:00"])
    }

    func testNonMarkerStreamNeverGetsEvents() async throws {
        let stream = XdfStreamInfo(streamID: 1,
                                    name: "EEG",
                                    type: "EEG",
                                    channelCount: 0,
                                    nominalSampleRate: 0,
                                    channelFormat: .float32)
        let document = XdfDocument(version: "1.0", streams: [stream], chunkIndex: [])
        let model = XdfOverviewViewModel(fileURL: URL(fileURLWithPath: "/tmp/no-markers.xdf"), document: document)
        model.startDecimation()

        let deadline = Date().addingTimeInterval(2)
        while model.loadPhase != .detailReady, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(model.streamCards.first?.events, [])
        XCTAssertFalse(model.streamCards.first?.isMarkerStream ?? true)
    }

    // MARK: formatEventTime

    func testFormatEventTimeMinutesAndSeconds() {
        XCTAssertEqual(StreamCardViewModel.formatEventTime(0), "0:00")
        XCTAssertEqual(StreamCardViewModel.formatEventTime(14), "0:14")
        XCTAssertEqual(StreamCardViewModel.formatEventTime(65), "1:05")
    }

    func testFormatEventTimeHoursMinutesSeconds() {
        XCTAssertEqual(StreamCardViewModel.formatEventTime(3661), "1:01:01")
    }

    func testFormatEventTimeClampsNegativeToZero() {
        // The zero reference is always the minimum timestamp seen, so this
        // shouldn't occur in practice — but the formatter still shouldn't
        // produce a nonsensical negative time label if it ever did.
        XCTAssertEqual(StreamCardViewModel.formatEventTime(-5), "0:00")
    }
}
