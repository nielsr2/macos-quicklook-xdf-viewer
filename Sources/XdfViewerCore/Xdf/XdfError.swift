import Foundation

public enum XdfError: Error, Sendable, Equatable {
    case badMagic
    case truncated
    case unsupportedFormat(String)
    case malformedXML
    case unknownTag(UInt16)
}
