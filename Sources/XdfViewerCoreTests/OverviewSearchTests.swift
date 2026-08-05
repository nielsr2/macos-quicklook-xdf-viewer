import XCTest
@testable import XdfViewerCore

/// Exercises the overview's unified search predicate:
/// `StreamCardViewModel.filterChannels`/`filterEvents`, the pure
/// case-insensitive substring filters `StreamCardView` uses to hide channel
/// rows (by label) and event rows (by value) as the user types into the
/// single top-bar search field (`XdfOverviewViewModel.searchText`).
final class OverviewSearchTests: XCTestCase {

    private func channel(_ label: String) -> ChannelViewModel {
        ChannelViewModel(index: 0, label: label, unit: nil)
    }

    private func event(_ value: String) -> StreamCardViewModel.MarkerEventRow {
        StreamCardViewModel.MarkerEventRow(index: 0, timestamp: 0, timeLabel: "0:00", value: value)
    }

    // MARK: Channels

    func testEmptyQueryMatchesAllChannels() {
        let channels = [channel("Fp1"), channel("Fp2"), channel("Cz")]
        XCTAssertEqual(StreamCardViewModel.filterChannels(channels, matching: "").map(\.label), ["Fp1", "Fp2", "Cz"])
    }

    func testWhitespaceOnlyQueryMatchesAllChannels() {
        let channels = [channel("Fp1"), channel("Fp2")]
        XCTAssertEqual(StreamCardViewModel.filterChannels(channels, matching: "   ").count, 2)
    }

    func testChannelSubstringMatchIsCaseInsensitive() {
        let channels = [channel("Fp1"), channel("Fp2"), channel("Cz")]
        XCTAssertEqual(StreamCardViewModel.filterChannels(channels, matching: "fp").map(\.label), ["Fp1", "Fp2"])
        XCTAssertEqual(StreamCardViewModel.filterChannels(channels, matching: "CZ").map(\.label), ["Cz"])
    }

    func testChannelQueryWithNoMatchesReturnsEmpty() {
        let channels = [channel("Fp1"), channel("Fp2")]
        XCTAssertTrue(StreamCardViewModel.filterChannels(channels, matching: "xyz").isEmpty)
    }

    // MARK: Events

    func testEmptyQueryMatchesAllEvents() {
        let events = [event("trial_start"), event("trial_end")]
        XCTAssertEqual(StreamCardViewModel.filterEvents(events, matching: "").count, 2)
    }

    func testEventSubstringMatchIsCaseInsensitiveOnValue() {
        let events = [event("trial_start"), event("STIMULUS_ON"), event("response")]
        XCTAssertEqual(StreamCardViewModel.filterEvents(events, matching: "trial").map(\.value), ["trial_start"])
        XCTAssertEqual(StreamCardViewModel.filterEvents(events, matching: "stimulus").map(\.value), ["STIMULUS_ON"])
    }

    func testEventQueryWithNoMatchesReturnsEmpty() {
        let events = [event("trial_start"), event("trial_end")]
        XCTAssertTrue(StreamCardViewModel.filterEvents(events, matching: "nope").isEmpty)
    }

    // MARK: isMarkerStream classification (drives which predicate a card uses)

    func testMarkerStreamClassification() {
        let markerStream = XdfStreamInfo(streamID: 1,
                                          name: "Markers",
                                          type: "Markers",
                                          channelCount: 1,
                                          nominalSampleRate: 0,
                                          channelFormat: .string)
        XCTAssertTrue(StreamCardViewModel(stream: markerStream).isMarkerStream)

        let numericStream = XdfStreamInfo(streamID: 2,
                                           name: "EEG",
                                           type: "EEG",
                                           channelCount: 4,
                                           nominalSampleRate: 256,
                                           channelFormat: .float32)
        XCTAssertFalse(StreamCardViewModel(stream: numericStream).isMarkerStream)

        // Multi-channel string format is not treated as a marker stream —
        // no established convention for what a "label" means across
        // multiple string channels (mirrors XdfMarkerReader's own guard).
        let multiChannelStringStream = XdfStreamInfo(streamID: 3,
                                                      name: "Weird",
                                                      type: "Other",
                                                      channelCount: 2,
                                                      nominalSampleRate: 0,
                                                      channelFormat: .string)
        XCTAssertFalse(StreamCardViewModel(stream: multiChannelStringStream).isMarkerStream)
    }
}
