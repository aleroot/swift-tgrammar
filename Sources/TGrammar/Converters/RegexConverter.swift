// Converts a regular expression (ECMAScript dialect, as described on MDN) into the EBNF
// dialect, so that `Grammar(regex:)` reuses the whole EBNF pipeline. Unsupported constructs
// (backreferences, lookaround, Unicode property escapes, word boundaries) are reported with
// upstream-compatible messages.

struct RegexConverter {
    private let codepoints: [Codepoint]
    private var current = 0
    private var result = ""
    private var parenthesisLevel = 0

    /// Converts `regex` to an EBNF body; with `withRuleName` it is wrapped as `root ::= … \n`.
    static func ebnf(from regex: String, withRuleName: Bool = true) throws(GrammarError) -> String {
        var converter = try RegexConverter(regex)
        let body = try converter.convert()
        return withRuleName ? "root ::= \(body)\n" : body
    }

    private init(_ regex: String) throws(GrammarError) {
        // `withUTF8` makes a bridged string native once instead of walking it through
        // Objective-C per byte.
        var copy = regex
        let (hasNull, decoded) = copy.withUTF8 { bytes in
            (bytes.contains(0), UTF8Codec.decodeAll(bytes, preservingInvalidBytes: false))
        }
        if hasNull { throw .conversion("The regex must not contain null characters.") }
        if decoded.first == UTF8Codec.invalid { throw .conversion("The regex is not a valid UTF-8 string.") }
        codepoints = decoded
    }

    private var end: Int { codepoints.count }
    private var atEnd: Bool { current >= end }

    @inline(__always)
    private func peek(_ offset: Int = 0) -> Codepoint {
        let index = current + offset
        return index < end ? codepoints[index] : 0
    }

    @inline(__always)
    private func isAt(_ scalar: Unicode.Scalar) -> Bool { !atEnd && peek() == Codepoint(scalar.value) }

    private func error(_ message: String) -> GrammarError {
        .conversion("Regex parsing error at position \(current + 1): \(message)")
    }

    private mutating func addSegment(_ element: String) {
        if !result.isEmpty { result += " " }
        result += element
    }

    private static func escaped(_ codepoint: Codepoint) -> String {
        var output = ""
        EscapeCodec.escape(codepoint, into: &output)
        return output
    }

    @inline(__always)
    private static func isDigit(_ codepoint: Codepoint) -> Bool { codepoint >= 0x30 && codepoint <= 0x39 }

    @inline(__always)
    private static func isAlpha(_ codepoint: Codepoint) -> Bool {
        (codepoint >= 0x41 && codepoint <= 0x5A) || (codepoint >= 0x61 && codepoint <= 0x7A)
    }

    // MARK: Pieces

    private mutating func handleCharacterClass() throws(GrammarError) -> String {
        var charClass = "["
        current += 1
        if isAt("]") { throw error("Empty character class is not allowed in regex.") }
        while !atEnd, !isAt("]") {
            if isAt("\\") {
                charClass += try handleEscapeInCharClass()
            } else {
                if let scalar = Unicode.Scalar(UInt32(bitPattern: peek())) {
                    charClass.unicodeScalars.append(scalar)
                } else {
                    charClass += String(decoding: UTF8Codec.encode(peek()), as: UTF8.self)
                }
                current += 1
            }
        }
        if atEnd { throw error("Unclosed '['") }
        charClass += "]"
        current += 1
        return charClass
    }

    /// `{x}`, `{x,}`, `{x,y}`.
    private mutating func handleRepetitionRange() throws(GrammarError) -> String {
        var text = "{"
        current += 1
        guard Self.isDigit(peek()) else { throw error("Invalid repetition count.") }
        while Self.isDigit(peek()) {
            text.unicodeScalars.append(Unicode.Scalar(UInt8(peek())))
            current += 1
        }
        guard isAt(",") || isAt("}") else { throw error("Invalid repetition count.") }
        text.unicodeScalars.append(Unicode.Scalar(UInt8(peek())))
        current += 1
        if codepoints[current - 1] == Codepoint(UInt8(ascii: "}")) { return text }
        guard Self.isDigit(peek()) || isAt("}") else { throw error("Invalid repetition count.") }
        while Self.isDigit(peek()) {
            text.unicodeScalars.append(Unicode.Scalar(UInt8(peek())))
            current += 1
        }
        guard isAt("}") else { throw error("Invalid repetition count.") }
        text += "}"
        current += 1
        return text
    }

    private static let customEscapes: Set<UInt8> = Set("^$.*+?\\()[]{}|/".utf8)

