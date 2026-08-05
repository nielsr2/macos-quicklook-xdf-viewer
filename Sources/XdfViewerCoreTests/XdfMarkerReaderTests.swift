import XCTest
@testable import XdfViewerCore

/// Hand-builds a minimal single-channel string-format `.xdf` marker stream
/// and verifies `XdfMarkerReader` decodes labels and timestamps correctly.
final class XdfMarkerReaderTests: XCTestCase {

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

    private func doubleLE(_ value: Double) -> Data {
        uint64LE(value.bitPattern)
    }

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

    /// One `Samples` chunk with `events.count` samples, each with an
    /// explicit timestamp (flag 0x08) and one var-length-prefixed string.
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
            .appendingPathComponent("xdf-marker-test-\(UUID().uuidString).xdf")
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

    func testDecodesTimestampedLabelsInOrder() throws {
        let events: [(timestamp: Double, label: String)] = [
            (1.5, "trial_start"),
            (4.25, "stimulus_on"),
            (9.0, "trial_end"),
        ]
        var data = fileMagic
        data.append(streamHeaderChunk(streamID: 7, xml: markerStreamHeaderXML))
        data.append(markerSamplesChunk(streamID: 7, events: events))

        let url = try writeTempFile(data)
        let document = try XdfReader.readStructure(url: url)
        let stream = try XCTUnwrap(document.streams.first)
        let chunks = document.chunks(forStream: stream.streamID)

        let decoded = XdfMarkerReader.readMarkers(url: url,
                                                    chunks: chunks,
                                                    channelCount: stream.channelCount,
                                                    channelFormat: stream.channelFormat)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0], XdfMarkerEvent(timestamp: 1.5, label: "trial_start"))
        XCTAssertEqual(decoded[1], XdfMarkerEvent(timestamp: 4.25, label: "stimulus_on"))
        XCTAssertEqual(decoded[2], XdfMarkerEvent(timestamp: 9.0, label: "trial_end"))
    }

    func testNonStringFormatReturnsEmpty() {
        let decoded = XdfMarkerReader.readMarkers(url: URL(fileURLWithPath: "/nonexistent"),
                                                    chunks: [],
                                                    channelCount: 1,
                                                    channelFormat: .float32)
        XCTAssertTrue(decoded.isEmpty)
    }

    func testMultiChannelStringFormatReturnsEmpty() {
        // Multi-channel string streams have no established "label" convention.
        let decoded = XdfMarkerReader.readMarkers(url: URL(fileURLWithPath: "/nonexistent"),
                                                    chunks: [XdfChunkIndex(streamID: 1, fileOffset: 0, byteLength: 10, declaredSampleCount: 1)],
                                                    channelCount: 2,
                                                    channelFormat: .string)
        XCTAssertTrue(decoded.isEmpty)
    }
}
