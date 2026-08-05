import XCTest
@testable import XdfViewerCore

/// Exercises `XdfEnvelopeReader`/`XdfSampleDecoder` against a hand-built
/// single-channel `.xdf` file with known sample values, so the decimation
/// math (which Stage 3's full waveform view and Stage 4's thumbnail both
/// depend on) is verified before either is built.
final class XdfEnvelopeReaderTests: XCTestCase {

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

    private func float32LE(_ value: Float) -> Data {
        uint32LE(value.bitPattern)
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

    /// Builds a `Samples` chunk with `values.count` samples, one float32
    /// channel value each, no timestamps (flag byte 0x00).
    private func samplesChunk(streamID: UInt32, values: [Float]) -> Data {
        var content = uint32LE(streamID)
        content.append(varLength(UInt64(values.count), width: 4))
        for v in values {
            content.append(0x00) // timestampFlag: none
            content.append(float32LE(v))
        }
        return chunk(tag: 3, content: content)
    }

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdf-envelope-test-\(UUID().uuidString).xdf")
        try data.write(to: url)
        return url
    }

    private let singleChannelHeaderXML = """
    <info>
      <name>TestStream</name>
      <type>EEG</type>
      <channel_count>1</channel_count>
      <nominal_srate>4</nominal_srate>
      <channel_format>float32</channel_format>
    </info>
    """

    func testDecimatesKnownValuesIntoExpectedColumnMinMax() throws {
        let values: [Float] = [1, 5, 2, 8] // 4 samples, 2 columns -> [1,5] and [2,8]
        var data = fileMagic
        data.append(streamHeaderChunk(streamID: 1, xml: singleChannelHeaderXML))
        data.append(samplesChunk(streamID: 1, values: values))

        let url = try writeTempFile(data)
        let document = try XdfReader.readStructure(url: url)
        let stream = try XCTUnwrap(document.streams.first)
        let chunks = document.chunks(forStream: stream.streamID)

        let envelopes = XdfEnvelopeReader.readEnvelopes(url: url,
                                                          chunks: chunks,
                                                          channelCount: stream.channelCount,
                                                          channelFormat: stream.channelFormat,
                                                          totalSampleCount: values.count,
                                                          columns: 2)

        XCTAssertEqual(envelopes.count, 1)
        let env = envelopes[0]
        XCTAssertEqual(env.columnCount, 2)
        XCTAssertEqual(env.mins, [1, 2])
        XCTAssertEqual(env.maxs, [5, 8])
    }

    func testUnsupportedStringFormatReturnsFlatEnvelope() {
        let envelopes = XdfEnvelopeReader.readEnvelopes(url: URL(fileURLWithPath: "/nonexistent"),
                                                          chunks: [],
                                                          channelCount: 2,
                                                          channelFormat: .string,
                                                          totalSampleCount: 10,
                                                          columns: 5)
        XCTAssertEqual(envelopes.count, 2)
        for env in envelopes {
            XCTAssertEqual(env.columnCount, 5)
            XCTAssertEqual(env.mins, [Float](repeating: 0, count: 5))
            XCTAssertEqual(env.maxs, [Float](repeating: 0, count: 5))
        }
    }

    func testZeroTotalSampleCountReturnsFlatEnvelope() throws {
        let envelopes = XdfEnvelopeReader.readEnvelopes(url: URL(fileURLWithPath: "/nonexistent"),
                                                          chunks: [],
                                                          channelCount: 1,
                                                          channelFormat: .float32,
                                                          totalSampleCount: 0,
                                                          columns: 3)
        XCTAssertEqual(envelopes.count, 1)
        XCTAssertEqual(envelopes[0].columnCount, 3)
    }

    // MARK: - Guardrails (Stage 5): bounded decode work regardless of declared file size

