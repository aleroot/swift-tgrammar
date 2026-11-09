// Byte-level Unicode helpers shared by the EBNF lexer, the grammar printer and the automata
// builders. Everything operates on raw UTF-8 bytes: grammars are matched byte by byte, so the
// natural unit is `UInt8`, and a code point is carried as an `Int32` so that it can also live in
// the grammar's flat `Int32` expression arena.

/// A Unicode scalar value (or, for invalid input, a raw byte value) stored as a 32-bit integer.
public typealias Codepoint = Int32

/// Codec for the UTF-8 encoding used throughout the grammar engine.
enum UTF8Codec {
    /// Marker returned when a byte sequence is not valid UTF-8.
    static let invalid: Codepoint = -1

    /// Decodes the scalar starting at `index`.
    ///
    /// - Returns: The code point and the number of bytes it occupies, or ``invalid`` with
    ///   length `0` when the bytes are not well-formed UTF-8 (including truncated sequences).
    @inline(__always)
    static func decode(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> (codepoint: Codepoint, length: Int) {
        let first = bytes[index]
        if first < 0x80 { return (Codepoint(first), 1) }
        let length: Int
        var value: Int32
        switch first {
        case 0xC0 ... 0xDF: length = 2; value = Int32(first & 0x1F)
        case 0xE0 ... 0xEF: length = 3; value = Int32(first & 0x0F)
        case 0xF0 ... 0xF7: length = 4; value = Int32(first & 0x07)
        default: return (invalid, 0)
        }
        if index + length > bytes.count { return (invalid, 0) }
        for offset in 1 ..< length {
            let continuation = bytes[index + offset]
            if continuation & 0xC0 != 0x80 { return (invalid, 0) }
            value = (value << 6) | Int32(continuation & 0x3F)
        }
        return (value, length)
    }

    /// Decodes a whole buffer into code points. Invalid bytes are preserved as their raw value
    /// (`0x80 ... 0xFF`) when `preservingInvalidBytes` is set; otherwise decoding stops and the
    /// single element ``invalid`` is returned.
    static func decodeAll(_ bytes: UnsafeBufferPointer<UInt8>, preservingInvalidBytes: Bool) -> [Codepoint] {
        var result: [Codepoint] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let (codepoint, length) = decode(bytes, at: index)
            if codepoint == invalid {
                if preservingInvalidBytes {
                    result.append(Codepoint(bytes[index]))
                    index += 1
                    continue
                }
                return [invalid]
            }
            result.append(codepoint)
            index += length
        }
        return result
    }

    /// Appends the UTF-8 encoding of `codepoint` to `output`.
    @inline(__always)
    static func encode(_ codepoint: Codepoint, into output: inout [UInt8]) {
        let value = UInt32(bitPattern: codepoint)
        switch value {
        case 0 ..< 0x80:
            output.append(UInt8(value))
        case 0x80 ..< 0x800:
            output.append(UInt8(0xC0 | (value >> 6)))
            output.append(UInt8(0x80 | (value & 0x3F)))
        case 0x800 ..< 0x10000:
            output.append(UInt8(0xE0 | (value >> 12)))
            output.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
            output.append(UInt8(0x80 | (value & 0x3F)))
        default:
            output.append(UInt8(0xF0 | (value >> 18)))
            output.append(UInt8(0x80 | ((value >> 12) & 0x3F)))
            output.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
            output.append(UInt8(0x80 | (value & 0x3F)))
        }
    }

    /// The UTF-8 bytes of a single code point.
    static func encode(_ codepoint: Codepoint) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(4)
        encode(codepoint, into: &output)
        return output
    }

    /// Number of bytes the UTF-8 encoding of `codepoint` occupies.
    @inline(__always)
    static func encodedLength(of codepoint: Codepoint) -> Int {
        switch codepoint {
        case ..<0x80: 1
        case ..<0x800: 2
        case ..<0x10000: 3
        default: 4
        }
    }
}

/// Backslash escapes shared by string literals and character classes in the EBNF dialect.
enum EscapeCodec {
    /// Marker returned when a backslash sequence is not a recognised escape.
    static let invalidEscape: Codepoint = -2

    /// Resolves a C-style escape letter (`n`, `t`, `\\`, `/`, `e`, …) to its code point.
    @inline(__always)
    static func simpleEscape(_ letter: UInt8) -> Codepoint? {
        switch letter {
        case UInt8(ascii: "'"): Codepoint(UInt8(ascii: "'"))
        case UInt8(ascii: "\""): Codepoint(UInt8(ascii: "\""))
        case UInt8(ascii: "?"): Codepoint(UInt8(ascii: "?"))
        case UInt8(ascii: "\\"): Codepoint(UInt8(ascii: "\\"))
        case UInt8(ascii: "/"): Codepoint(UInt8(ascii: "/"))
        case UInt8(ascii: "a"): 0x07
        case UInt8(ascii: "b"): 0x08
        case UInt8(ascii: "f"): 0x0C
        case UInt8(ascii: "n"): 0x0A
        case UInt8(ascii: "r"): 0x0D
        case UInt8(ascii: "t"): 0x09
        case UInt8(ascii: "v"): 0x0B
        case UInt8(ascii: "0"): 0x00
        case UInt8(ascii: "e"): 0x1B
        default: nil
        }
    }

