import Foundation

/// Caches decoded per-channel envelopes keyed by `(streamID, columns)` so
/// navigating between the stacked full-waveform view and the single-channel
/// solo view — or switching *which* channel is soloed — doesn't re-decode the
/// same stream from disk every time.
///
/// A single decode pass necessarily produces every channel's envelope
/// (`XdfSampleDecoder` must parse all channels per sample just to advance the
/// byte cursor), so keying on `(streamID, columns)` rather than on an
/// individual channel lets the solo view reuse one stream-wide pass across all
/// of that stream's channels. This directly removes the "soloing a different
/// channel re-runs the full decode" cost the performance audit flagged.
///
/// An `actor`: the store is accessed serially, and an in-flight decode is
/// shared so two near-simultaneous requests for the same key decode only once.
/// Instances are scoped to one previewed file (held by `XdfPreviewView`), so
/// the cache is discarded with the preview — envelopes are small (a 30k-column
/// solo pass is ~240 KB; a 37×8k full pass ~2.4 MB) and only a handful of keys
/// are ever live, so no eviction policy is needed for a preview's lifetime.
public actor XdfEnvelopeCache {
    private struct Key: Hashable {
        let streamID: UInt32
        let columns: Int
    }

    private var ready: [Key: [XdfChannelEnvelope]] = [:]
    private var inFlight: [Key: Task<[XdfChannelEnvelope], Never>] = [:]

    public init() {}

    /// Returns the cached envelopes for `(streamID, columns)`, computing them
    /// via `compute` (on a detached task, off the calling actor) on first
    /// request and coalescing concurrent requests for the same key.
    public func envelopes(streamID: UInt32,
                          columns: Int,
                          compute: @escaping @Sendable () -> [XdfChannelEnvelope]) async -> [XdfChannelEnvelope] {
        let key = Key(streamID: streamID, columns: columns)
        if let hit = ready[key] { return hit }
        if let running = inFlight[key] { return await running.value }

        let task = Task.detached(priority: .userInitiated) { compute() }
        inFlight[key] = task
        let result = await task.value
        ready[key] = result
        inFlight[key] = nil
        return result
    }
}
