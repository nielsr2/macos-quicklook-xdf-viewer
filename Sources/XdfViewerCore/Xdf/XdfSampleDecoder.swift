import Foundation

/// Decodes raw `Samples` chunk payloads for one stream, given the byte-range
/// index recorded by `XdfReader.readStructure`. Values are handed to the
/// caller one sample at a time rather than collected into an array, so a
/// decimator can fold them directly into columns without ever materializing
/// the full per-channel sample series (see `XdfEnvelopeReader`).
enum XdfSampleDecoder {

    /// Per-sample format: `[timestampFlag: UInt8]` (0x08 = an explicit
    /// `Double` timestamp follows, anything else = none) + `channelCount`
    /// values in `channelFormat`. `chunks` must all belong to the same
    /// stream. String-format channels are unsupported and are skipped
    /// (no samples decoded, no error) since there is no meaningful numeric
    /// envelope for them.
    static func decodeSamples(url: URL,
                               chunks: [XdfChunkIndex],
                               channelCount: Int,
                               channelFormat: XdfSampleFormat,
                               onSample: (UnsafeBufferPointer<Double>) -> Void) throws {
        guard channelFormat != .string, channelCount > 0 else { return }

        var reader = try ByteReader(url: url)
        var scratch = [Double](repeating: 0, count: channelCount)

        for chunkEntry in chunks {
            try reader.seek(to: chunkEntry.fileOffset)
            let chunkEnd = chunkEntry.fileOffset + chunkEntry.byteLength
            guard chunkEnd <= reader.count else { throw XdfError.truncated }

            _ = try reader.readUInt32() // streamID — already known from the index.
            let numSamples = try reader.readVarLength()

            var decoded: UInt64 = 0
            while decoded < numSamples, reader.offset < chunkEnd {
                let flag = try reader.readUInt8()
                if flag == 0x08 {
                    _ = try reader.readDouble() // timestamp; unused for the envelope.
                }
                for c in 0..<channelCount {
                    scratch[c] = try readValue(&reader, format: channelFormat)
                }
                scratch.withUnsafeBufferPointer(onSample)
                decoded += 1
            }
        }
    }

    /// String-format variant of `decodeSamples`, for marker/event streams
    /// (XDF's convention: a single string channel, one value per event).
    /// Calls `onSample(timestamp, values)` once per sample — `timestamp` is
    /// the sample's own explicit timestamp if present, `nil` if this sample
    /// had none (irregular marker streams almost always carry an explicit
    /// timestamp per sample in practice, but the format allows omitting it).
    static func decodeStringSamples(url: URL,
                                     chunks: [XdfChunkIndex],
                                     channelCount: Int,
                                     onSample: (Double?, [String]) -> Void) throws {
        guard channelCount > 0 else { return }

        var reader = try ByteReader(url: url)
        var scratch = [String](repeating: "", count: channelCount)

        for chunkEntry in chunks {
            try reader.seek(to: chunkEntry.fileOffset)
            let chunkEnd = chunkEntry.fileOffset + chunkEntry.byteLength
            guard chunkEnd <= reader.count else { throw XdfError.truncated }

            _ = try reader.readUInt32() // streamID — already known from the index.
            let numSamples = try reader.readVarLength()

            var decoded: UInt64 = 0
            while decoded < numSamples, reader.offset < chunkEnd {
                let flag = try reader.readUInt8()
                var timestamp: Double?
                if flag == 0x08 {
                    timestamp = try reader.readDouble()
                }
                for c in 0..<channelCount {
                    // Strings are var-length-prefixed using the same 1/4/8-byte
                    // width scheme as chunk lengths and sample counts.
                    let length = try reader.readVarLength()
                    scratch[c] = try reader.readUTF8(count: Int(length))
                }
                onSample(timestamp, scratch)
                decoded += 1
            }
        }
    }

    private static func readValue(_ reader: inout ByteReader, format: XdfSampleFormat) throws -> Double {
        switch format {
        case .int8: return Double(Int8(bitPattern: try reader.readUInt8()))
        case .int16: return Double(Int16(bitPattern: try reader.readUInt16()))
        case .int32: return Double(Int32(bitPattern: try reader.readUInt32()))
        case .int64: return Double(Int64(bitPattern: try reader.readUInt64()))
        case .float32: return Double(Float(bitPattern: try reader.readUInt32()))
        case .double64: return try reader.readDouble()
        case .string: return 0 // Unreachable — guarded by the caller.
        }
    }
}
