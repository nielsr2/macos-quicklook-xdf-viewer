import Foundation

/// Maps the XDF `<channel_format>` string to its on-disk sample width.
public enum XdfSampleFormat: String, Sendable, Equatable, CaseIterable {
    case int8, int16, int32, int64, float32, double64, string

    public init?(xmlValue: String) {
        self.init(rawValue: xmlValue)
    }

    /// Byte width of one sample value, or `nil` for the variable-length `string` format.
    public var byteWidth: Int? {
        switch self {
        case .int8: return 1
        case .int16: return 2
        case .int32, .float32: return 4
        case .int64, .double64: return 8
        case .string: return nil
        }
    }
}
