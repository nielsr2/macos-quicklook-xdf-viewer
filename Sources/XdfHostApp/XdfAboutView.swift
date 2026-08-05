import SwiftUI
import XdfViewerCore

/// The host app's window: an "About" summary explaining how to enable the
/// Quick Look preview, plus the default settings editor. The app exists
/// mainly so macOS registers the embedded Quick Look extensions — it must be
/// launched at least once from /Applications.
struct XdfAboutView: View {
    @ObservedObject var settings: XdfViewerSettings

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 40))
                        .foregroundStyle(settings.accentColor.color)
                    VStack(alignment: .leading) {
                        Text("XdfViewer").font(.title2.bold())
                        Text("Quick Look preview for XDF recordings").foregroundStyle(.secondary)
                    }
                }
                Text("Adds a multi-stream overview and waveform preview to Quick Look for .xdf (Lab Streaming Layer) recordings.")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 320, alignment: .leading)

                GroupBox("Enable the preview") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Keep this app in /Applications", systemImage: "1.circle")
                        Label("Launch it once (you're here — done)", systemImage: "2.circle")
                        Label("System Settings → General → Login Items & Extensions → Quick Look → enable XdfViewer", systemImage: "3.circle")
                        Label("Select an .xdf file in Finder and press Space", systemImage: "4.circle")
                    }
                    .font(.callout)
                    .frame(width: 320, alignment: .leading)
                    .padding(6)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading) {
                Text("Default settings").font(.headline).padding(.top, 16).padding(.horizontal, 8)
                XdfSettingsPopover(settings: settings)
            }
        }
        .frame(width: 720, height: 400)
        .preferredColorScheme(settings.theme.colorScheme)
    }
}
