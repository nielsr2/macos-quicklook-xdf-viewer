import Foundation

/// One `<channel>` entry from a stream's header metadata.
public struct XdfChannelInfo: Sendable, Equatable {
    public var label: String?
    public var unit: String?
    public var type: String?

    public init(label: String? = nil, unit: String? = nil, type: String? = nil) {
        self.label = label
        self.unit = unit
        self.type = type
    }
}
