import XCTest
@testable import XdfViewerCore

/// Hand-builds minimal, synthetic `.xdf` byte sequences and exercises
/// `XdfReader.readStructure` against them. No external fixture files are used
/// here on purpose — real sample recordings will be added later.
final class XdfReaderTests: XCTestCase {

    // MARK: - Byte-building helpers

    /// Encodes `value` using the XDF variable-length-count scheme: a 1-byte
    /// width selector followed by that many little-endian bytes.
    private func varLength(_ value: UInt64, width: Int = 4) -> Data {
        var data = Data([UInt8(width)])
        for i in 0..<width {
            data.append(UInt8((value >> (8 * i)) & 0xFF))
        }
        return data
    }

    private func uint32LE(_ value: UInt32) -> Data {
        var data = Data()
        for i in 0..<4 {
            data.append(UInt8((value >> (8 * i)) & 0xFF))
        }
        return data
    }

    /// Wraps `content` in the outer `[NumLengthBytes][Length][Tag]` chunk framing.
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

    private func fileHeaderChunk(version: String = "1.0") -> Data {
        let xml = "<info><version>\(version)</version></info>"
        return chunk(tag: 1, content: Data(xml.utf8))
    }

    private func streamHeaderChunk(streamID: UInt32, xml: String) -> Data {
        var content = uint32LE(streamID)
        content.append(Data(xml.utf8))
        return chunk(tag: 2, content: content)
    }

    private func samplesChunk(streamID: UInt32, sampleCount: UInt64, payload: Data = Data(repeating: 0, count: 16)) -> Data {
        var content = uint32LE(streamID)
        content.append(varLength(sampleCount, width: 4))
        content.append(payload)
        return chunk(tag: 3, content: content)
    }

    private func streamFooterChunk(streamID: UInt32, xml: String) -> Data {
        var content = uint32LE(streamID)
        content.append(Data(xml.utf8))
        return chunk(tag: 6, content: content)
    }

    private let validStreamHeaderXML = """
    <info>
      <name>TestStream</name>
      <type>EEG</type>
      <channel_count>2</channel_count>
      <nominal_srate>100</nominal_srate>
      <channel_format>float32</channel_format>
      <desc>
        <channels>
          <channel><label>Ch1</label><unit>uV</unit><type>EEG</type></channel>
          <channel><label>Ch2</label><unit>uV</unit><type>EEG</type></channel>
        </channels>
      </desc>
    </info>
    """

    private let validStreamFooterXML = """
    <info>
      <first_timestamp>0.0</first_timestamp>
      <last_timestamp>9.0</last_timestamp>
      <sample_count>2</sample_count>
      <effective_srate>99.9</effective_srate>
    </info>
    """

