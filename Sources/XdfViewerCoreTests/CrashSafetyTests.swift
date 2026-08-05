import XCTest
@testable import XdfViewerCore

/// Regression tests for crashes found auditing the full-waveform view: unvalidated
/// values straight from an `.xdf` file (non-finite samples, absurd durations /
/// timestamps / channel counts, oversized var-lengths) must degrade gracefully
/// instead of trapping `Int(_:)` / `Range` / CoreGraphics.
final class CrashSafetyTests: XCTestCase {

    // MARK: - Byte-building helpers (mirror XdfReaderTests' framing)

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
        let bits = value.bitPattern
        var data = Data()
        for i in 0..<4 { data.append(UInt8((bits >> (8 * i)) & 0xFF)) }
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

    private func fileHeaderChunk() -> Data {
        chunk(tag: 1, content: Data("<info><version>1.0</version></info>".utf8))
    }

    private func streamHeaderChunk(streamID: UInt32, xml: String) -> Data {
        var content = uint32LE(streamID)
        content.append(Data(xml.utf8))
        return chunk(tag: 2, content: content)
    }

    /// A `Samples` chunk whose payload is `values.count` single-channel float32
    /// samples, each with a "no timestamp" flag byte.
    private func float32SamplesChunk(streamID: UInt32, values: [Float]) -> Data {
        var payload = Data()
        for v in values {
            payload.append(0x00)            // timestamp flag: none
            payload.append(float32LE(v))    // one channel
        }
        var content = uint32LE(streamID)
        content.append(varLength(UInt64(values.count), width: 4))
        content.append(payload)
        return chunk(tag: 3, content: content)
    }

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdf-crash-test-\(UUID().uuidString).xdf")
        try data.write(to: url)
        return url
    }

    // MARK: - #3 Non-finite samples must not poison the envelope

    func testNonFiniteSamplesProduceFiniteEnvelope() throws {
        let xml = """
        <info><name>S</name><type>EMG</type><channel_count>1</channel_count>\
        <nominal_srate>100</nominal_srate><channel_format>float32</channel_format></info>
        """
        var data = fileMagic
        data.append(fileHeaderChunk())
        data.append(streamHeaderChunk(streamID: 1, xml: xml))
        // A finite baseline plus +inf, -inf, and NaN — as seen in real EEG/EMG
        // dropouts. None of these may leak into the drawn envelope.
        data.append(float32SamplesChunk(streamID: 1,
                                        values: [1.0, .infinity, -.infinity, .nan, 2.0]))
        let url = try writeTempFile(data)

        let document = try XdfReader.readStructure(url: url)
        let chunks = document.chunks(forStream: 1)
        let envelopes = XdfEnvelopeReader.readEnvelopes(url: url,
                                                        chunks: chunks,
                                                        channelCount: 1,
                                                        channelFormat: .float32,
                                                        totalSampleCount: 5,
                                                        columns: 4)

        let env = try XCTUnwrap(envelopes.first)
        for v in env.mins { XCTAssertTrue(v.isFinite, "min \(v) is not finite") }
        for v in env.maxs { XCTAssertTrue(v.isFinite, "max \(v) is not finite") }
        XCTAssertTrue(env.dataMin.isFinite)
        XCTAssertTrue(env.dataMax.isFinite)
        // The finite samples (1.0, 2.0) must still register; the non-finite ones
        // are dropped, and their columns fall back to the flat-zero placeholder.
        XCTAssertEqual(env.dataMax, 2.0, accuracy: 0.0001)
        XCTAssertTrue(env.mins.contains { abs($0 - 1.0) < 0.0001 },
                      "finite sample 1.0 should register in some column")
    }

    // MARK: - #1 Column-count computation must not trap on absurd durations

    func testEnvelopeColumnsClampsAbsurdDuration() {
        // A footer declaring last_timestamp = 1e17 previously made
        // `Int(d * 120)` trap when opening the full waveform view.
        let cols = XdfEnvelopeReader.envelopeColumns(duration: 1e17, perSecond: 120,
                                                     min: 600, max: 8000)
        XCTAssertEqual(cols, 8000)
    }

    func testEnvelopeColumnsNormalAndDegenerateCases() {
        XCTAssertEqual(XdfEnvelopeReader.envelopeColumns(duration: 20, perSecond: 120,
                                                         min: 600, max: 8000), 2400)
        XCTAssertEqual(XdfEnvelopeReader.envelopeColumns(duration: 1, perSecond: 120,
                                                         min: 600, max: 8000), 600)
        // Non-finite / non-positive durations fall back to the minimum.
        XCTAssertEqual(XdfEnvelopeReader.envelopeColumns(duration: .nan, perSecond: 120,
                                                         min: 600, max: 8000), 600)
        XCTAssertEqual(XdfEnvelopeReader.envelopeColumns(duration: -5, perSecond: 120,
                                                         min: 600, max: 8000), 600)
        // Non-finite duration is garbage, not a genuinely long recording — it
        // takes the conservative `min` fallback (unlike a finite-huge duration,
        // which maxes out columns).
        XCTAssertEqual(XdfEnvelopeReader.envelopeColumns(duration: .infinity, perSecond: 400,
                                                         min: 2000, max: 30000), 2000)
    }

    // MARK: - #6 Summing declared sample counts must saturate, not overflow-trap

    func testTotalDeclaredSampleCountSaturatesOnOverflow() {
        let chunks = [
            XdfChunkIndex(streamID: 1, fileOffset: 0, byteLength: 8, declaredSampleCount: Int.max),
            XdfChunkIndex(streamID: 1, fileOffset: 8, byteLength: 8, declaredSampleCount: Int.max),
        ]
        XCTAssertEqual(chunks.totalDeclaredSampleCount, Int.max)
    }

    func testTotalDeclaredSampleCountSumsNormalCounts() {
        let chunks = [
            XdfChunkIndex(streamID: 1, fileOffset: 0, byteLength: 8, declaredSampleCount: 10),
            XdfChunkIndex(streamID: 1, fileOffset: 8, byteLength: 8, declaredSampleCount: 32),
        ]
        XCTAssertEqual(chunks.totalDeclaredSampleCount, 42)
        XCTAssertEqual([XdfChunkIndex]().totalDeclaredSampleCount, 0)
    }

    // MARK: - #7 Negative channel_count must not trap Range construction

    func testNegativeChannelCountClampsToZero() throws {
        let xml = """
        <info><name>S</name><type>EEG</type><channel_count>-3</channel_count>\
        <nominal_srate>100</nominal_srate><channel_format>float32</channel_format></info>
        """
        var data = fileMagic
        data.append(fileHeaderChunk())
        data.append(streamHeaderChunk(streamID: 7, xml: xml))
        let url = try writeTempFile(data)

        let document = try XdfReader.readStructure(url: url)
        let stream = try XCTUnwrap(document.streams.first)
        XCTAssertEqual(stream.channelCount, 0)

        // Building the card previously trapped on `0..<(-3)`.
        let card = StreamCardViewModel(stream: stream)
        XCTAssertTrue(card.channels.isEmpty)
    }

    // MARK: - #8 Oversized chunk length must throw, not trap Int(length)

    func testOversizedChunkLengthThrows() throws {
        var data = fileMagic
        // A chunk whose declared length exceeds Int.max: an 8-byte var-length
        // of UInt64.max, then two bytes so `readUInt16` (the tag) succeeds and
        // execution reaches the `Int(length) - 2` conversion.
        data.append(varLength(UInt64.max, width: 8))
        data.append(Data([0x01, 0x00])) // tag bytes
        let url = try writeTempFile(data)

        XCTAssertThrowsError(try XdfReader.readStructure(url: url)) { error in
            XCTAssertEqual(error as? XdfError, .truncated)
        }
    }

    // MARK: - #5 Oversized marker string length must degrade to empty, not trap

    func testOversizedMarkerStringLengthDegradesToEmpty() throws {
        let xml = """
        <info><name>M</name><type>Markers</type><channel_count>1</channel_count>\
        <nominal_srate>0</nominal_srate><channel_format>string</channel_format></info>
        """
        var data = fileMagic
        data.append(fileHeaderChunk())
        data.append(streamHeaderChunk(streamID: 3, xml: xml))
        // One marker sample: explicit timestamp, then a string whose declared
        // length is UInt64.max (8-byte var-length) — `Int(length)` would trap.
        var content = uint32LE(3)
        content.append(varLength(1, width: 4))              // numSamples
        content.append(0x08)                                 // timestamp flag
        content.append(Data(repeating: 0, count: 8))         // timestamp 0.0
        content.append(varLength(UInt64.max, width: 8))      // absurd string length
        data.append(chunk(tag: 3, content: content))
        let url = try writeTempFile(data)

        let document = try XdfReader.readStructure(url: url)
        let stream = try XCTUnwrap(document.streams.first)
        let chunks = document.chunks(forStream: stream.streamID)

        // XdfMarkerReader's contract: never traps, degrades to empty on any
        // malformed chunk.
        let decoded = XdfMarkerReader.readMarkers(url: url, chunks: chunks,
                                                  channelCount: stream.channelCount,
                                                  channelFormat: stream.channelFormat)
        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - #2 / #9 Time/rate/duration formatting must not trap Int(Double)

    func testTimeFormattingDoesNotTrapOnHugeValues() {
        // Each of these previously trapped `Int(Double)` for a large *finite*
        // value coming from an absurd footer timestamp / duration / srate.
        XCTAssertFalse(TimeAxis.formatTime(1e19).isEmpty)
        XCTAssertFalse(TimeAxis.formatTime(1e19, step: 0.5).isEmpty)
        XCTAssertFalse(StreamCardViewModel.formatDuration(1e19).isEmpty)
        XCTAssertFalse(StreamCardViewModel.formatEventTime(1e19).isEmpty)
        XCTAssertTrue(StreamCardViewModel.formatSampleRate(1e300).contains("Hz"))
        // No negative times from 32-bit `%d` truncation of a large hours value.
        XCTAssertFalse(StreamCardViewModel.formatDuration(1e19).contains("-"))
    }

    func testTimeFormattingUnchangedForNormalValues() {
        XCTAssertEqual(TimeAxis.formatTime(200), "3:20")
        XCTAssertEqual(StreamCardViewModel.formatDuration(9.0), "0:09")
        XCTAssertEqual(StreamCardViewModel.formatSampleRate(100), "100 Hz")
        XCTAssertEqual(StreamCardViewModel.formatSampleRate(500), "500 Hz")
        XCTAssertEqual(StreamCardViewModel.formatEventTime(75), "1:15")
    }

    // MARK: - #4 Axis tick generation must terminate and stay bounded

    func testTickValuesTerminatesAndIsBoundedAtLargeOffset() {
        // Zoomed in far from t=0: `step` is tiny relative to `visibleStart`, so a
        // `t += step` accumulator loop never advances (t + step == t) and spins
        // forever on the main thread. Index-based generation must stay bounded.
        let ticks = TimeAxis.tickValues(visibleStart: 1e15, visibleEnd: 1e15 + 0.001,
                                        step: 1e-9, maxTicks: 512)
        XCTAssertLessThanOrEqual(ticks.count, 513)
    }

    func testTickValuesNormalSpan() {
        let ticks = TimeAxis.tickValues(visibleStart: 0, visibleEnd: 10, step: 2)
        XCTAssertTrue(ticks.contains(0))
        XCTAssertTrue(ticks.contains(10))
        XCTAssertTrue(ticks.allSatisfy { $0.isFinite })
    }
}