    /// A single escaped character (`\n`, `\x41`, `\u{1F600}`, `\cA`, `\.`, …), rendered as an
    /// EBNF escape. Mirrors upstream `ParseNextEscaped` + the regex-only `\u{…}` and `\c` forms.
    private mutating func handleCharEscape(allowDash: Bool) throws(GrammarError) -> String {
        let remaining = end - current
        let next = peek(1)
        if remaining < 2 || (next == 0x75 && remaining < 5) || (next == 0x78 && remaining < 4) || (next == 0x63 && remaining < 3) {
            throw error("Escape sequence is not finished.")
        }
        @inline(__always) func hex(_ offset: Int) -> Int32 {
            let value = peek(offset)
            return value < 0x80 ? EscapeCodec.hexValue(UInt8(value)) : -1
        }
        if next <= 0x80 {
            let letter = UInt8(truncatingIfNeeded: next)
            if Self.customEscapes.contains(letter) || (allowDash && letter == UInt8(ascii: "-")) {
                current += 2
                return Self.escaped(Codepoint(letter))
            }
            if let codepoint = EscapeCodec.simpleEscape(letter) {
                current += 2
                return Self.escaped(codepoint)
            }
            if letter == UInt8(ascii: "x") {
                // Arbitrary-length hex.
                var length = 0
                var value: Codepoint = 0
                while hex(2 + length) != -1 {
                    value = value &* 16 &+ hex(2 + length)
                    length += 1
                }
                if length > 0 {
                    current += length + 2
                    return Self.escaped(value)
                }
            } else if letter == UInt8(ascii: "u") || letter == UInt8(ascii: "U") {
                let digits = letter == UInt8(ascii: "u") ? 4 : 8
                var value: Codepoint = 0
                var valid = true
                for offset in 0 ..< digits {
                    let digit = hex(2 + offset)
                    if digit == -1 {
                        valid = false
                        break
                    }
                    value = value &* 16 &+ digit
                }
                if valid {
                    current += digits + 2
                    return Self.escaped(value)
                }
            }
        }
        if next == 0x75, peek(2) == Codepoint(UInt8(ascii: "{")) {
            current += 3
            var length = 0
            var value: Codepoint = 0
            while hex(length) != -1, length <= 6 {
                value = value &* 16 &+ hex(length)
                length += 1
            }
            if length == 0 || length > 6 || peek(length) != Codepoint(UInt8(ascii: "}")) {
                throw error("Invalid Unicode escape sequence.")
            }
            current += length + 1
            return Self.escaped(value)
        }
        if next == 0x63 {
            current += 2
            guard Self.isAlpha(peek()) else { throw error("Invalid control character escape sequence.") }
            current += 1
            return Self.escaped(codepoints[current - 1] % 32)
        }
        // Unrecognized escape: the character itself is matched.
        current += 2
        return Self.escaped(codepoints[current - 1])
    }

    /// The class body matched by `\s`: ECMAScript WhiteSpace (TAB, VT, FF, ZWNBSP and every
    /// Space_Separator code point) plus LineTerminator (LF, CR, LS, PS). Unlike `\d` and `\w`, it
    /// is not ASCII-only.
    static let whitespaceClassBody = #"\f\n\r\t\v\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff"#
    /// The complement of ``whitespaceClassBody`` over every code point, for `\S` inside a class.
    static let nonWhitespaceClassBody = #"\x00-\x08\x0E-\x1F\x21-\x9F\xA1-\u167f\u1681-\u1fff\u200b-\u2027\u202a-\u202e"#
        + #"\u2030-\u205e\u2060-\u2fff\u3001-\ufefe\uff00-\U0010FFFF"#

    private mutating func handleEscapeInCharClass() throws(GrammarError) -> String {
        guard end - current >= 2 else { throw error("Escape sequence is not finished.") }
        switch peek(1) {
        case 0x64: current += 2; return "0-9"  // \d
        case 0x44: current += 2; return #"\x00-\x2F\x3A-\U0010FFFF"#  // \D
        case 0x77: current += 2; return "a-zA-Z0-9_"  // \w
        case 0x57: current += 2; return #"\x00-\x2F\x3A-\x40\x5B-\x5E\x60\x7B-\U0010FFFF"#  // \W
        case 0x73: current += 2; return Self.whitespaceClassBody  // \s
        case 0x53: current += 2; return Self.nonWhitespaceClassBody  // \S
        default:
            let text = try handleCharEscape(allowDash: true)
            return text == "]" || text == "-" ? "\\" + text : text
        }
    }

