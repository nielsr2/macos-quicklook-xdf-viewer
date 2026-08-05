import Foundation

/// XDF chunk tag values, per the format spec (github.com/sccn/xdf).
public enum XdfChunkTag: UInt16, Sendable, Equatable {
    case fileHeader = 1
    case streamHeader = 2
    case samples = 3
    case clockOffset = 4
    case boundary = 5
    case streamFooter = 6
}