    /// Writes `data` to a fresh temp file and returns its URL. The caller does
    /// not need to clean up — each test uses a unique NSTemporaryDirectory path.
    private func writeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdf-reader-test-\(UUID().uuidString).xdf")
        try data.write(to: url)
        return url
    }

    // MARK: - Tests

    func testMinimalValidFileRoundTrips() throws {
        var data = fileMagic
        data.append(fileHeaderChunk())
        data.append(streamHeaderChunk(streamID: 1, xml: validStreamHeaderXML))
        data.append(samplesChunk(streamID: 1, sampleCount: 2))
        data.append(streamFooterChunk(streamID: 1, xml: validStreamFooterXML))

        let url = try writeTempFile(data)
        let document = try XdfReader.readStructure(url: url)

        XCTAssertEqual(document.version, "1.0")
        XCTAssertEqual(document.streams.count, 1)

        let stream = try XCTUnwrap(document.streams.first)
        XCTAssertEqual(stream.streamID, 1)
        XCTAssertEqual(stream.name, "TestStream")
        XCTAssertEqual(stream.type, "EEG")
        XCTAssertEqual(stream.channelCount, 2)
        XCTAssertEqual(stream.nominalSampleRate, 100)
        XCTAssertEqual(stream.channelFormat, .float32)
        XCTAssertEqual(stream.channels.count, 2)
        XCTAssertEqual(stream.channels[0].label, "Ch1")
        XCTAssertEqual(stream.channels[0].unit, "uV")
        XCTAssertEqual(stream.channels[1].label, "Ch2")
        XCTAssertEqual(stream.firstTimestamp, 0.0)
        XCTAssertEqual(stream.lastTimestamp, 9.0)
        XCTAssertEqual(stream.sampleCount, 2)
        XCTAssertEqual(stream.effectiveSampleRate, 99.9)
        XCTAssertEqual(stream.duration, 9.0)

        XCTAssertEqual(document.chunkIndex.count, 1)
        let indexEntry = try XCTUnwrap(document.chunkIndex.first)
        XCTAssertEqual(indexEntry.streamID, 1)
        XCTAssertEqual(indexEntry.declaredSampleCount, 2)
        XCTAssertEqual(document.chunks(forStream: 1).count, 1)
    }

    func testBadMagicThrows() throws {
        var data = Data("BAD!".utf8)
        data.append(fileHeaderChunk())

        let url = try writeTempFile(data)
        XCTAssertThrowsError(try XdfReader.readStructure(url: url)) { error in
            XCTAssertEqual(error as? XdfError, .badMagic)
        }
    }

    func testTruncatedFileThrows() throws {
        var data = fileMagic
        data.append(fileHeaderChunk())
        data.append(streamHeaderChunk(streamID: 1, xml: validStreamHeaderXML))
        // Cut the file off partway through the StreamHeader chunk's declared
        // content — the declared chunk Length now claims more bytes than
        // actually exist in the file.
        data.removeLast(20)

        let url = try writeTempFile(data)
        XCTAssertThrowsError(try XdfReader.readStructure(url: url)) { error in
            XCTAssertEqual(error as? XdfError, .truncated)
        }
    }

    func testUnknownTagIsSkippedAndRestOfFileStillParses() throws {
        var data = fileMagic
        data.append(fileHeaderChunk())
        // Tag 200 doesn't correspond to any known XdfChunkTag case.
        data.append(chunk(tag: 200, content: Data([0xAA, 0xBB, 0xCC, 0xDD])))
        data.append(streamHeaderChunk(streamID: 1, xml: validStreamHeaderXML))
        data.append(samplesChunk(streamID: 1, sampleCount: 2))
        data.append(streamFooterChunk(streamID: 1, xml: validStreamFooterXML))

        let url = try writeTempFile(data)
        let document = try XdfReader.readStructure(url: url)

        XCTAssertEqual(document.streams.count, 1)
        XCTAssertEqual(document.streams.first?.name, "TestStream")
        XCTAssertEqual(document.chunkIndex.count, 1)
    }

    func testMalformedStreamHeaderXMLDegradesToDefaults() throws {
        // Well-closed <name>, then an unclosed <channel_count> and no other
        // fields — the parser bails out partway but must not throw, and must
        // keep whatever it collected before things went wrong.
        let garbledXML = "<info><name>Foo</name><channel_count>abc"

        var data = fileMagic
        data.append(fileHeaderChunk())
        data.append(streamHeaderChunk(streamID: 42, xml: garbledXML))

        let url = try writeTempFile(data)
        let document = try XdfReader.readStructure(url: url)

        XCTAssertEqual(document.streams.count, 1)
        let stream = try XCTUnwrap(document.streams.first)
        XCTAssertEqual(stream.streamID, 42)
        XCTAssertEqual(stream.name, "Foo")
        XCTAssertEqual(stream.type, "") // never provided, defaults to empty.
        XCTAssertEqual(stream.channelCount, 0) // element never closed, stays default.
        XCTAssertEqual(stream.channelFormat, .float32) // default when missing.
        XCTAssertTrue(stream.channels.isEmpty)
    }
}
