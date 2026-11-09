struct LarkToken {
    enum Kind { case name, string, regex, number, symbol, newline, special, reference, directive, embedded, eof }
    var kind: Kind
    var text: String
    var flags = ""
    var line: Int
    var column: Int
    var location: LarkLocation { .init(line: line, column: column) }
    func error(_ message: String) -> GrammarError { .lark(message: message, line: line, column: column) }
}

/// A source position carried by AST nodes so conversion errors point at the offending construct.
struct LarkLocation: Sendable {
    var line: Int
    var column: Int
    static let start = LarkLocation(line: 1, column: 1)
    func error(_ message: String) -> GrammarError { .lark(message: message, line: line, column: column) }
}

/// A byte lexer for Lark source. Embedded JSON/Lark bodies are retained as source slices rather
/// than lexed as the enclosing language. Nothing from the lexer enters token generation.
struct LarkLexer {
    private let bytes: [UInt8]
    private var cursor = 0
    private var line = 1
    private var column = 1
    private init(_ source: String) { bytes = Array(source.utf8) }
    private var atEnd: Bool { cursor >= bytes.count }
    private func peek(_ delta: Int = 0) -> UInt8 { cursor + delta < bytes.count ? bytes[cursor + delta] : 0 }
    private mutating func advance() {
        if peek() == 10 { line += 1; column = 1 } else { column += 1 }
        cursor += 1
    }
    private func text(_ start: Int) -> String { String(decoding: bytes[start ..< cursor], as: UTF8.self) }
    private static func letter(_ byte: UInt8) -> Bool { (65 ... 90).contains(byte) || (97 ... 122).contains(byte) || byte == 95 }
    private static func digit(_ byte: UInt8) -> Bool { (48 ... 57).contains(byte) }
    private mutating func flags() -> String {
        let start = cursor
        while Self.letter(peek()) { advance() }
        return text(start)
    }

