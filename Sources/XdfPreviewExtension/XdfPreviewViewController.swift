import Cocoa
import Quartz
import SwiftUI
import XdfViewerCore
import os

/// View-based Quick Look preview for .xdf recordings: reads the file's fast
/// structural pass off the main thread, then hosts the SwiftUI
/// `XdfPreviewView` (stream-card overview). Mirrors the async/MainActor/
/// NSHostingView shape used by `PreviewExtension/PreviewViewController.swift`.
final class XdfPreviewViewController: NSViewController, QLPreviewingController {

    private static let log = Logger(subsystem: "com.nielsr2.XdfViewer", category: "preview")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 550))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        Self.log.debug("preparePreviewOfFile: \(url.lastPathComponent, privacy: .public)")

        // Fast structural pass (magic + chunk-boundary walk + header/footer
        // XML; no sample decode) off the main thread.
        let document = try await Task.detached(priority: .userInitiated) { () -> XdfDocument in
            try XdfReader.readStructure(url: url)
        }.value

        await MainActor.run {
            let model = XdfOverviewViewModel(fileURL: url, document: document)
            let root = XdfPreviewView(model: model)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = self.view.bounds
            hosting.autoresizingMask = [.width, .height]
            self.view.subviews.forEach { $0.removeFromSuperview() }
            self.view.addSubview(hosting)
        }
    }
}
