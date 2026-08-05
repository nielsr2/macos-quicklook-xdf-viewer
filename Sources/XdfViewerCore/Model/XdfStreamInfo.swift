import Foundation

/// Decoded `StreamHeader`/`StreamFooter` metadata for one stream in an XDF file.
/// Produced by the fast structural pass (`XdfReader.readStructure`); sample
/// payloads are not decoded here — see `XdfChunkIndex` for that.
public struct XdfStreamInfo: Sendable, Equatable, Identifiable {
    public var id: UInt32 { streamID }

    public var streamID: UInt32
    public var name: String
    public var type: String
    public var channelCount: Int
    public var nominalSampleRate: Double
    public var channelFormat: XdfSampleFormat
    public var channels: [XdfChannelInfo]

    // From StreamFooter, if present.
    public var firstTimestamp: Double?
    public var lastTimestamp: Double?
    public var sampleCount: Int?
    public var effectiveSampleRate: Double?

    public init(streamID: UInt32,
                name: String,
                type: String,
                channelCount: Int,
                nominalSampleRate: Double,
                channelFormat: XdfSampleFormat,
                channels: [XdfChannelInfo] = [],
                firstTimestamp: Double? = nil,
                lastTimestamp: Double? = nil,
                sampleCount: Int? = nil,
                effectiveSampleRate: Double? = nil) {
        self.streamID = streamID
        self.name = name
        self.type = type
        self.channelCount = channelCount
        self.nominalSampleRate = nominalSampleRate
        self.channelFormat = channelFormat
        self.channels = channels
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.sampleCount = sampleCount
        self.effectiveSampleRate = effectiveSampleRate
    }

    /// Duration derived from footer timestamps, or `nil` if the footer is missing/malformed.
    public var duration: Double? {
        guard let first = firstTimestamp, let last = lastTimestamp, last >= first else { return nil }
        return last - first
    }
}