    @inline(__always)
    static func hexValue(_ byte: UInt8) -> Int32 {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): Int32(byte &- UInt8(ascii: "0"))
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): Int32(byte &- UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): Int32(byte &- UInt8(ascii: "A")) + 10
        default: -1
        }
    }

    /// Parses the escape sequence starting with the backslash at `index`.
    ///
    /// Supports the simple escapes, `\xH…` (any number of hex digits), `\uHHHH` and
    /// `\UHHHHHHHH`. `additional` resolves extra single-letter escapes (used for regex
    /// metacharacters inside character classes) before the built-in table.
    ///
    /// - Returns: The code point and consumed byte count, or ``invalidEscape`` with length `0`.
    static func parseEscape(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at index: Int,
        additional: (UInt8) -> Codepoint? = { _ in nil }
    ) -> (codepoint: Codepoint, length: Int) {
        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\") else { return (invalidEscape, 0) }
        let letter = bytes[index + 1]
        if letter > 128 { return (invalidEscape, 0) }
        if let codepoint = additional(letter) { return (codepoint, 2) }
        if let codepoint = simpleEscape(letter) { return (codepoint, 2) }
        switch letter {
        case UInt8(ascii: "x"):
            var length = 0
            var value: Int32 = 0
            while index + 2 + length < bytes.count {
                let digit = hexValue(bytes[index + 2 + length])
                if digit < 0 { break }
                value = value &* 16 &+ digit
                length += 1
            }
            return length == 0 ? (invalidEscape, 0) : (value, length + 2)
        case UInt8(ascii: "u"), UInt8(ascii: "U"):
            let digits = letter == UInt8(ascii: "u") ? 4 : 8
            guard index + 2 + digits <= bytes.count else { return (invalidEscape, 0) }
            var value: Int32 = 0
            for offset in 0 ..< digits {
                let digit = hexValue(bytes[index + 2 + offset])
                if digit < 0 { return (invalidEscape, 0) }
                value = value &* 16 &+ digit
            }
            return (value, digits + 2)
        default:
            return (invalidEscape, 0)
        }
    }

    /// Decodes either a UTF-8 scalar or an escape sequence at `index`.
    @inline(__always)
    static func parseScalarOrEscape(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at index: Int,
        additional: (UInt8) -> Codepoint? = { _ in nil }
    ) -> (codepoint: Codepoint, length: Int) {
        if bytes[index] == UInt8(ascii: "\\") {
            return parseEscape(bytes, at: index, additional: additional)
        }
        return UTF8Codec.decode(bytes, at: index)
    }

    /// Appends the printable, re-parseable form of `codepoint` to `output`.
    ///
    /// Printable ASCII is emitted as is; control characters and quotes use the short C escapes;
    /// everything else becomes `\xHH`, `\uHHHH` or `\UHHHHHHHH` depending on magnitude.
    static func escape(_ codepoint: Codepoint, into output: inout String, custom: (Codepoint) -> String? = { _ in nil }) {
        if let replacement = custom(codepoint) {
            output += replacement
            return
        }
        switch codepoint {
        case 0x27: output += "\\'"
        case 0x22: output += "\\\""
        case 0x3F: output += "\\?"
        case 0x5C: output += "\\\\"
        case 0x07: output += "\\a"
        case 0x08: output += "\\b"
        case 0x0C: output += "\\f"
        case 0x0A: output += "\\n"
        case 0x0D: output += "\\r"
        case 0x09: output += "\\t"
        case 0x0B: output += "\\v"
        case 0x00: output += "\\0"
        case 0x1B: output += "\\e"
        case 0x20 ... 0x7E:
            output.unicodeScalars.append(Unicode.Scalar(UInt8(codepoint)))
        default:
            let (prefix, width): (String, Int) = codepoint <= 0xFF ? ("\\x", 2) : codepoint <= 0xFFFF ? ("\\u", 4) : ("\\U", 8)
            let hex = String(UInt32(bitPattern: codepoint), radix: 16)
            output += prefix
            if hex.count < width { output += String(repeating: "0", count: width - hex.count) }
            output += hex
        }
    }

    /// Escapes a raw byte string. Valid UTF-8 is escaped per code point; stray bytes are
    /// escaped individually as `\xHH`.
    static func escape(bytes: UnsafeBufferPointer<UInt8>, into output: inout String) {
        var index = 0
        while index < bytes.count {
            let (codepoint, length) = UTF8Codec.decode(bytes, at: index)
            if codepoint == UTF8Codec.invalid {
                escape(Codepoint(bytes[index]), into: &output)
                index += 1
            } else {
                escape(codepoint, into: &output)
                index += length
            }
        }
    }

    static func escaped(bytes: [UInt8]) -> String {
        var output = ""
        output.reserveCapacity(bytes.count + 2)
        bytes.withUnsafeBufferPointer { escape(bytes: $0, into: &output) }
        return output
    }

    static func escaped(_ string: String) -> String {
        var copy = string
        return copy.withUTF8 { buffer in
            var output = ""
            output.reserveCapacity(buffer.count + 2)
            escape(bytes: buffer, into: &output)
            return output
        }
    }
}
