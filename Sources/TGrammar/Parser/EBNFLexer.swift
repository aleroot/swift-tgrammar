// Tokenizer for the EBNF dialect. Operates on raw UTF-8 bytes and tracks line/column for error
// reporting. Character classes are emitted as token runs (`[`, optional `^`, chars/dashes, `]`)
// so that the parser decides how dashes pair up into ranges.

/// Per-rule options written as `name[max_tokens=.., capture, lazy, ...] ::= ...`.
struct RuleAttributes: Equatable {
    var maxTokens: Int32 = -1
    var maxChars: Int32 = -1
    var captureName = ""
    var hiddenSuffixBytes: Int32 = 0
    var hiddenStopBytes: Int32 = 0
    var hiddenBodyRuleID: Int32 = -1
    var hiddenMarkerRuleID: Int32 = -1
    var stopCaptureName = ""
    var isLazy = false
    var temperature: Float?

    var suffixStopInfo: SuffixStopInfo {
        var info = SuffixStopInfo()
        info.hiddenSuffixBytes = hiddenSuffixBytes
        info.hiddenStopBytes = hiddenStopBytes
        info.bodyRuleID = hiddenBodyRuleID
        info.markerRuleID = hiddenMarkerRuleID
        info.stopCaptureName = stopCaptureName
        return info
    }
}

struct EBNFToken {
    enum Kind {
        case ruleName, identifier, stringLiteral, integerLiteral, booleanLiteral
        case lParen, rParen, lookaheadLParen, lBrace, rBrace, lBracket, rBracket
        case caret, dash, charInCharClass, escapeInCharClass
        case pipe, comma, star, plus, question, equal, assign
        case endOfFile
    }

    enum Value {
        case none
        case string([UInt8])
        case integer(Int64)
        case boolean(Bool)
        case codepoint(Codepoint)
        case identifier(String)
    }

    var kind: Kind
    /// The source text of the token, for diagnostics.
    var lexeme: String
    var value: Value
    var line: Int
    var column: Int
    var attributes: RuleAttributes?

    var identifier: String {
        if case let .identifier(name) = value { return name }
        return ""
    }
}

struct EBNFLexer {
    private let bytes: [UInt8]
    private var cursor = 0
    private var line = 1
    private var column = 1

    static let maxIntegerInGrammar: Int64 = 1_000_000_000_000_000

    private init(bytes: [UInt8]) { self.bytes = bytes }

    static func tokenize(_ input: String) throws(GrammarError) -> [EBNFToken] {
        var lexer = EBNFLexer(bytes: Array(input.utf8))
        return try lexer.tokenizeAll()
    }

    // MARK: Cursor

    @inline(__always)
    private func peek(_ delta: Int = 0) -> UInt8 {
        let index = cursor &+ delta
        return index >= 0 && index < bytes.count ? bytes[index] : 0
    }

    private mutating func consume(_ count: Int = 1) {
        for _ in 0 ..< count {
            let byte = peek()
            if byte == UInt8(ascii: "\n") || (byte == UInt8(ascii: "\r") && peek(1) != UInt8(ascii: "\n")) {
                line += 1
                column = 1
            } else {
                column += 1
            }
            cursor += 1
        }
    }

    private mutating func skipSpaceAndComments() {
        while true {
            switch peek() {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                consume()
            case UInt8(ascii: "#"):
                while cursor < bytes.count, peek() != UInt8(ascii: "\n"), peek() != UInt8(ascii: "\r") { consume() }
                if cursor >= bytes.count { return }
                consume()
                if peek(-1) == UInt8(ascii: "\r"), peek() == UInt8(ascii: "\n") { consume() }
            default:
                return
            }
        }
    }

    private func error(_ message: String, line: Int? = nil, column: Int? = nil) -> GrammarError {
        .lexer(message: message, line: line ?? self.line, column: column ?? self.column)
    }

    @inline(__always)
    private static func isNameByte(_ byte: UInt8, first: Bool) -> Bool {
        switch byte {
        case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."),
            UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"):
            true
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            !first
        default:
            false
        }
    }

    @inline(__always)
    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private func lexeme(from start: Int) -> String {
        String(decoding: bytes[start ..< cursor], as: UTF8.self)
    }

    // MARK: Tokens

