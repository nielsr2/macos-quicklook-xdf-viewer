import SwiftUI

/// Right-edge collapsible events panel shared by `FullWaveformView` and
/// `SoloChannelView`, matching the Windows original's events pane. A slim
/// toggle strip stays visible in both states so the plot keeps full width
/// when collapsed; expanded it lists every marker in the file chronologically
/// as "time  value" rows with its own value-substring search. Clicking a row
/// hands the event back to the host via `onSelect`, which centres the plot on
/// that event's time at the current zoom.
///
/// The host is responsible for only mounting this when events are actually
/// mappable (`stream.firstTimestamp != nil` and markers exist) — mirroring the
/// Windows original, which suppresses the events pane on the same condition.
struct TimelineEventsPanel: View {
    /// All of the file's markers, already timestamp-sorted by the host.
    let events: [XdfMarkerEvent]
    /// Zero point on the timeline (the stream's `firstTimestamp`); marker
    /// timestamps are absolute and shown relative to this.
    let streamStartTimestamp: Double
    @Binding var isExpanded: Bool
    /// Invoked with the tapped event so the host can centre the plot on it.
    var onSelect: (XdfMarkerEvent) -> Void

    @State private var searchText: String = ""

    private static let expandedWidth: CGFloat = 260

    private var filteredEvents: [(offset: Int, event: XdfMarkerEvent)] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs = events.enumerated().map { (offset: $0.offset, event: $0.element) }
        guard !query.isEmpty else { return pairs }
        return pairs.filter { $0.event.label.localizedCaseInsensitiveContains(query) }
    }

    private var countLabel: String {
        let n = events.count
        return "\(n) event\(n == 1 ? "" : "s")"
    }

    var body: some View {
        HStack(spacing: 0) {
            Divider()
            toggleStrip
            if isExpanded {
                Divider()
                expandedBody
                    .frame(width: Self.expandedWidth)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toggleStrip: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.right" : "chevron.left")
                    .font(.caption)
                Image(systemName: "flag")
                    .font(.caption)
                Text("Events")
                    .font(.caption2)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(height: 48)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            .frame(width: 26)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isExpanded ? "Hide events" : "Show events")
    }

    private var expandedBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text(countLabel)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            Divider()

            if filteredEvents.isEmpty {
                Text(searchText.isEmpty ? "No events" : "No matching events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredEvents, id: \.offset) { item in
                            eventRow(item.event)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("Filter events", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
    }

    private func eventRow(_ event: XdfMarkerEvent) -> some View {
        Button {
            onSelect(event)
        } label: {
            HStack(spacing: 8) {
                Text(TimeAxis.formatTime(event.timestamp - streamStartTimestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Text(event.label.isEmpty ? "—" : event.label)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    struct PreviewHost: View {
        @State private var expanded = true
        var body: some View {
            TimelineEventsPanel(
                events: [
                    XdfMarkerEvent(timestamp: 1.5, label: "trial_start"),
                    XdfMarkerEvent(timestamp: 6.25, label: "stimulus_on"),
                    XdfMarkerEvent(timestamp: 6.4, label: "fixation"),
                    XdfMarkerEvent(timestamp: 74.0, label: "trial_end"),
                    XdfMarkerEvent(timestamp: 3620.0, label: "block_2_start_with_a_long_label"),
                ],
                streamStartTimestamp: 0,
                isExpanded: $expanded,
                onSelect: { _ in })
                .frame(width: 290, height: 320)
        }
    }
    return PreviewHost()
}
