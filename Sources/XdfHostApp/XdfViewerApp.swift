import SwiftUI
import XdfViewerCore

@main
struct XdfViewerApp: App {
    @StateObject private var settings = XdfViewerSettings.shared

    var body: some Scene {
        Window("XdfViewer", id: "main") {
            XdfAboutView(settings: settings)
        }
        .windowResizability(.contentSize)

        // Preferences window (⌘,) reusing the same settings the preview uses.
        Settings {
            XdfSettingsPopover(settings: settings)
                .padding()
        }
    }
}