    private mutating func tokenizeAll() throws(GrammarError) -> [EBNFToken] {
        var tokens: [EBNFToken] = []
        while true {
            try nextToken(into: &tokens)
            if tokens.last?.kind == .endOfFile { break }
        }
        try markRuleNames(&tokens)
        return tokens
    }

    private mutating func nextToken(into tokens: inout [EBNFToken]) throws(GrammarError) {
        skipSpaceAndComments()
        let startLine = line
        let startColumn = column
        func simple(_ kind: EBNFToken.Kind, _ text: String) -> EBNFToken {
            EBNFToken(kind: kind, lexeme: text, value: .none, line: startLine, column: startColumn)
        }
        guard cursor < bytes.count else {
            tokens.append(simple(.endOfFile, ""))
            return
        }
        let byte = peek()
        switch byte {
        case UInt8(ascii: "("):
            if peek(1) == UInt8(ascii: "=") {
                consume(2)
                tokens.append(simple(.lookaheadLParen, "(="))
            } else {
                consume()
                tokens.append(simple(.lParen, "("))
            }
        case UInt8(ascii: ")"): consume(); tokens.append(simple(.rParen, ")"))
        case UInt8(ascii: "{"): consume(); tokens.append(simple(.lBrace, "{"))
        case UInt8(ascii: "}"): consume(); tokens.append(simple(.rBrace, "}"))
        case UInt8(ascii: "|"): consume(); tokens.append(simple(.pipe, "|"))
        case UInt8(ascii: ","): consume(); tokens.append(simple(.comma, ","))
        case UInt8(ascii: "*"): consume(); tokens.append(simple(.star, "*"))
        case UInt8(ascii: "+"): consume(); tokens.append(simple(.plus, "+"))
        case UInt8(ascii: "?"): consume(); tokens.append(simple(.question, "?"))
        case UInt8(ascii: "="): consume(); tokens.append(simple(.equal, "="))
        case UInt8(ascii: ":"):
            guard peek(1) == UInt8(ascii: ":"), peek(2) == UInt8(ascii: "=") else {
                throw error("Unexpected character: ':'")
            }
            consume(3)
            tokens.append(simple(.assign, "::="))
        case UInt8(ascii: "\""):
            tokens.append(try stringToken())
        case UInt8(ascii: "["):
            try characterClassTokens(into: &tokens)
        default:
            if Self.isNameByte(byte, first: true) {
                tokens.append(try identifierOrBooleanToken())
            } else if Self.isDigit(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") {
                tokens.append(try integerToken())
            } else {
                throw error("Unexpected character: \(String(decoding: [byte], as: UTF8.self))")
            }
        }
    }

    private mutating func identifierText() throws(GrammarError) -> String {
        let start = cursor
        var first = true
        while cursor < bytes.count, Self.isNameByte(peek(), first: first) {
            consume()
            first = false
        }
        if start == cursor { throw error("Expect identifier") }
        return lexeme(from: start)
    }

    private mutating func identifierOrBooleanToken() throws(GrammarError) -> EBNFToken {
        let startLine = line
        let startColumn = column
        let identifier = try identifierText()
        if identifier == "true" || identifier == "false" {
            return EBNFToken(kind: .booleanLiteral, lexeme: identifier, value: .boolean(identifier == "true"), line: startLine, column: startColumn)
        }
        var token = EBNFToken(kind: .identifier, lexeme: identifier, value: .identifier(identifier), line: startLine, column: startColumn)
        if peek() == UInt8(ascii: "["), let (attributes, length) = try attributeBlock(identifier: identifier, line: startLine, column: startColumn) {
            consume(length)
            token.attributes = attributes
        }
        return token
    }

