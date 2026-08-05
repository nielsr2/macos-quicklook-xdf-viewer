import Foundation

/// Byte-range index of one `Samples` chunk, recorded during the fast structural
/// pass so the slow decimation pass can seek straight to sample payloads
/// without re-walking the whole file.
public struct XdfChunkIndex: Sendable, Equatable {
    public var streamID: UInt32
    public var fileOffset: Int
    public var byteLength: Int
    public var declaredSampleCount: Int

    public init(streamID: UInt32, fileOffset: Int, byteLength: Int, declaredSampleCount: Int) {
        self.streamID = streamID
        self.fileOffset = fileOffset
        self.byteLength = byteLength
        self.declaredSampleCount = declaredSampleCount
    }
}
