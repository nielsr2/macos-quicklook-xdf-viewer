import Foundation

/// Plain-value bag of everything Stage 1 cares about from a `FileHeader`,
/// `StreamHeader`, or `StreamFooter` XML blob. Fields that were absent or
/// unparseable in the source XML are left at their defaults — parsing a
/// single stream's XML never throws, so one malformed stream can't abort
/// the read of the rest of the file.
struct XdfHeaderFields {
    var name: String = ""
    var type: String = ""
    var channelCount: Int = 0
    var nominalSampleRate: Double = 0
    /// Defaults to `.float32` (LSL's own default) when `<channel_format>` is
    /// missing or doesn't match a known value.
    var channelFormat: XdfSampleFormat = .float32
    var channels: [XdfChannelInfo] = []

    // StreamFooter fields.
    var firstTimestamp: Double?
    var lastTimestamp: Double?
    var sampleCount: Int?
    var effectiveSampleRate: Double?

    // FileHeader field.
    var version: String?
}

/// Parses the small, flat XML metadata embedded in XDF `FileHeader`,
/// `StreamHeader`, and `StreamFooter` chunks using an event-driven
/// `XMLParser`, rather than the heavier `XMLDocument` API.
enum XdfHeaderXMLParser {
    /// Parses `xml` and returns whatever fields could be recovered. Never
    /// throws: invalid UTF-8/XML, unexpected elements, or a parser that bails
    /// out partway through all just yield a best-effort (possibly default)
    /// result.
    static func parse(xml: String) -> XdfHeaderFields {
        guard let data = xml.data(using: .utf8), !data.isEmpty else { return XdfHeaderFields() }
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        _ = parser.parse() // Ignore success/failure — return best-effort fields regardless.
        return delegate.fields
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private(set) var fields = XdfHeaderFields()

        private var currentText = ""
        private var insideChannel = false
        private var currentChannel = XdfChannelInfo()

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            currentText = ""
            if elementName == "channel" {
                insideChannel = true
                currentChannel = XdfChannelInfo()
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            currentText = ""

            if insideChannel {
                switch elementName {
                case "label": currentChannel.label = text.isEmpty ? nil : text
                case "unit": currentChannel.unit = text.isEmpty ? nil : text
                case "type": currentChannel.type = text.isEmpty ? nil : text
                case "channel":
                    fields.channels.append(currentChannel)
                    insideChannel = false
                default: break
                }
                return
            }

            switch elementName {
            case "name": fields.name = text
            case "type": fields.type = text
            // Clamp to >= 0: a malformed negative count would trap every
            // downstream `0..<channelCount` (StreamCardViewModel, readEnvelopes).
            case "channel_count": fields.channelCount = max(0, Int(text) ?? 0)
            case "nominal_srate": fields.nominalSampleRate = Double(text) ?? 0
            case "channel_format": fields.channelFormat = XdfSampleFormat(xmlValue: text) ?? .float32
            case "first_timestamp": fields.firstTimestamp = Double(text)
            case "last_timestamp": fields.lastTimestamp = Double(text)
            case "sample_count": fields.sampleCount = Int(text)
            case "effective_srate": fields.effectiveSampleRate = Double(text)
            case "version": fields.version = text
            default: break
            }
        }

        // A malformed document ends parsing early; `parser.parse()`'s return
        // value is ignored by the caller, so nothing extra to do here beyond
        // letting whatever fields were already collected stand.
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {}
    }
}