    /// Scans `[attr, attr=value, ...]` followed by `::=` without consuming. Returns `nil` when the
    /// bracket is not an attribute block (it is then lexed as a character class).
    private func attributeBlock(identifier: String, line startLine: Int, column startColumn: Int) throws(GrammarError) -> (RuleAttributes, Int)? {
        var delta = 1
        func skipSpace() {
            while peek(delta) == UInt8(ascii: " ") || peek(delta) == UInt8(ascii: "\t") { delta += 1 }
        }
        func matchKeyword(_ keyword: StaticString) -> Bool {
            let matched = keyword.withUTF8Buffer { buffer -> Bool in
                for (offset, expected) in buffer.enumerated() where peek(delta &+ offset) != expected { return false }
                return true
            }
            if matched { delta += keyword.utf8CodeUnitCount }
            return matched
        }
        func integerValue() -> Int64? {
            skipSpace()
            guard peek(delta) == UInt8(ascii: "=") else { return nil }
            delta += 1
            skipSpace()
            var value: Int64 = 0
            var digits = 0
            while Self.isDigit(peek(delta)), digits < 10 {
                value = value &* 10 &+ Int64(peek(delta) &- UInt8(ascii: "0"))
                delta += 1
                digits += 1
            }
            return digits > 0 && !Self.isDigit(peek(delta)) ? value : nil
        }
        func stringValue() -> String? {
            skipSpace()
            guard peek(delta) == UInt8(ascii: "=") else { return nil }
            delta += 1
            skipSpace()
            guard peek(delta) == UInt8(ascii: "\"") else { return nil }
            delta += 1
            var value: [UInt8] = []
            while peek(delta) != UInt8(ascii: "\"") {
                let byte = peek(delta)
                if byte == 0 || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\\") { return nil }
                value.append(byte)
                delta += 1
            }
            delta += 1
            return String(decoding: value, as: UTF8.self)
        }
        func floatValue() -> Double? {
            skipSpace()
            guard peek(delta) == UInt8(ascii: "=") else { return nil }
            delta += 1
            skipSpace()
            var text: [UInt8] = []
            while true {
                let byte = peek(delta)
                if Self.isDigit(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
                    || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")
                {
                    text.append(byte)
                    delta += 1
                } else {
                    break
                }
            }
            if text.isEmpty { return nil }
            return Double(String(decoding: text, as: UTF8.self))
        }

        var attributes = RuleAttributes()
        var seen = Set<String>()
        var matched = true
        var sawCapture = false
        var sawStopCapture = false
        var sawHiddenSuffix = false
        var sawHiddenStop = false
        var sawHiddenBody = false
        var sawHiddenMarker = false
        var sawMaxChars = false
        var sawTemperature = false
        var temperature = 0.0

        while matched {
            skipSpace()
            if !seen.contains("max_tokens"), matchKeyword("max_tokens") {
                seen.insert("max_tokens")
                if let value = integerValue() { attributes.maxTokens = Int32(truncatingIfNeeded: value) } else { matched = false }
            } else if !seen.contains("max_chars"), matchKeyword("max_chars") {
                seen.insert("max_chars")
                sawMaxChars = true
                if let value = integerValue() {
                    attributes.maxChars = value > Int64(Int32.max) ? Int32.max : Int32(value)
                    if value > Int64(Int32.max) { throw error("The rule attribute value is too large", line: startLine, column: startColumn) }
                } else { matched = false }
            } else if !seen.contains("capture_hidden_suffix_bytes"), matchKeyword("capture_hidden_suffix_bytes") {
                seen.insert("capture_hidden_suffix_bytes")
                sawHiddenSuffix = true
                if let value = integerValue() {
                    if value > Int64(Int32.max) { throw error("The rule attribute value is too large", line: startLine, column: startColumn) }
                    attributes.hiddenSuffixBytes = Int32(value)
                } else { matched = false }
            } else if !seen.contains("capture_hidden_stop_bytes"), matchKeyword("capture_hidden_stop_bytes") {
                seen.insert("capture_hidden_stop_bytes")
                sawHiddenStop = true
                if let value = integerValue() {
                    if value > Int64(Int32.max) { throw error("The rule attribute value is too large", line: startLine, column: startColumn) }
                    attributes.hiddenStopBytes = Int32(value)
                } else { matched = false }
            } else if !seen.contains("capture_hidden_body_rule_id"), matchKeyword("capture_hidden_body_rule_id") {
                seen.insert("capture_hidden_body_rule_id")
                sawHiddenBody = true
                if let value = integerValue() {
                    if value > Int64(Int32.max) { throw error("The rule attribute value is too large", line: startLine, column: startColumn) }
                    attributes.hiddenBodyRuleID = Int32(value)
                } else { matched = false }
            } else if !seen.contains("capture_hidden_marker_rule_id"), matchKeyword("capture_hidden_marker_rule_id") {
                seen.insert("capture_hidden_marker_rule_id")
                sawHiddenMarker = true
                if let value = integerValue() {
                    if value > Int64(Int32.max) { throw error("The rule attribute value is too large", line: startLine, column: startColumn) }
                    attributes.hiddenMarkerRuleID = Int32(value)
                } else { matched = false }
            } else if !seen.contains("stop_capture"), matchKeyword("stop_capture") {
                seen.insert("stop_capture")
                sawStopCapture = true
                if let value = stringValue() { attributes.stopCaptureName = value } else { matched = false }
            } else if !seen.contains("capture"), matchKeyword("capture") {
                seen.insert("capture")
                sawCapture = true
                skipSpace()
                if peek(delta) == UInt8(ascii: "=") {
                    if let value = stringValue() { attributes.captureName = value } else { matched = false }
                } else {
                    attributes.captureName = identifier
                }
            } else if !seen.contains("lazy"), matchKeyword("lazy") {
                seen.insert("lazy")
                attributes.isLazy = true
            } else if !seen.contains("temperature"), matchKeyword("temperature") {
                seen.insert("temperature")
                sawTemperature = true
                if let value = floatValue() { temperature = value } else { matched = false }
            } else {
                matched = false
            }
            if !matched { break }
            skipSpace()
            if peek(delta) == UInt8(ascii: ",") {
                delta += 1
                continue
            }
            break
        }
        if matched {
            skipSpace()
            if peek(delta) == UInt8(ascii: "]") { delta += 1 } else { matched = false }
        }
        if matched {
            var after = delta
            while peek(after) == UInt8(ascii: " ") || peek(after) == UInt8(ascii: "\t") { after += 1 }
            if !(peek(after) == UInt8(ascii: ":") && peek(after &+ 1) == UInt8(ascii: ":") && peek(after &+ 2) == UInt8(ascii: "=")) {
                matched = false
            }
        }
        guard matched else { return nil }

        if sawCapture, attributes.captureName.isEmpty {
            throw error("The capture name must not be empty", line: startLine, column: startColumn)
        }
        if sawStopCapture, attributes.stopCaptureName.isEmpty {
            throw error("The stop capture name must not be empty", line: startLine, column: startColumn)
        }
        if sawHiddenBody != sawHiddenMarker {
            throw error("The capture-hidden body and marker rule ids must be specified together", line: startLine, column: startColumn)
        }
        if (sawHiddenSuffix && attributes.hiddenSuffixBytes <= 0) || (sawHiddenStop && attributes.hiddenStopBytes <= 0) {
            throw error("The number of capture-hidden bytes must be positive", line: startLine, column: startColumn)
        }
        if sawMaxChars, attributes.maxChars < 0 {
            throw error("The max_chars rule attribute must be non-negative", line: startLine, column: startColumn)
        }
        if sawTemperature {
            guard temperature.isFinite, temperature >= 0, temperature <= Double(Float.greatestFiniteMagnitude) else {
                throw error("The temperature must be a finite non-negative number", line: startLine, column: startColumn)
            }
            attributes.temperature = Float(temperature)
        }
        return (attributes, delta)
    }

    private mutating func stringToken() throws(GrammarError) -> EBNFToken {
        let startLine = line
        let startColumn = column
        let start = cursor
        consume()
        var value: [UInt8] = []
        while cursor < bytes.count, peek() != UInt8(ascii: "\""), peek() != UInt8(ascii: "\n"), peek() != UInt8(ascii: "\r") {
            let (codepoint, length) = bytes.withUnsafeBufferPointer { EscapeCodec.parseScalarOrEscape($0, at: cursor) }
            if codepoint == UTF8Codec.invalid { throw error("Invalid UTF8 sequence") }
            if codepoint == EscapeCodec.invalidEscape { throw error("Invalid escape sequence") }
            consume(length)
            UTF8Codec.encode(codepoint, into: &value)
        }
        guard peek() == UInt8(ascii: "\"") else { throw error("Expect \" in string literal") }
        consume()
        return EBNFToken(kind: .stringLiteral, lexeme: lexeme(from: start), value: .string(value), line: startLine, column: startColumn)
    }

    /// Escapes that are only meaningful inside a character class (regex metacharacters).
    private static func characterClassEscape(_ letter: UInt8) -> Codepoint? {
        switch letter {
        case UInt8(ascii: "^"), UInt8(ascii: "$"), UInt8(ascii: "\\"), UInt8(ascii: "."), UInt8(ascii: "*"),
            UInt8(ascii: "+"), UInt8(ascii: "?"), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "["),
            UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "|"), UInt8(ascii: "/"),
            UInt8(ascii: "-"):
            Codepoint(letter)
        default:
            nil
        }
    }

    private static func isShorthandClassLetter(_ letter: UInt8) -> Bool {
        switch letter {
        case UInt8(ascii: "d"), UInt8(ascii: "D"), UInt8(ascii: "s"), UInt8(ascii: "S"), UInt8(ascii: "w"), UInt8(ascii: "W"): true
        default: false
        }
    }

    private mutating func characterClassTokens(into tokens: inout [EBNFToken]) throws(GrammarError) {
        tokens.append(EBNFToken(kind: .lBracket, lexeme: "[", value: .none, line: line, column: column))
        consume()
        if peek() == UInt8(ascii: "^") {
            tokens.append(EBNFToken(kind: .caret, lexeme: "^", value: .none, line: line, column: column))
            consume()
        }
        while cursor < bytes.count, peek() != UInt8(ascii: "]") {
            let byte = peek()
            if byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n") {
                throw error("Character class should not contain newline")
            }
            if byte == UInt8(ascii: "-") {
                tokens.append(EBNFToken(kind: .dash, lexeme: "-", value: .none, line: line, column: column))
                consume()
                continue
            }
            if byte == UInt8(ascii: "\\"), Self.isShorthandClassLetter(peek(1)) {
                let start = cursor
                let tokenLine = line
                let tokenColumn = column
                consume(2)
                let text = lexeme(from: start)
                tokens.append(EBNFToken(kind: .escapeInCharClass, lexeme: text, value: .identifier(String(text.dropFirst())), line: tokenLine, column: tokenColumn))
                continue
            }
            let (codepoint, length) = bytes.withUnsafeBufferPointer {
                EscapeCodec.parseScalarOrEscape($0, at: cursor, additional: Self.characterClassEscape)
            }
            if codepoint == UTF8Codec.invalid { throw error("Invalid UTF8 sequence") }
            if codepoint == EscapeCodec.invalidEscape {
                let end = min(cursor &+ 2, bytes.count)
                throw error("Invalid escape sequence" + String(decoding: bytes[cursor ..< end], as: UTF8.self))
            }
            let start = cursor
            let tokenLine = line
            let tokenColumn = column
            consume(length)
            tokens.append(EBNFToken(kind: .charInCharClass, lexeme: lexeme(from: start), value: .codepoint(codepoint), line: tokenLine, column: tokenColumn))
        }
        guard cursor < bytes.count else { throw error("Unterminated character class") }
        tokens.append(EBNFToken(kind: .rBracket, lexeme: "]", value: .none, line: line, column: column))
        consume()
    }

    private mutating func integerToken() throws(GrammarError) -> EBNFToken {
        let startLine = line
        let startColumn = column
        let start = cursor
        var negative = false
        if peek() == UInt8(ascii: "-") {
            negative = true
            consume()
        } else if peek() == UInt8(ascii: "+") {
            consume()
        }
        var value: Int64 = 0
        while cursor < bytes.count, Self.isDigit(peek()) {
            value = value &* 10 &+ Int64(peek() &- UInt8(ascii: "0"))
            consume()
            if value > Self.maxIntegerInGrammar {
                throw error("Integer is too large: parsed \(value), max allowed is \(Self.maxIntegerInGrammar)")
            }
        }
        return EBNFToken(kind: .integerLiteral, lexeme: lexeme(from: start), value: .integer(negative ? -value : value), line: startLine, column: startColumn)
    }

    /// Promotes the identifier preceding each `::=` to a rule name and validates its placement.
    private func markRuleNames(_ tokens: inout [EBNFToken]) throws(GrammarError) {
        for index in tokens.indices where tokens[index].kind == .assign {
            if index == 0 {
                throw error("Assign should not be the first token", line: tokens[index].line, column: tokens[index].column)
            }
            let previous = tokens[index - 1]
            if previous.kind != .identifier {
                throw error("Assign should be preceded by an identifier", line: previous.line, column: previous.column)
            }
            if index >= 2, tokens[index - 2].line == previous.line {
                throw error("The rule name should be at the beginning of the line", line: previous.line, column: previous.column)
            }
            tokens[index - 1].kind = .ruleName
        }
    }
}