    private mutating func handleEscape() throws(GrammarError) -> String {
        guard end - current >= 2 else { throw error("Escape sequence is not finished.") }
        switch peek(1) {
        case 0x64: current += 2; return "[0-9]"
        case 0x44: current += 2; return "[^0-9]"
        case 0x77: current += 2; return "[a-zA-Z0-9_]"
        case 0x57: current += 2; return "[^a-zA-Z0-9_]"
        case 0x73: current += 2; return "[" + Self.whitespaceClassBody + "]"
        case 0x53: current += 2; return "[^" + Self.whitespaceClassBody + "]"
        case 0x31 ... 0x39, 0x6B: throw error("Backreference is not supported yet.")
        case 0x70, 0x50: throw error("Unicode character class escape sequence is not supported yet.")
        case 0x62, 0x42: throw error("Word boundary is not supported yet.")
        default: return "\"" + (try handleCharEscape(allowDash: false)) + "\""
        }
    }

    /// `(?` + modifier: non-capturing and named groups are accepted, lookaround and flags are not.
    private mutating func handleGroupModifier() throws(GrammarError) {
        if atEnd { throw error("Group modifier is not finished.") }
        if isAt(":") {
            current += 1
        } else if isAt("=") || isAt("!") {
            throw error("Lookahead is not supported yet.")
        } else if isAt("<"), current + 1 < end, peek(1) == 0x3D || peek(1) == 0x21 {
            throw error("Lookbehind is not supported yet.")
        } else if isAt("<") {
            current += 1
            while !atEnd, Self.isAlpha(peek()) { current += 1 }
            guard !atEnd, isAt(">") else { throw error("Invalid named capturing group.") }
            current += 1
        } else {
            throw error("Group modifier flag is not supported yet.")
        }
    }

    // MARK: Driver

    private mutating func convert() throws(GrammarError) -> String {
        var isEmpty = true
        while !atEnd {
            if isAt("^") || isAt("$") {
                // Anchors are implied: the grammar always matches the whole output.
                current += 1
            } else if isAt("[") {
                isEmpty = false
                addSegment(try handleCharacterClass())
            } else if isAt("(") {
                isEmpty = false
                current += 1
                parenthesisLevel += 1
                addSegment("(")
                if !atEnd, isAt("?") {
                    current += 1
                    try handleGroupModifier()
                }
            } else if isAt(")") {
                isEmpty = false
                guard parenthesisLevel > 0 else { throw error("Unmatched ')'") }
                // An empty alternative before `)` (e.g. "(a|)") needs an explicit "".
                if result.utf8.last == UInt8(ascii: "|") { addSegment("\"\"") }
                parenthesisLevel -= 1
                addSegment(")")
                current += 1
            } else if isAt("*") || isAt("+") || isAt("?") {
                isEmpty = false
                result.unicodeScalars.append(Unicode.Scalar(UInt8(peek())))
                current += 1
                // Non-greedy modifiers are ignored: repetitions are explored non-deterministically.
                if !atEnd, isAt("?") { current += 1 }
                if !atEnd, isAt("{") || isAt("*") || isAt("+") || isAt("?") {
                    throw error("Two consecutive repetition modifiers are not allowed.")
                }
            } else if isAt("{") {
                isEmpty = false
                result += try handleRepetitionRange()
                if !atEnd, isAt("?") { current += 1 }
                if !atEnd, isAt("{") || isAt("*") || isAt("+") || isAt("?") {
                    throw error("Two consecutive repetition modifiers are not allowed.")
                }
            } else if isAt("|") {
                isEmpty = false
                // An empty alternative before `|` needs an explicit "".
                if result.isEmpty || result.utf8.last == UInt8(ascii: "|") || result.utf8.last == UInt8(ascii: "(") { addSegment("\"\"") }
                addSegment("|")
                current += 1
            } else if isAt("\\") {
                isEmpty = false
                addSegment(try handleEscape())
            } else if isAt(".") {
                isEmpty = false
                addSegment(#"[\u0000-\U0010FFFF]"#)
                current += 1
            } else {
                isEmpty = false
                addSegment("\"" + Self.escaped(peek()) + "\"")
                current += 1
            }
        }
        if parenthesisLevel != 0 { throw error("The parenthesis is not closed.") }
        if result.utf8.last == UInt8(ascii: "|") { addSegment("\"\"") }
        if isEmpty { addSegment("\"\"") }
        return result
    }
}

extension Grammar {
    /// Builds a grammar accepting exactly the strings matched by `regex` (ECMAScript dialect;
    /// anchors are implied, backreferences and lookaround are not supported).
    public convenience init(regex: String) throws(GrammarError) {
        try self.init(ebnf: try RegexConverter.ebnf(from: regex))
    }

    /// The EBNF produced for `regex` (what ``init(regex:)`` parses).
    public static func ebnf(fromRegex regex: String) throws(GrammarError) -> String {
        try RegexConverter.ebnf(from: regex)
    }
}

extension GrammarCompiler {
    /// Compiles a grammar accepting exactly the strings matched by `regex`.
    public func compile(regex: String) throws(GrammarError) -> CompiledGrammar {
        try compile(Grammar(regex: regex))
    }
}
