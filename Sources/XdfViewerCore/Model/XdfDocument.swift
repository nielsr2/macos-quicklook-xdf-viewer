import Foundation

/// Result of the fast structural pass over an `.xdf` file: file-level metadata,
/// per-stream header/footer info, and a byte-range index into the `Samples`
/// chunks for each stream (used by the slow decimation pass, Stage 3).
public struct XdfDocument: Sendable {
    public var version: String?
    public var streams: [XdfStreamInfo]
    public var chunkIndex: [XdfChunkIndex]

    public init(version: String? = nil, streams: [XdfStreamInfo] = [], chunkIndex: [XdfChunkIndex] = []) {
        self.version = version
        self.streams = streams
        self.chunkIndex = chunkIndex
    }

    /// Chunk index entries for a given stream, in file order.
    public func chunks(forStream streamID: UInt32) -> [XdfChunkIndex] {
        chunkIndex.filter { $0.streamID == streamID }
    }
}