    /// A stream whose *declared* sample count is huge (simulating a
    /// pathological or corrupt footer/chunk-length claim) but whose actual
    /// on-disk chunks are tiny must still resolve fast and safely — the
    /// guardrail must key off `maxSamplesToScan`, not blindly trust
    /// `totalSampleCount`/chunk declarations enough to attempt reading data
    /// that was never really there. Uses a small `maxSamplesToScan` so the
    /// test doesn't need a multi-million-sample fixture to exercise the
    /// stride-selection path.
    func testHugeDeclaredSampleCountDoesNotScanEveryChunk() throws {
        // Three 4-sample chunks with clearly separable value ranges so we can
        // tell which chunks actually got decoded.
        var data = fileMagic
        data.append(streamHeaderChunk(streamID: 1, xml: singleChannelHeaderXML))
        data.append(samplesChunk(streamID: 1, values: [1, 2, 3, 4]))
        data.append(samplesChunk(streamID: 1, values: [100, 101, 102, 103]))
        data.append(samplesChunk(streamID: 1, values: [200, 201, 202, 203]))

        let url = try writeTempFile(data)
        let document = try XdfReader.readStructure(url: url)
        let stream = try XCTUnwrap(document.streams.first)
        let chunks = document.chunks(forStream: stream.streamID)
        XCTAssertEqual(chunks.count, 3)

        let start = Date()
        let envelopes = XdfEnvelopeReader.readEnvelopes(url: url,
                                                          chunks: chunks,
                                                          channelCount: stream.channelCount,
                                                          channelFormat: stream.channelFormat,
                                                          // A wildly inflated declared total, far beyond what's
                                                          // actually on disk — exercises the same code path a
                                                          // corrupted or maliciously-crafted footer would.
                                                          totalSampleCount: 100_000_000,
                                                          columns: 2,
                                                          maxSamplesToScan: 5)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.0, "bounded decimation must resolve quickly regardless of declared size")
        let env = try XCTUnwrap(envelopes.first)
        // Only the first (stride-selected) chunk's values [1...4] should have
        // been decoded; if the guardrail failed open and scanned every
        // chunk, the max would be 203.
        XCTAssertLessThanOrEqual(env.maxs.max() ?? 0, 4)
    }

    func testBoundedChunkSelectionSpreadsAcrossWholeRecordingNotJustThePrefix() {
        let chunks = (0..<20).map { i in
            XdfChunkIndex(streamID: 1, fileOffset: i * 100, byteLength: 100, declaredSampleCount: 1000)
        }
        // 20 chunks * 1000 declared samples each = 20,000 total; cap at 4,000
        // should keep roughly a quarter of the chunks, not just the first four.
        let (selected, sampleCount) = XdfEnvelopeReader.boundedChunkSelection(chunks: chunks,
                                                                                totalSampleCount: 20_000,
                                                                                maxSamplesToScan: 4_000)
        XCTAssertLessThan(selected.count, chunks.count)
        XCTAssertLessThanOrEqual(sampleCount, 5_000) // some slack: last accepted chunk can push slightly over
        // Confirms the selection isn't simply `chunks.prefix(n)`: it should
        // reach into the back half of the original chunk list.
        let lastSelectedOffset = try? XCTUnwrap(selected.last?.fileOffset)
        XCTAssertGreaterThan(lastSelectedOffset ?? 0, chunks[3].fileOffset)
    }

    func testBoundedChunkSelectionLeavesSmallStreamsUntouched() {
        let chunks = (0..<3).map { i in
            XdfChunkIndex(streamID: 1, fileOffset: i * 100, byteLength: 100, declaredSampleCount: 4)
        }
        let (selected, sampleCount) = XdfEnvelopeReader.boundedChunkSelection(chunks: chunks,
                                                                                totalSampleCount: 12,
                                                                                maxSamplesToScan: XdfEnvelopeReader.defaultMaxSamplesToScan)
        XCTAssertEqual(selected.count, chunks.count)
        XCTAssertEqual(sampleCount, 12)
    }
}
