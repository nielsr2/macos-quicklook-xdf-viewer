import Foundation

/// Cursor-based, bounds-checked binary reader over a (typically memory-mapped)
/// `Data` buffer. All multi-byte integer reads are little-endian, matching the
/// on-disk XDF format. Every read that would run past the end of the buffer
/// throws `XdfError.truncated` rather than trapping.
struct ByteReader {
    private let data: Data
    private(set) var offset: Int

    init(data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    /// Loads `url` via memory mapping so large recordings don't need to be
    /// fully resident in memory just to read structural metadata.
    init(url: URL) throws {
        self.data = try Data(contentsOf: url, options: [.mappedIfSafe])
        self.offset = 0
    }

    /// Total number of bytes in the underlying buffer.
    var count: Int { data.count }

    /// Number of bytes left to read from the current cursor position.
    var remaining: Int { data.count - offset }

    /// Whether the cursor has reached (or passed) the end of the buffer.
    var isAtEnd: Bool { offset >= data.count }

    /// Repositions the cursor to an absolute byte offset. The offset must lie
    /// within `0...count`; anything else is treated as a truncation error
    /// since it implies the caller computed a chunk boundary past EOF.
    mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= data.count else { throw XdfError.truncated }
        offset = newOffset
    }

    /// Advances the cursor by `byteCount` bytes without reading them.
    mutating func skip(_ byteCount: Int) throws {
        guard byteCount >= 0 else { throw XdfError.truncated }
        try seek(to: offset + byteCount)
    }

    mutating func readUInt8() throws -> UInt8 {
        UInt8(truncatingIfNeeded: try readLittleEndianUInt(width: 1))
    }

    mutating func readUInt16() throws -> UInt16 {
        UInt16(truncatingIfNeeded: try readLittleEndianUInt(width: 2))
    }

    mutating func readUInt32() throws -> UInt32 {
        UInt32(truncatingIfNeeded: try readLittleEndianUInt(width: 4))
    }

    mutating func readUInt64() throws -> UInt64 {
        try readLittleEndianUInt(width: 8)
    }

    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readLittleEndianUInt(width: 8))
    }

    /// Reads the XDF variable-length-count encoding used both for the
    /// container `[NumLengthBytes][Length]` chunk header and for the
    /// per-`Samples`-chunk sample count: a 1-byte width selector (1, 4, or 8)
    /// followed by that many little-endian bytes holding the value.
    mutating func readVarLength() throws -> UInt64 {
        let width = try readUInt8()
        guard width == 1 || width == 4 || width == 8 else { throw XdfError.truncated }
        return try readLittleEndianUInt(width: Int(width))
    }

    /// Reads `byteCount` bytes and decodes them as UTF-8. Never throws for
    /// invalid encoding (uses the Unicode replacement character instead) —
    /// only insufficient remaining bytes is an error.
    mutating func readUTF8(count byteCount: Int) throws -> String {
        try requireBytes(byteCount)
        let start = data.startIndex + offset
        let bytes = data.subdata(in: start..<(start + byteCount))
        offset += byteCount
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads `width` (1, 2, 4, or 8) little-endian bytes and returns them as a
    /// `UInt64`.
    ///
    /// This is the innermost hot path of sample decoding — called several times
    /// per decoded value, tens of millions of times per envelope pass. The old
    /// implementation looped `width` times over `data[base + i]`, and `Data`'s
    /// subscript re-validates its index on every access, which dominated decode
    /// latency (the "Decoding…" spinner). This loads the whole word in one
    /// unaligned read from a single `withUnsafeBytes` region instead. `offset`
    /// is 0-based from the buffer's first byte (matching the old
    /// `data.startIndex + offset` indexing), so it maps directly onto the
    /// unsafe buffer; `requireBytes(width)` guarantees the read stays in bounds.
    private mutating func readLittleEndianUInt(width: Int) throws -> UInt64 {
        try requireBytes(width)
        let start = offset
        let value: UInt64 = data.withUnsafeBytes { raw in
            switch width {
            case 1: return UInt64(raw.loadUnaligned(fromByteOffset: start, as: UInt8.self))
            case 2: return UInt64(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: start, as: UInt16.self)))
            case 4: return UInt64(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: start, as: UInt32.self)))
            case 8: return UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: start, as: UInt64.self))
            default:
                // Widths are validated to 1/4/8 by every caller (readVarLength)
                // and are otherwise fixed; this byte-wise fallback only guards a
                // future caller passing an odd width.
                var result: UInt64 = 0
                for i in 0..<width { result |= UInt64(raw[start + i]) << (8 * i) }
                return result
            }
        }
        offset += width
        return value
    }

    private func requireBytes(_ n: Int) throws {
        guard n >= 0, remaining >= n else { throw XdfError.truncated }
    }
}
