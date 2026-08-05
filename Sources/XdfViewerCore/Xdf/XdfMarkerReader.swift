import Foundation

/// One decoded marker/event: a label at a point in time. Timestamps are in
/// the same clock as `XdfStreamInfo.firstTimestamp`/`lastTimestamp`.
public struct XdfMarkerEvent: Sendable, Equatable {
    public var timestamp: Double
    public var label: String

    public init(timestamp: Double, label: String) {
        self.timestamp = timestamp
        self.label = label
    }
}

/// Decodes string-format `Samples` chunks (the XDF convention for
/// marker/event streams) into timestamped labels. Complements
/// `XdfEnvelopeReader`, which explicitly skips string-format channels since
/// they have no meaningful numeric envelope.
public enum XdfMarkerReader {

    /// Only single-channel string-format streams are treated as marker
    /// streams — there's no established XDF convention for what a "label"
    /// would mean across multiple string channels, so anything else (wrong
    /// format, zero or multiple channels) returns an empty array rather than
    /// guessing. A sample with no explicit timestamp is dropped (a marker
    /// with no time to place it on the axis isn't useful) rather than
    /// interpolated. Never throws — a decode failure degrades to an empty
    /// array, matching `XdfEnvelopeReader`'s "one bad stream can't break the
    /// rest of the preview" contract.
    public static func readMarkers(url: URL,
                                    chunks: [XdfChunkIndex],
                                    channelCount: Int,
                                    channelFormat: XdfSampleFormat) -> [XdfMarkerEvent] {
        guard channelFormat == .string, channelCount == 1, !chunks.isEmpty else { return [] }

        var events: [XdfMarkerEvent] = []
        do {
            try XdfSampleDecoder.decodeStringSamples(url: url, chunks: chunks, channelCount: channelCount) { timestamp, values in
                guard let timestamp, timestamp.isFinite, let label = values.first else { return }
                events.append(XdfMarkerEvent(timestamp: timestamp, label: label))
            }
        } catch {
            return []
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }
}
