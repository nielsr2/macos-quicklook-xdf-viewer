import Foundation

/// Entry point for reading `.xdf` files. `readStructure` is the fast pass used
/// by Stage 0/2 to build the overview; it must not decode sample payloads.
/// Implemented in Stage 1.
public enum XdfReader {
    /// ASCII `"XDF:"` file magic expected at the very start of the file.
    private static let magic = "XDF:"

    /// Fast structural pass: validates the file magic, walks every chunk in
    /// the file, parses `FileHeader`/`StreamHeader`/`StreamFooter` XML into
    /// an `XdfDocument`, and records a byte-range `XdfChunkIndex` entry for
    /// every `Samples` chunk without decoding its sample payload.
    ///
    /// Only two failure modes abort the whole read: a bad file magic
    /// (`XdfError.badMagic`) and running out of bytes mid-structure
    /// (`XdfError.truncated`). A malformed or unknown chunk tag, or garbled
    /// XML in one stream's header/footer, is skipped/defaulted so the rest
    /// of the file still parses.
    public static func readStructure(url: URL) throws -> XdfDocument {
        var reader = try ByteReader(url: url)

        let header = try reader.readUTF8(count: magic.utf8.count)
        guard header == magic else { throw XdfError.badMagic }

        var document = XdfDocument()
        var streamOrder: [UInt32] = []
        var streamsByID: [UInt32: XdfStreamInfo] = [:]
        var chunkIndex: [XdfChunkIndex] = []

        func stream(for streamID: UInt32) -> XdfStreamInfo {
            if let existing = streamsByID[streamID] { return existing }
            let placeholder = XdfStreamInfo(streamID: streamID,
                                             name: "",
                                             type: "",
                                             channelCount: 0,
                                             nominalSampleRate: 0,
                                             channelFormat: .float32)
            streamOrder.append(streamID)
            streamsByID[streamID] = placeholder
            return placeholder
        }

        while !reader.isAtEnd {
            let length = try reader.readVarLength()
            guard length >= 2 else { throw XdfError.truncated }
            let tagRaw = try reader.readUInt16()
            // A declared length > Int.max would trap `Int(length)`; a corrupt
            // file must throw, not crash the preview/thumbnail extension.
            guard let lengthInt = Int(exactly: length) else { throw XdfError.truncated }
            let contentLength = lengthInt - 2
            guard contentLength >= 0, reader.remaining >= contentLength else { throw XdfError.truncated }
            let contentStart = reader.offset
            let contentEnd = contentStart + contentLength

            if let tag = XdfChunkTag(rawValue: tagRaw) {
                switch tag {
                case .fileHeader:
                    let xml = try reader.readUTF8(count: contentLength)
                    document.version = XdfHeaderXMLParser.parse(xml: xml).version

                case .streamHeader:
                    if contentLength >= 4 {
                        let streamID = try reader.readUInt32()
                        let xmlLength = contentEnd - reader.offset
                        let xml = try reader.readUTF8(count: xmlLength)
                        let fields = XdfHeaderXMLParser.parse(xml: xml)
                        var info = stream(for: streamID)
                        info.name = fields.name
                        info.type = fields.type
                        info.channelCount = fields.channelCount
                        info.nominalSampleRate = fields.nominalSampleRate
                        info.channelFormat = fields.channelFormat
                        info.channels = fields.channels
                        streamsByID[streamID] = info
                    }

                case .samples:
                    if contentLength >= 4 {
                        let streamID = try reader.readUInt32()
                        var declaredCount = 0
                        if reader.offset < contentEnd {
                            // Best-effort: the sample count is cheap to read (it's
                            // right after streamID), but never let a hiccup here
                            // abort the whole structural pass — we resync to
                            // `contentEnd` unconditionally below regardless.
                            if let n = try? reader.readVarLength() {
                                declaredCount = Int(min(n, UInt64(Int.max)))
                            }
                        }
                        chunkIndex.append(XdfChunkIndex(streamID: streamID,
                                                         fileOffset: contentStart,
                                                         byteLength: contentLength,
                                                         declaredSampleCount: declaredCount))
                    }

                case .clockOffset, .boundary:
                    break // Not needed for Stage 1; skipped via the resync below.

                case .streamFooter:
                    if contentLength >= 4 {
                        let streamID = try reader.readUInt32()
                        let xmlLength = contentEnd - reader.offset
                        let xml = try reader.readUTF8(count: xmlLength)
                        let fields = XdfHeaderXMLParser.parse(xml: xml)
                        var info = stream(for: streamID)
                        info.firstTimestamp = fields.firstTimestamp
                        info.lastTimestamp = fields.lastTimestamp
                        info.sampleCount = fields.sampleCount
                        info.effectiveSampleRate = fields.effectiveSampleRate
                        streamsByID[streamID] = info
                    }
                }
            }
            // Unknown tags and any partially-consumed known chunk both resync
            // to the chunk's declared end, so a single bad chunk can never
            // desynchronize the rest of the walk.
            try reader.seek(to: contentEnd)
        }

        document.streams = streamOrder.compactMap { streamsByID[$0] }
        document.chunkIndex = chunkIndex
        return document
    }
}
