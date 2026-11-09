/// Failure to restore a versioned grammar, tokenizer, or compiled mask cache.
public enum SerializationError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalidJSON(String)
    case version(found: String?, expected: String)
    case format(String)

    public var description: String {
        switch self {
        case .invalidJSON(let message): "Invalid serialized JSON: \(message)"
        case .version(let found, let expected): "Serialization version \(found ?? "missing"); expected \(expected)"
        case .format(let message): "Invalid serialized object: \(message)"
        }
    }
}

/// The format version written into serialized grammars, tokenizers and compiled grammars,
/// XGrammar's `get_serialization_version()`. Restoring data written with another version throws
/// ``SerializationError/version(found:expected:)``; key on-disk caches by it.
public let serializationVersion = "v18"

enum SerializationValue {
    static let version = serializationVersion
    static func parse(_ source: String) throws(SerializationError) -> JSONValue {
        let value: JSONValue
        do { value = try JSONValue.parse(source) }
        catch { throw .invalidJSON(error.description) }
        guard value.members != nil else { throw .format("Expected an object") }
        guard value["__VERSION__"]?.string == version else { throw .version(found: value["__VERSION__"]?.string, expected: version) }
        return value
    }

    static func object(_ members: [(String, JSONValue)], versioned: Bool = false) -> JSONValue {
        .object((members + (versioned ? [("__VERSION__", .string(version))] : [])).map { .init(key: $0.0, value: $0.1) })
    }
    static func number(_ value: some BinaryInteger) -> JSONValue { .number(String(value)) }
    static func numbers(_ values: some Sequence<some BinaryInteger>) -> JSONValue {
        var result: [JSONValue] = []
        result.reserveCapacity(values.underestimatedCount)
        for value in values { result.append(number(value)) }
        return .array(result)
    }
    static func required(_ value: JSONValue, _ key: String) throws(SerializationError) -> JSONValue {
        guard let field = value[key] else { throw .format("Missing \(key)") }
        return field
    }
    static func array(_ value: JSONValue, count: Int? = nil) throws(SerializationError) -> [JSONValue] {
        guard let array = value.array, count.map({ $0 == array.count }) ?? true else { throw .format("Expected an array\(count.map { " of \($0) elements" } ?? "")") }
        return array
    }
    static func integer<T: FixedWidthInteger>(_ value: JSONValue, as: T.Type = T.self) throws(SerializationError) -> T {
        guard let number = value.integer, let result = T(exactly: number) else { throw .format("Integer is missing or out of range") }
        return result
    }
    static func integers<T: FixedWidthInteger>(_ value: JSONValue, as: T.Type = T.self) throws(SerializationError) -> [T] {
        try array(value).map { value throws(SerializationError) in try integer(value) }
    }
    static func bool(_ value: JSONValue) throws(SerializationError) -> Bool {
        guard let value = value.bool else { throw .format("Expected a boolean") }
        return value
    }

    // Upstream JSON uses Latin-1 strings for arbitrary bytes, including UTF-8 rule names.
    static func bytes(_ bytes: some Sequence<UInt8>) -> JSONValue {
        .string(String(String.UnicodeScalarView(bytes.map { UnicodeScalar($0) })))
    }
    static func text(_ text: String) -> JSONValue { bytes(text.utf8) }
    static func decodeBytes(_ value: JSONValue) throws(SerializationError) -> [UInt8] {
        guard let text = value.string else { throw .format("Expected a Latin-1 byte string") }
        return try text.unicodeScalars.map { scalar throws(SerializationError) in
            guard scalar.value <= 255 else { throw .format("Byte string contains a scalar outside Latin-1") }
            return UInt8(scalar.value)
        }
    }
    static func decodeText(_ value: JSONValue) throws(SerializationError) -> String {
        let bytes = try decodeBytes(value)
        guard let text = String(validating: bytes, as: UTF8.self) else { throw .format("Text is not valid UTF-8") }
        return text
    }
    static func check(_ condition: Bool, _ message: String) throws(SerializationError) {
        guard condition else { throw .format(message) }
    }
}