    static func tokenize(_ source: String) throws(GrammarError) -> [LarkToken] {
        var lexer = Self(source)
        var tokens: [LarkToken] = []
        while !lexer.atEnd { if let token = try lexer.next() { tokens.append(token) } }
        tokens.append(.init(kind: .eof, text: "", line: lexer.line, column: lexer.column))
        return tokens
    }
    private mutating func next() throws(GrammarError) -> LarkToken? {
        let start = cursor
        var token = LarkToken(kind: .symbol, text: "", line: line, column: column)
        switch peek() {
        case 32, 9, 13: advance(); return nil
        case 10: advance(); token.kind = .newline
        case 35:
            while !atEnd, peek() != 10 { advance() }; return nil
        case 47 where peek(1) == 47:
            while !atEnd, peek() != 10 { advance() }; return nil
        case 34:
            advance()
            while !atEnd, peek() != 34 {
                guard peek() != 10, peek() != 13 else { throw token.error("unterminated string literal") }
                if peek() == 92 { advance(); if atEnd { throw token.error("unterminated string literal") } }
                advance()
            }
            guard !atEnd else { throw token.error("unterminated string literal") }
            advance()
            let quoted = text(start)
            let decoded: String?
            do { decoded = try JSONValue.parse(quoted).string } catch { throw token.error("invalid string literal: \(error.message)") }
            guard let decoded else { throw token.error("invalid string literal: ") }
            token.kind = .string; token.text = decoded; token.flags = flags()
            return token
        case 47:
            advance(); let patternStart = cursor
            while !atEnd {
                if peek() == 92 { advance(); if !atEnd { advance() }; continue }
                if peek() == 47 { break }
                guard peek() != 10 else { throw token.error("unterminated regular expression") }
                advance()
            }
            guard !atEnd else { throw token.error("unterminated regular expression") }
            token.kind = .regex; token.text = text(patternStart)
            advance(); token.flags = flags(); return token
        case 60:
            advance()
            while !atEnd, peek() != 62 {
                guard ![32, 9, 10, 11, 12, 13, 60].contains(peek()) else { throw token.error("invalid special token") }
                advance()
            }
            guard !atEnd else { throw token.error("unterminated special token") }
            advance(); token.kind = .special
        case 64:
            advance(); let begin = cursor
            while Self.letter(peek()) || Self.digit(peek()) || peek() == 45 { advance() }
            guard cursor > begin else { throw token.error("empty grammar reference") }
            token.kind = .reference; token.text = text(begin); return token
        case 37:
            advance()
            while Self.letter(peek()) { advance() }
            token.kind = .directive; token.text = text(start)
            if ["%json", "%lark", "%grammar_options", "%regex"].contains(token.text) {
                let directive = token.text
                while !atEnd, [32, 9, 10, 13].contains(peek()) { advance() }
                let bodyStart = cursor
                if directive == "%lark" {
                    guard peek() == 123 else { throw token.error("expected '{' after %lark") }
                    try balanced(open: peek(), token: token)
                } else {
                    do {
                        if peek() == 123 || peek() == 91 {
                            try balanced(open: peek(), token: token)
                        } else if peek() == 34 {
                            advance()
                            while !atEnd, peek() != 34 { if peek() == 92 { advance() }; if !atEnd { advance() } }
                            if !atEnd { advance() }
                        } else {
                            while !atEnd, Self.letter(peek()) || Self.digit(peek()) || [43, 45, 46].contains(peek()) { advance() }
                        }
                        _ = try JSONValue.parse(text(bodyStart))
                    } catch {
                        throw token.error("failed to parse JSON value after \(directive): \(error.message)")
                    }
                }
                token.kind = .embedded; token.text = text(bodyStart); token.flags = directive
            }
            return token
        case 46 where peek(1) == 46: advance(); advance()
        case 58 where peek(1) == 58: advance(); advance()
        case 45 where peek(1) == 62: advance(); advance()
        case 45 where Self.digit(peek(1)), 43 where Self.digit(peek(1)):
            number(); token.kind = .number
        case 45: throw token.error("unexpected '-' character")
        case 33 where !Self.letter(peek(1)): throw token.error("unexpected '!' character")
        default:
            if Self.letter(peek()) {
                advance()
                while Self.letter(peek()) || Self.digit(peek()) || peek() == 45 { advance() }
                token.kind = .name
            } else if Self.digit(peek()) {
                number(); token.kind = .number
            } else if "():[]{}|?*+~,=.!&".utf8.contains(peek()) { advance() }
            else { throw token.error("unexpected character '\(String(decoding: [peek()], as: UTF8.self))'") }
        }
        token.text = text(start)
        return token
    }
    /// Upstream's number lexeme: optional sign, digits, an optional fraction (not `..`) and exponent.
    private mutating func number() {
        if peek() == 43 || peek() == 45 { advance() }
        while Self.digit(peek()) { advance() }
        if peek() == 46, peek(1) != 46 { advance(); while Self.digit(peek()) { advance() } }
        if peek() == 101 || peek() == 69 {
            advance()
            if peek() == 43 || peek() == 45 { advance() }
            while Self.digit(peek()) { advance() }
        }
    }
    private mutating func balanced(open: UInt8, token: LarkToken) throws(GrammarError) {
        var expected: [UInt8] = [open == 123 ? 125 : 93]
        advance()
        while !atEnd {
            switch peek() {
            case 34:
                advance()
                while !atEnd, peek() != 34 { if peek() == 92 { advance() }; if !atEnd { advance() } }
                guard !atEnd else { throw token.error("unterminated embedded string") }
            case 47 where token.text == "%lark" && peek(1) != 47:
                advance(); var inClass = false
                while !atEnd {
                    if peek() == 92 { advance(); if !atEnd { advance() }; continue }
                    if peek() == 91 { inClass = true }; if peek() == 93 { inClass = false }
                    if peek() == 47 && !inClass { break }; advance()
                }
                guard !atEnd else { throw token.error("unterminated embedded regex") }
            case 35 where token.text == "%lark": while !atEnd, peek() != 10 { advance() }; continue
            case 47 where token.text == "%lark" && peek(1) == 47: while !atEnd, peek() != 10 { advance() }; continue
            case 123, 91:
                guard expected.count < 512 else { throw token.error("embedded grammar nesting exceeds 512 levels") }
                expected.append(peek() == 123 ? 125 : 93)
            case 125, 93:
                guard peek() == expected.last else { throw token.error("unbalanced embedded grammar") }
                expected.removeLast()
                if expected.isEmpty { advance(); return }
            default: break
            }
            advance()
        }
        throw token.error("unterminated embedded grammar")
    }
}
