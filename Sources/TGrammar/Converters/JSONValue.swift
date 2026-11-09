import Foundation

// Ordered objects and lexical numbers are essential here: schema property order controls
// generation order, and decoding 19.99 through a binary float changes literal constraints.
indirect enum JSONValue: Sendable, Hashable {
    struct Member: Sendable, Hashable {
        var key: String
        var value: JSONValue
    }
    case object([Member])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    subscript(_ key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }
    var members: [Member]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var integer: Int64? { if case .number(let value) = self { Int64(value) } else { nil } }
    var double: Double? { if case .number(let value) = self { Double(value) } else { nil } }

    func replacing(_ key: String, with value: JSONValue) -> JSONValue {
        var members = self.members ?? []
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
        } else { members.append(.init(key: key, value: value)) }
        return .object(members)
    }

    func removing(_ key: String) -> JSONValue {
        .object((members ?? []).filter { $0.key != key })
    }

    func serialized(itemSeparator: String = ",", keySeparator: String = ":") -> String {
        var output: [UInt8] = []
        write(to: &output, itemSeparator: Array(itemSeparator.utf8), keySeparator: Array(keySeparator.utf8))
        return String(decoding: output, as: UTF8.self)
    }

    /// Appends the serialization to one buffer: nested string joins copied every byte once per
    /// nesting level, which dominated compiled-grammar serialization.
    private func write(to output: inout [UInt8], itemSeparator: [UInt8], keySeparator: [UInt8]) {
        switch self {
        case .object(let members):
            output.append(UInt8(ascii: "{"))
            for (index, member) in members.enumerated() {
                if index > 0 { output.append(contentsOf: itemSeparator) }
                Self.writeQuoted(member.key, to: &output)
                output.append(contentsOf: keySeparator)
                member.value.write(to: &output, itemSeparator: itemSeparator, keySeparator: keySeparator)
            }
            output.append(UInt8(ascii: "}"))
        case .array(let values):
            output.append(UInt8(ascii: "["))
            for (index, value) in values.enumerated() {
                if index > 0 { output.append(contentsOf: itemSeparator) }
                value.write(to: &output, itemSeparator: itemSeparator, keySeparator: keySeparator)
            }
            output.append(UInt8(ascii: "]"))
        case .string(let value): Self.writeQuoted(value, to: &output)
        case .number(let value):
            if Self.isCanonicalInteger(value) { output.append(contentsOf: value.utf8) }
            else { output.append(contentsOf: Self.canonicalNumber(value).utf8) }
        case .bool(let value): output.append(contentsOf: (value ? "true" : "false").utf8)
        case .null: output.append(contentsOf: "null".utf8)
        }
    }

    /// `quote(_:)` written as UTF-8 bytes.
    private static func writeQuoted(_ string: String, to output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case 0x22: output.append(contentsOf: [0x5C, 0x22])
            case 0x5C: output.append(contentsOf: [0x5C, 0x5C])
            case 8: output.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 9: output.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 10: output.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 12: output.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 13: output.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0 ..< 32:
                let digits = Array("0123456789abcdef".utf8)
                output.append(contentsOf: [0x5C, UInt8(ascii: "u"), 0x30, 0x30, digits[Int(byte >> 4)], digits[Int(byte & 0xF)]])
            default: output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
    }

    /// Whether `canonicalNumber(_:)` returns `source` unchanged: an integer without leading zeros
    /// (and not `-0`).
    private static func isCanonicalInteger(_ source: String) -> Bool {
        var bytes = source.utf8[...]
        if bytes.first == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
        guard let first = bytes.first, bytes.allSatisfy({ (0x30 ... 0x39).contains($0) }) else { return false }
        return first != 0x30 || (bytes.count == 1 && source.utf8.count == 1)
    }

    static func quote(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 0 ..< 32:
                let hex = String(scalar.value, radix: 16)
                result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private static func canonicalNumber(_ source: String) -> String {
        let negative = source.hasPrefix("-")
        let unsigned = negative ? String(source.dropFirst()) : source
        let pieces = unsigned.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        let exponent = pieces.count == 2 ? Int(pieces[1]) : 0
        guard let exponent, exponent > -1024, exponent < 1024 else { return source }
        let mantissa = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        var digits = String(mantissa.joined())
        var point = mantissa[0].count + exponent
        while digits.first == "0", digits.count > 1 { digits.removeFirst(); point -= 1 }
        while digits.last == "0", digits.count > 1 { digits.removeLast() }
        if digits == "0" { return "0" }
        let value: String
        if point <= 0 { value = "0." + String(repeating: "0", count: -point) + digits }
        else if point >= digits.count { value = digits + String(repeating: "0", count: point - digits.count) }
        else {
            let index = digits.index(digits.startIndex, offsetBy: point)
            value = String(digits[..<index]) + "." + digits[index...]
        }
        return negative ? "-" + value : value
    }

    static func parse(_ source: String) throws(GrammarError) -> JSONValue {
        var parser = JSONReader(bytes: Array(source.utf8))
        let result = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.position == parser.bytes.count else { throw parser.error("Unexpected trailing input") }
        return result
    }
}

