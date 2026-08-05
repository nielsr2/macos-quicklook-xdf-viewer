import QuickLookThumbnailing
import CoreGraphics
import AppKit
import XdfViewerCore
import os

/// Renders a compact stacked multi-stream mini-envelope for Finder icon/list/
/// gallery views: one horizontal min/max band per represented stream.
final class XdfThumbnailProvider: QLThumbnailProvider {

    private static let log = Logger(subsystem: "com.nielsr2.XdfViewer", category: "thumbnail")

    /// Cap on how many streams get a band in the thumbnail — beyond this the
    /// icon gets too cluttered to read at typical Finder sizes.
    private static let maxStreams = 4

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let size = request.maximumSize
        guard size.width > 0, size.height > 0 else {
            handler(nil, nil); return
        }

        // Fast structural pass only — no full sample decode here.
        let document: XdfDocument
        do {
            document = try XdfReader.readStructure(url: request.fileURL)
        } catch {
            Self.log.debug("thumbnail structure read failed: \(error.localizedDescription, privacy: .public)")
            handler(nil, nil)   // fall back to the generic document icon
            return
        }
        guard !document.streams.isEmpty else {
            handler(nil, nil)
            return
        }

        // Numeric streams only — a string-typed marker stream (or a stream
        // with no channels) has no meaningful envelope to draw, so drop
        // those before capping to `maxStreams` rather than after.
        let chosenStreams = document.streams
            .filter { $0.channelFormat != .string && $0.channelCount > 0 }
            .prefix(Self.maxStreams)
        guard !chosenStreams.isEmpty else {
            handler(nil, nil)   // e.g. an all-marker/string file — nothing to draw
            return
        }

        // Coarse per-stream envelope, most-informative channel only — enough
        // visual detail at thumbnail scale, and avoids averaging/mixing
        // channels. Picking channel 0 unconditionally would show a flat line
        // for streams where only one of many declared channels is active.
        let columns = max(8, Int(size.width))
        let envelopes: [XdfChannelEnvelope] = chosenStreams.map { stream in
            let chunks = document.chunks(forStream: stream.streamID)
            let totalSampleCount = stream.sampleCount ?? chunks.totalDeclaredSampleCount
            let streamEnvelopes = XdfEnvelopeReader.readEnvelopes(url: request.fileURL,
                                                                   chunks: chunks,
                                                                   channelCount: stream.channelCount,
                                                                   channelFormat: stream.channelFormat,
                                                                   totalSampleCount: totalSampleCount,
                                                                   columns: columns)
            return streamEnvelopes.mostInformative() ?? .flat(columns: columns)
        }

        let reply = QLThumbnailReply(contextSize: size) { context -> Bool in
            XdfThumbnailProvider.draw(envelopes: envelopes, size: size, context: context)
            return true
        }
        handler(reply, nil)
    }

    private static func draw(envelopes: [XdfChannelEnvelope], size: CGSize, context: CGContext) {
        // Subtle background fill.
        let bg = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .white
        context.setFillColor(bg.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        let accent = (NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemBlue)
        let bandCount = envelopes.count
        let bandHeight = size.height / CGFloat(bandCount)

        for (index, envelope) in envelopes.enumerated() {
            let cols = envelope.columnCount
            guard cols > 0 else { continue }

            // Stack bands top-down in stream order.
            let bandTop = size.height - CGFloat(index) * bandHeight
            let bandBottom = bandTop - bandHeight
            let mid = (bandTop + bandBottom) / 2
            let scale = bandHeight / 2 * 0.85
            let lineWidth = max(0.5, size.width / CGFloat(cols))

            // Slight opacity taper gives adjacent bands visual separation
            // without needing distinct hues per stream.
            let alpha = max(0.55, 1.0 - CGFloat(index) * 0.15)
            context.setStrokeColor(accent.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)

            for col in 0..<cols {
                let x = size.width * CGFloat(col) / CGFloat(cols)
                let top = mid + CGFloat(envelope.maxs[col]) * scale
                let bot = mid + CGFloat(envelope.mins[col]) * scale
                context.move(to: CGPoint(x: x, y: bot))
                context.addLine(to: CGPoint(x: x, y: max(top, bot + 0.5)))
            }
            context.strokePath()
        }
    }
}
