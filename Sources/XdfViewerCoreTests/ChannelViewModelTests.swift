import XCTest
@testable import XdfViewerCore

/// Exercises `ChannelViewModel`'s label/unit resolution — the same
/// positional-fallback convention `FullWaveformView.channelLabel(at:)`
/// already uses, now centralized here so every channel-centric view (rows,
/// solo view) agrees on what a channel is called.
final class ChannelViewModelTests: XCTestCase {

    private func stream(channels: [XdfChannelInfo], channelCount: Int? = nil) -> XdfStreamInfo {
        XdfStreamInfo(streamID: 1,
                      name: "S1",
                      type: "EEG",
                      channelCount: channelCount ?? channels.count,
                      nominalSampleRate: 256,
                      channelFormat: .float32,
                      channels: channels)
    }

    func testUsesDeclaredLabelWhenPresent() {
        let s = stream(channels: [XdfChannelInfo(label: "Fp1", unit: "microvolts", type: "EEG")])
        let channel = ChannelViewModel(index: 0, stream: s)
        XCTAssertEqual(channel.label, "Fp1")
        XCTAssertEqual(channel.unit, "microvolts")
    }

    func testFallsBackToPositionalLabelWhenEmpty() {
        let s = stream(channels: [XdfChannelInfo(label: "", unit: "microvolts", type: "EEG")])
        let channel = ChannelViewModel(index: 0, stream: s)
        XCTAssertEqual(channel.label, "Ch 1")
    }

    func testFallsBackToPositionalLabelWhenNil() {
        let s = stream(channels: [XdfChannelInfo(label: nil, unit: nil, type: "EEG")])
        let channel = ChannelViewModel(index: 0, stream: s)
        XCTAssertEqual(channel.label, "Ch 1")
        XCTAssertNil(channel.unit)
    }

    func testFallsBackToPositionalLabelWhenHeaderDeclaresFewerChannelsThanChannelCount() {
        // channelCount says 3 but only 1 <channel> entry is present — a
        // malformed-but-not-uncommon header shape; index 2 has no matching
        // XdfChannelInfo at all.
        let s = stream(channels: [XdfChannelInfo(label: "Fp1", unit: nil, type: "EEG")], channelCount: 3)
        let channel = ChannelViewModel(index: 2, stream: s)
        XCTAssertEqual(channel.label, "Ch 3")
        XCTAssertNil(channel.unit)
    }

    func testIndexMatchesIdentifiableID() {
        let channel = ChannelViewModel(index: 5, label: "X", unit: nil)
        XCTAssertEqual(channel.id, 5)
    }
}
