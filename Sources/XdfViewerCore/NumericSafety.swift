import Foundation

/// Clamp-and-truncate a `Double` to `Int` for display formatting without
/// tripping Swift's `Double`→`Int` conversion trap — which aborts the process
/// for non-finite values and for any magnitude ≥ 2^63. These inputs come from
/// unvalidated `.xdf` footer timestamps / durations / sample rates, so a single
/// absurd value must degrade gracefully instead of crashing the preview.
///
/// Truncates toward zero, like `Int(_:)`; callers that want rounding should
/// `.rounded()` first. Non-finite → 0; magnitudes past the safe range saturate
/// to `Int.min` / `Int.max` (`9e18` sits safely below `Int.max` ≈ `9.22e18`).
func safeInt(_ x: Double) -> Int {
    guard x.isFinite else { return 0 }
    if x >= 9.0e18 { return Int.max }
    if x <= -9.0e18 { return Int.min }
    return Int(x)
}
