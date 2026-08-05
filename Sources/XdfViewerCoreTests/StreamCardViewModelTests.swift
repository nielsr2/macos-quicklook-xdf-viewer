import XCTest
@testable import XdfViewerCore

/// Exercises `StreamCardViewModel`'s channel-list construction and its
/// default expander state — always expanded, regardless of channel count,
/// matching the Windows original (which never auto-collapses a stream card).
/// A prior revision auto-collapsed streams above a 32-channel threshold;
/// that's been removed per a deliberate redesign decision (see
/// `XdfPreviewView`'s fill-height card layout, which makes an always-open
/// card practical even for a large channel count since its list now scrolls
/// within the window's available height instead of a fixed cap).
final class StreamCardViewModelTests: XCTestCase {

    private func stream(channelCount: Int) -> XdfStreamInfo {
        XdfStreamInfo(streamID: 1,
                      name: "S1",
                      type: "EEG",
                      channelCount: channelCount,
                      nominalSampleRate: 256,
                      channelFormat: .float32,
                      channels: (0..<channelCount).map { XdfChannelInfo(label: "Ch\($0)", unit: nil, type: "EEG") })
    }

    func testBuildsOneChannelViewModelPerChannelInIndexOrder() {
        let vm = StreamCardViewModel(stream: stream(channelCount: 4))
        XCTAssertEqual(vm.channels.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(vm.channels.map(\.label), ["Ch0", "Ch1", "Ch2", "Ch3"])
    }

    func testAlwaysStartsExpandedRegardlessOfChannelCount() {
        XCTAssertTrue(StreamCardViewModel(stream: stream(channelCount: 1)).isExpanded)
        XCTAssertTrue(StreamCardViewModel(stream: stream(channelCount: 32)).isExpanded)
        XCTAssertTrue(StreamCardViewModel(stream: stream(channelCount: 33)).isExpanded)
        XCTAssertTrue(StreamCardViewModel(stream: stream(channelCount: 144)).isExpanded)
    }

    func testDetailNotLoadedInitially() {
        let vm = StreamCardViewModel(stream: stream(channelCount: 2))
        XCTAssertFalse(vm.detailLoaded)
        XCTAssertTrue(vm.channels.allSatisfy { $0.detail == nil && !$0.isLoadingDetail })
    }
}
