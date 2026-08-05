import Foundation

/// A min/max amplitude envelope for one channel, one column per horizontal
/// pixel bucket — the XDF analog of `AudioViewerCore.WaveformEnvelope`.
public struct XdfChannelEnvelope: Sendable, Equatable {
    public let mins: [Float]
    public let maxs: [Float]
    public var columnCount: Int { mins.count }

    /// Data range (min of `mins`, max of `maxs`), computed once here at
    /// construction. The per-frame drawing code (`ChannelLaneView`,
    /// `MinimapView`, `WaveformSparkline`) and `mostInformative()` used to
    /// call `mins.min()` / `maxs.max()` on every single redraw — an O(columns)
    /// scan (up to ~30k columns) repeated per lane per pan/zoom/hover tick.
    /// Caching it at init makes those redraws O(1) in the range lookup.
    public let dataMin: Float
    public let dataMax: Float

    /// Peak-to-peak amplitude — a cheap "has real signal" proxy used to pick a
    /// representative channel for sparklines/minimaps.
    public var peakToPeak: Float { dataMax - dataMin }

    public init(mins: [Float], maxs: [Float]) {
        self.mins = mins
        self.maxs = maxs
        self.dataMin = mins.min() ?? 0
        self.dataMax = maxs.max() ?? 0
    }

    /// A flat, all-zero envelope — used as a placeholder and as the safe
    /// fallback when a stream's samples can't be decoded (unsupported
    /// format, decode failure, or no samples at all).
    public static func flat(columns: Int) -> XdfChannelEnvelope {
        let columns = max(1, columns)
        return XdfChannelEnvelope(mins: [Float](repeating: 0, count: columns),
                                   maxs: [Float](repeating: 0, count: columns))
    }
}

/// Streams a stream's decoded samples straight into per-channel min/max
/// envelopes without ever materializing the full sample series — the
/// decimation half of the two-phase load. Used by both the full waveform
/// view (Stage 3, fine columns) and the thumbnail provider (Stage 4, coarse
/// columns).
public enum XdfEnvelopeReader {

    /// Default ceiling on how many samples a single `readEnvelopes` call will
    /// actually walk, regardless of how large the stream claims to be.
    ///
    /// Decimation exists to give a Quick Look preview a fast "shape of the
    /// data" glance — it must never become O(unbounded) in wall-clock time
    /// just because a file *declares* (or genuinely has) tens or hundreds of
    /// millions of samples in a stream. 5,000,000 is generous headroom over
    /// what a 48-column sparkline or an ~8000-column full-view envelope
    /// actually needs (both are column counts several orders of magnitude
    /// smaller than this), while still comfortably covering every real LSL
    /// recording we've tested against (the reference file had ~13k/1.8k
    /// samples per stream). At typical decode throughput this keeps a single
    /// stream's decimation pass in the sub-second range even in the worst
    /// case, which is the actual budget that matters for a preview extension.
    public static let defaultMaxSamplesToScan = 5_000_000

    /// Column budget for a decimation pass: `perSecond` columns per second of
    /// `duration`, clamped to `lo...hi`. The clamp happens in floating point
    /// *before* the `Int` conversion, so an absurd or non-finite `duration`
    /// from a malformed footer (e.g. `last_timestamp = 1e17`) can't trap
    /// `Int(_:)` — which aborts for NaN/±Inf or any value ≥ 2^63. A non-finite
    /// or non-positive duration falls back to `lo`.
    public static func envelopeColumns(duration: Double, perSecond: Double,
                                        min lo: Int, max hi: Int) -> Int {
        let lo = Swift.max(1, lo)
        let hi = Swift.max(lo, hi)
        guard duration.isFinite, perSecond.isFinite, duration > 0, perSecond > 0 else { return lo }
        let raw = (duration * perSecond).rounded()
        if raw <= Double(lo) { return lo }
        if raw >= Double(hi) { return hi }   // hi is a sane Int, so this Int() is safe
        return Int(raw)
    }

