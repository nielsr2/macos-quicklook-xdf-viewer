import XCTest
@testable import XdfViewerCore

/// Covers `XdfEnvelopeCache`: a second request for the same (streamID, columns)
/// returns the cached result without recomputing, and concurrent requests for
/// the same key coalesce into a single compute.
final class XdfEnvelopeCacheTests: XCTestCase {

    /// Thread-safe compute counter shared with the (Sendable) compute closures.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testSecondRequestReusesCachedResult() async {
        let cache = XdfEnvelopeCache()
        let counter = Counter()
        let make: @Sendable () -> [XdfChannelEnvelope] = {
            counter.increment()
            return [XdfChannelEnvelope(mins: [-1], maxs: [1])]
        }

        let a = await cache.envelopes(streamID: 7, columns: 100, compute: make)
        let b = await cache.envelopes(streamID: 7, columns: 100, compute: make)

        XCTAssertEqual(a, b)
        XCTAssertEqual(counter.count, 1, "second request must hit the cache, not recompute")
    }

    func testDifferentKeysComputeSeparately() async {
        let cache = XdfEnvelopeCache()
        let counter = Counter()
        let make: @Sendable () -> [XdfChannelEnvelope] = {
            counter.increment()
            return [XdfChannelEnvelope(mins: [0], maxs: [0])]
        }

        _ = await cache.envelopes(streamID: 1, columns: 100, compute: make)
        _ = await cache.envelopes(streamID: 1, columns: 200, compute: make)  // different columns
        _ = await cache.envelopes(streamID: 2, columns: 100, compute: make)  // different stream

        XCTAssertEqual(counter.count, 3)
    }

    func testConcurrentRequestsForSameKeyComputeOnce() async {
        let cache = XdfEnvelopeCache()
        let counter = Counter()
        let make: @Sendable () -> [XdfChannelEnvelope] = {
            counter.increment()
            return [XdfChannelEnvelope(mins: [-2], maxs: [2])]
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { _ = await cache.envelopes(streamID: 42, columns: 500, compute: make) }
            }
        }

        XCTAssertEqual(counter.count, 1, "in-flight requests for one key must coalesce")
    }
}
