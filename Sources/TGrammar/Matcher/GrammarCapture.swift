/// A completed named region, in completion order. Bytes remain available for partial UTF-8
/// tokens; `text` decodes them when the captured region is valid text.
public struct GrammarCapture: Sendable, Hashable {
    public let name: String
    public let bytes: [UInt8]
    public var text: String { String(decoding: bytes, as: UTF8.self) }
    public init(name: String, bytes: [UInt8]) { self.name = name; self.bytes = bytes }
}
