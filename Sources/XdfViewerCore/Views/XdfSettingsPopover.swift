import SwiftUI

/// The settings editor exposing appearance options for the XDF preview.
/// Changes persist immediately via `XdfViewerSettings`.
public struct XdfSettingsPopover: View {
    @ObservedObject var settings: XdfViewerSettings

    public init(settings: XdfViewerSettings) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: bind(\.theme)) {
                    ForEach(XdfAppearanceTheme.allCases) { Text($0.label).tag($0) }
                }
                Picker("Accent color", selection: bind(\.accentColor)) {
                    ForEach(XdfAccentColor.allCases) { swatch in
                        Label {
                            Text(swatch.label)
                        } icon: {
                            Circle().fill(swatch.color).frame(width: 12, height: 12)
                        }
                        .tag(swatch)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
        .frame(maxHeight: 200)
    }

    /// Binding into an `XdfViewerSettings` property that re-publishes on write.
    private func bind<Value>(_ keyPath: ReferenceWritableKeyPath<XdfViewerSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0 }
        )
    }
}

#Preview {
    XdfSettingsPopover(settings: .shared)
        .padding()
}