private struct JSONReader {
    let bytes: [UInt8]
    var position = 0
    func error(_ message: String) -> GrammarError { .conversion("Invalid JSON at byte \(position): \(message)") }
    mutating func whitespace() {
        while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
    }
    mutating func consume(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }
    mutating func value(depth: Int) throws(GrammarError) -> JSONValue {
        guard depth < 512 else { throw error("JSON is nested deeper than 512 levels") }
        guard StackGuard.hasRoom else { throw error(StackGuard.message) }
        whitespace()
        guard position < bytes.count else { throw error("Expected a value") }
        switch bytes[position] {
        case 123:
            position += 1
            var members: [JSONValue.Member] = []
            var keys = Set<String>()
            whitespace()
            if consume(125) { return .object(members) }
            while true {
                whitespace()
                let key = try string()
                guard keys.insert(key).inserted else { throw error("Duplicate object key \(key)") }
                whitespace()
                guard consume(58) else { throw error("Expected ':'") }
                members.append(.init(key: key, value: try value(depth: depth + 1)))
                whitespace()
                if consume(125) { return .object(members) }
                guard consume(44) else { throw error("Expected ',' or '}'") }
            }
        case 91:
            position += 1
            var values: [JSONValue] = []
            whitespace()
            if consume(93) { return .array(values) }
            while true {
                values.append(try value(depth: depth + 1))
                whitespace()
                if consume(93) { return .array(values) }
                guard consume(44) else { throw error("Expected ',' or ']'") }
            }
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        case 45, 48 ... 57: return .number(try number())
        default: throw error("Expected a JSON value")
        }
    }
    mutating func literal(_ text: String) throws(GrammarError) {
        for byte in text.utf8 {
            guard consume(byte) else { throw error("Expected \(text)") }
        }
    }
    mutating func string() throws(GrammarError) -> String {
        guard consume(34) else { throw error("Expected a string") }
        var result: [UInt8] = []
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            if byte == 34 {
                guard let value = String(bytes: result, encoding: .utf8) else { throw error("Invalid UTF-8") }
                return value
            }
            guard byte >= 32 else { throw error("Unescaped control character") }
            if byte != 92 { result.append(byte); continue }
            guard position < bytes.count else { throw error("Unfinished string escape") }
            let escape = bytes[position]
            position += 1
            switch escape {
            case 34, 92, 47: result.append(escape)
            case 98: result.append(8)
            case 102: result.append(12)
            case 110: result.append(10)
            case 114: result.append(13)
            case 116: result.append(9)
            case 117:
                var codepoint = try hex4()
                if (0xD800 ... 0xDBFF).contains(codepoint) {
                    guard consume(92), consume(117) else { throw error("Expected a low surrogate") }
                    let low = try hex4()
                    guard (0xDC00 ... 0xDFFF).contains(low) else { throw error("Invalid low surrogate") }
                    codepoint = 0x10000 + (codepoint - 0xD800) * 1024 + low - 0xDC00
                }
                guard let scalar = Unicode.Scalar(codepoint) else { throw error("Invalid Unicode scalar") }
                result.append(contentsOf: String(scalar).utf8)
            default: throw error("Invalid string escape")
            }
        }
        throw error("Unterminated string")
    }
    mutating func hex4() throws(GrammarError) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0 ..< 4 {
            guard position < bytes.count else { throw error("Invalid Unicode escape") }
            let digit = EscapeCodec.hexValue(bytes[position])
            guard digit >= 0 else { throw error("Invalid Unicode escape") }
            value = value * 16 + UInt32(digit)
            position += 1
        }
        return value
    }
    mutating func number() throws(GrammarError) -> String {
        let start = position
        _ = consume(45)
        if !consume(48) {
            guard position < bytes.count, (49 ... 57).contains(bytes[position]) else { throw error("Invalid number") }
            digits()
        }
        if consume(46) {
            let before = position
            digits()
            guard position > before else { throw error("Expected fraction digits") }
        }
        if consume(101) || consume(69) {
            _ = consume(43) || consume(45)
            let before = position
            digits()
            guard position > before else { throw error("Expected exponent digits") }
        }
        return String(decoding: bytes[start ..< position], as: UTF8.self)
    }
    mutating func digits() {
        while position < bytes.count, (48 ... 57).contains(bytes[position]) { position += 1 }
    }
}
