import Foundation

/// Loads every marker/event stream in a document and merges them into one
/// timestamp-sorted list. Markers belong to the whole file, not any single
/// data stream — this is shared by every timeline view that overlays them
/// (`FullWaveformView`, and the single-channel solo view).
///
/// Extracted from `FullWaveformView.loadMarkers()` (Stage 5 channel-centric
/// redesign, Phase 0) so both views decode markers identically.
enum XdfFileMarkerLoader {
    static func loadMarkers(document: XdfDocument, fileURL: URL) async -> [XdfMarkerEvent] {
        let markerStreams = document.streams.filter { $0.channelFormat == .string && $0.channelCount == 1 }
        guard !markerStreams.isEmpty else { return [] }

        return await Task.detached(priority: .userInitiated) { () -> [XdfMarkerEvent] in
            var all: [XdfMarkerEvent] = []
            for markerStream in markerStreams {
                let chunks = document.chunks(forStream: markerStream.streamID)
                all.append(contentsOf: XdfMarkerReader.readMarkers(url: fileURL,
                                                                     chunks: chunks,
                                                                     channelCount: markerStream.channelCount,
                                                                     channelFormat: markerStream.channelFormat))
            }
            return all.sorted { $0.timestamp < $1.timestamp }
        }.value
    }
}