    /// - Parameters:
    ///   - chunks: this stream's `Samples` chunk index entries, from
    ///     `XdfDocument.chunks(forStream:)`.
    ///   - totalSampleCount: best-effort total, e.g. `stream.sampleCount` or
    ///     the sum of `declaredSampleCount` across `chunks`. Used only to size
    ///     the column mapping; an inaccurate count just skews column widths,
    ///     it can't corrupt the result.
    ///   - columns: number of output buckets per channel.
    ///   - maxSamplesToScan: hard ceiling on samples actually decoded (see
    ///     `defaultMaxSamplesToScan`). When `totalSampleCount` exceeds this,
    ///     `readEnvelopes` decodes a uniformly-strided subset of `chunks`
    ///     (spread across the whole recording rather than just its start) so
    ///     the total decoded sample count stays under the ceiling. The
    ///     resulting envelope is coarser than it would otherwise be — a
    ///     transient that falls entirely inside a skipped chunk is invisible
    ///     — but the cost of producing it stays bounded. One residual edge
    ///     case this can't fully close: a single pathological chunk whose own
    ///     `declaredSampleCount` alone exceeds the ceiling is still decoded
    ///     in full (the shared, frozen `XdfSampleDecoder.decodeSamples` has
    ///     no mid-chunk early-exit), so its cost is bounded by that one
    ///     chunk's size rather than the whole file's — real LSL recordings
    ///     don't produce single chunks anywhere near this size in practice.
    /// - Returns: one envelope per channel, in channel order. Never throws —
    ///   an unsupported format or a decode failure degrades to flat
    ///   placeholder envelopes so one bad stream can't break the rest of the
    ///   preview.
    public static func readEnvelopes(url: URL,
                                      chunks: [XdfChunkIndex],
                                      channelCount: Int,
                                      channelFormat: XdfSampleFormat,
                                      totalSampleCount: Int,
                                      columns: Int,
                                      maxSamplesToScan: Int = defaultMaxSamplesToScan) -> [XdfChannelEnvelope] {
        let columns = max(1, columns)
        let channelCount = max(0, channelCount)
        guard channelCount > 0, channelFormat != .string, totalSampleCount > 0, !chunks.isEmpty else {
            return (0..<max(channelCount, 1)).map { _ in .flat(columns: columns) }
        }

        let (scanChunks, scanSampleCount) = boundedChunkSelection(chunks: chunks,
                                                                    totalSampleCount: totalSampleCount,
                                                                    maxSamplesToScan: maxSamplesToScan)

        var mins = [[Float]](repeating: [Float](repeating: .greatestFiniteMagnitude, count: columns), count: channelCount)
        var maxs = [[Float]](repeating: [Float](repeating: -.greatestFiniteMagnitude, count: columns), count: channelCount)
        var touched = [[Bool]](repeating: [Bool](repeating: false, count: columns), count: channelCount)

        var sampleIndex = 0
        let perColumn = Double(scanSampleCount) / Double(columns)

        do {
            try XdfSampleDecoder.decodeSamples(url: url, chunks: scanChunks, channelCount: channelCount, channelFormat: channelFormat) { values in
                let col = min(columns - 1, Int(Double(sampleIndex) / perColumn))
                for c in 0..<channelCount {
                    let v = Float(values[c])
                    // Skip non-finite samples (NaN/±Inf — common in real EEG/EMG
                    // recordings on electrode dropout / LSL gaps). Letting one
                    // leak in makes dataMax/dataMin non-finite, which turns every
                    // drawn coordinate for the lane into NaN. Not marking the
                    // column `touched` lets the untouched→0 reset below clear a
                    // column that had only non-finite samples, instead of leaving
                    // its ±greatestFiniteMagnitude sentinels.
                    guard v.isFinite else { continue }
                    if v < mins[c][col] { mins[c][col] = v }
                    if v > maxs[c][col] { maxs[c][col] = v }
                    touched[c][col] = true
                }
                sampleIndex += 1
            }
        } catch {
            return (0..<channelCount).map { _ in .flat(columns: columns) }
        }

        return (0..<channelCount).map { c in
            var chMins = mins[c]
            var chMaxs = maxs[c]
            for col in 0..<columns where !touched[c][col] {
                chMins[col] = 0
                chMaxs[col] = 0
            }
            return XdfChannelEnvelope(mins: chMins, maxs: chMaxs)
        }
    }

    /// Picks a subset of `chunks` whose declared sample counts sum to no
    /// more than `maxSamplesToScan`, choosing a uniform stride through the
    /// chunk list (rather than taking a prefix) so the scanned chunks are
    /// spread across the whole recording instead of clustering at the start.
    /// Returns the selected chunks along with the sum of their declared
    /// sample counts — used to size the column mapping for the *scanned*
    /// subset, not the original full-stream total, so columns still span the
    /// full width of the envelope instead of leaving the tail flat.
    static func boundedChunkSelection(chunks: [XdfChunkIndex],
                                       totalSampleCount: Int,
                                       maxSamplesToScan: Int) -> (chunks: [XdfChunkIndex], sampleCount: Int) {
        guard maxSamplesToScan > 0, totalSampleCount > maxSamplesToScan, chunks.count > 1 else {
            return (chunks, totalSampleCount)
        }

        let stride = max(1, Int((Double(totalSampleCount) / Double(maxSamplesToScan)).rounded(.up)))
        var selected: [XdfChunkIndex] = []
        var scanned = 0
        var i = 0
        while i < chunks.count, scanned < maxSamplesToScan {
            let chunk = chunks[i]
            selected.append(chunk)
            scanned += chunk.declaredSampleCount
            i += stride
        }
        if selected.isEmpty, let first = chunks.first {
            // Every chunk was skipped by the stride (shouldn't happen given
            // `stride`'s derivation, but fall back to at least one chunk
            // rather than an empty envelope).
            selected = [first]
            scanned = first.declaredSampleCount
        }
        return (selected, max(scanned, 1))
    }
}

public extension Array where Element == XdfChunkIndex {
    /// Sum of every chunk's `declaredSampleCount`, saturating at `Int.max`
    /// instead of trapping on overflow. Declared counts come straight from the
    /// file (each is only individually clamped to `Int.max` at index time), so
    /// two pathological chunks can overflow a plain `+`. Used as the fallback
    /// total when a stream footer carries no `sample_count`.
    var totalDeclaredSampleCount: Int {
        reduce(0) { acc, chunk in
            let (sum, overflowed) = acc.addingReportingOverflow(chunk.declaredSampleCount)
            return overflowed ? Int.max : sum
        }
    }
}

public extension Array where Element == XdfChannelEnvelope {
    /// The channel with the largest peak-to-peak range — a cheap proxy for
    /// "has real signal", used to pick a representative channel for
    /// sparklines/thumbnails. Some recordings only feed one of many declared
    /// channels (e.g. a single active sensor out of sixteen); always picking
    /// channel 0 would show a flat line for those even though the stream has
    /// real data elsewhere.
    func mostInformative() -> XdfChannelEnvelope? {
        // Uses each envelope's cached `peakToPeak` (computed once at init)
        // instead of rescanning every column here on each call.
        self.max { $0.peakToPeak < $1.peakToPeak }
    }
}
