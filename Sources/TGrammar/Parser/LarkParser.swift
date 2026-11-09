indirect enum LarkNode {
    case string(String, flags: String, at: LarkLocation)
    case regex(String, flags: String, at: LarkLocation)
    case range(Int32, Int32)
    case name(String, at: LarkLocation)
    case sequence([LarkNode])
    case choice([LarkNode])
    case repeatNode(LarkNode, minimum: Int32, maximum: Int32)
    case special(String, at: LarkLocation)
    case reference(String, at: LarkLocation)
    case json(String, at: LarkLocation)
    case nested(String, at: LarkLocation)
    case structuredRegex(String, at: LarkLocation)
}

struct LarkDocument {
    struct Definition {
        var name: String
        var body: LarkNode
        var attributes = RuleAttributes()
        var marker: LarkNode?
        var markerIsStop = false
        var location: LarkToken
        var hasAttributes = false
        /// Where `max_tokens` / `capture` were written, for diagnostics raised after parsing.
        var maxTokensLocation: LarkToken?
        var captureLocation: LarkToken?
        var isTerminal: Bool { name.utf8.first(where: { $0 != 95 }).map { (65 ... 90).contains($0) } ?? false }
    }
    var definitions: [Definition] = []
    var ignores: [LarkNode] = []
    var allowInitialSkip = false
}

struct LarkParser {
    private let tokens: [LarkToken]
    private var position = 0
    private var depth = 0
    private init(_ tokens: [LarkToken]) { self.tokens = tokens }
    private func peek(_ delta: Int = 0) -> LarkToken { tokens[min(position + delta, tokens.count - 1)] }
    @discardableResult private mutating func take() -> LarkToken { defer { position += 1 }; return peek() }
    private func isSymbol(_ text: String, _ delta: Int = 0) -> Bool { peek(delta).kind == .symbol && peek(delta).text == text }
    private mutating func match(_ text: String) -> Bool {
        if (peek().kind == .symbol || peek().kind == .directive), peek().text == text { take(); return true }
        return false
    }
    private mutating func expect(_ text: String, _ message: String) throws(GrammarError) { guard match(text) else { throw peek().error(message) } }
    private mutating func name(_ message: String) throws(GrammarError) -> String { guard peek().kind == .name else { throw peek().error(message) }; return take().text }
    private mutating func newlines() { while peek().kind == .newline { take() } }

    static func parse(_ source: String) throws(GrammarError) -> LarkDocument {
        var parser = Self(try LarkLexer.tokenize(source))
        return try parser.document()
    }
    private mutating func document() throws(GrammarError) -> LarkDocument {
        var document = LarkDocument()
        newlines()
        while peek().kind != .eof {
            if peek().text == "%import" {
                take(); let location = peek()
                var path = try name("expected import path")
                while match(".") { path += "." + (try name("expected name after '.'")) }
                var imports: [(String, String)] = []
                if match("(") {
                    repeat { let local = try name("expected imported terminal name"); imports.append((path + "." + local, local)) } while match(",")
                    try expect(")", "expected ')' after import list")
                } else {
                    let local = match("->") ? try name("expected import alias") : String(path.split(separator: ".").last ?? "")
                    imports.append((path, local))
                }
                for (path, local) in imports {
                    guard let pattern = LarkCommonTerminals.patterns[path] else { throw location.error("unknown common import '\(path)'") }
                    document.definitions.append(.init(name: local, body: .regex(pattern, flags: "", at: location.location), location: location))
                }
            } else if peek().text == "%ignore" {
                take(); document.ignores.append(try choice())
            } else if peek().kind == .embedded && peek().flags == "%grammar_options" {
                let token = take()
                let options = try JSONValue.parse(token.text)
                guard let members = options.members else { throw token.error("%grammar_options value must be an object") }
                for member in members {
                    switch member.key {
                    case "allow_initial_skip", "no_forcing", "allow_invalid_utf8":
                        guard let enabled = member.value.bool else { throw token.error("\(member.key) must be a boolean") }
                        if member.key == "allow_initial_skip" { document.allowInitialSkip = document.allowInitialSkip || enabled }
                        else if enabled { throw token.error("%grammar_options option '\(member.key)' is not supported") }
                    default: throw token.error("unknown %grammar_options option '\(member.key)'")
                    }
                }
            } else if peek().kind == .directive {
                throw peek().error("directive \(peek().text) is not supported")
            } else {
                _ = match("?") || match("!")
                let token = peek(), ruleName = try name("expected rule or terminal name")
                var definition = LarkDocument.Definition(name: ruleName, body: .sequence([]), location: token)
                if isSymbol("[") {
                    if definition.isTerminal { throw peek().error("attributes are only supported on rules") }
                    take()
                    try ruleAttributes(&definition)
                }
                if isSymbol(".") { throw peek().error("rule and terminal priorities are not supported") }
                if isSymbol("::") { throw peek().error("parametric grammar is not supported") }
                if isSymbol("{") { throw peek().error("Lark templates are not supported") }
                try expect(":", "expected ':' after rule name")
                definition.body = try choice()
                document.definitions.append(definition)
            }
            guard peek().kind == .eof || peek().kind == .newline else { throw peek().error("expected end of grammar item") }
            newlines()
        }
        return document
    }

    private func validateCaptureName(_ name: String, _ token: LarkToken) throws(GrammarError) {
        guard !name.isEmpty else { throw token.error("capture name must not be empty") }
        guard name.utf8.allSatisfy({ (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0) || [95, 45, 46].contains($0) }) else {
            throw token.error("capture name must only contain letters, digits, '_', '-' and '.'")
        }
    }

    private mutating func stopLikeValue(_ key: String) throws(GrammarError) -> LarkNode {
        let value = take()
        switch value.kind {
        case .string:
            guard !value.text.isEmpty else { throw value.error("\(key) must not be empty") }
            return .string(value.text, flags: value.flags, at: value.location)
        case .regex: return .regex(value.text, flags: value.flags, at: value.location)
        case .name:
            guard value.text.utf8.first(where: { $0 != 95 }).map({ (65 ... 90).contains($0) }) == true else { throw value.error("\(key) terminal name must be uppercase") }
            return .name(value.text, at: value.location)
        default: throw value.error("expected string literal, regular expression, or uppercase terminal name after \(key)=")
        }
    }

    private mutating func ruleAttributes(_ definition: inout LarkDocument.Definition) throws(GrammarError) {
        definition.hasAttributes = true
        var hasMaxTokens = false, hasMaxChars = false, hasCapture = false, hasStopCapture = false, hasTemperature = false
        var hasSuffix = false, hasStop = false
        var stopCaptureToken: LarkToken?
        while !isSymbol("]") {
            let key = peek(), keyName = try name("expected rule attribute")
            switch keyName {
            case "lazy" where !isSymbol("="): definition.attributes.isLazy = true
            case "max_tokens", "max_chars":
                try expect("=", "expected '=' after \(keyName) attribute")
                let valueToken = peek(), value = try integer()
                if keyName == "max_tokens" {
                    guard value > 0 else { throw valueToken.error("max_tokens must be positive") }
                    guard value <= 1_000_000 else { throw valueToken.error("max_tokens is too large") }
                    guard !hasMaxTokens else { throw key.error("max_tokens attribute is specified more than once") }
                    hasMaxTokens = true; definition.attributes.maxTokens = value; definition.maxTokensLocation = key
                } else {
                    guard !hasMaxChars else { throw key.error("max_chars attribute is specified more than once") }
                    hasMaxChars = true; definition.attributes.maxChars = value
                }
            case "capture":
                var captureName = definition.name, location = key
                if match("=") {
                    let value = take()
                    guard value.kind == .string else { throw value.error("expected string literal after capture=") }
                    guard value.flags.isEmpty else { throw value.error("case-insensitive flags are not supported on capture") }
                    captureName = value.text; location = value
                }
                try validateCaptureName(captureName, location)
                guard !hasCapture else { throw key.error("capture attribute is specified more than once") }
                hasCapture = true; definition.attributes.captureName = captureName; definition.captureLocation = location
            case "suffix", "stop":
                try expect("=", "expected '=' after \(keyName) attribute")
                let marker = try stopLikeValue(keyName)
                let isStop = keyName == "stop"
                guard !(isStop ? hasStop : hasSuffix) else { throw key.error("\(keyName) attribute is specified more than once") }
                guard !(isStop ? hasSuffix : hasStop) else { throw key.error(isStop ? "stop cannot be combined with suffix" : "suffix cannot be combined with stop") }
                if isStop { hasStop = true } else { hasSuffix = true }
                definition.marker = marker; definition.markerIsStop = isStop
            case "stop_capture":
                try expect("=", "expected '=' after stop_capture attribute")
                let value = take()
                guard value.kind == .string else { throw value.error("expected string literal after stop_capture=") }
                guard value.flags.isEmpty else { throw value.error("case-insensitive flags are not supported on stop_capture") }
                try validateCaptureName(value.text, value)
                guard !hasStopCapture else { throw key.error("stop_capture attribute is specified more than once") }
                hasStopCapture = true; stopCaptureToken = value; definition.attributes.stopCaptureName = value.text
            case "temperature":
                try expect("=", "expected '=' after temperature attribute")
                let value = take()
                guard value.kind == .number else { throw value.error("expected number after temperature=") }
                guard !hasTemperature else { throw key.error("temperature attribute is specified more than once") }
                guard let number = Float(value.text), number.isFinite, number >= 0 else { throw value.error("temperature must be a finite non-negative number") }
                hasTemperature = true; definition.attributes.temperature = number
            default: throw key.error("rule attribute '\(keyName)' is not supported by XGrammar Lark")
            }
            guard match(",") else { break }
        }
        try expect("]", "expected ']' after rule attributes")
        if let stopCaptureToken, !hasSuffix, !hasStop { throw stopCaptureToken.error("stop_capture requires stop or suffix") }
    }
    private mutating func choice() throws(GrammarError) -> LarkNode {
        var choices = [try sequence()]
        while true {
            if peek().kind == .newline {
                var next = 0
                while peek(next).kind == .newline { next += 1 }
                if isSymbol("|", next) || depth > 0 { newlines() }
            }
            guard match("|") else { break }
            choices.append(try sequence())
        }
        return choices.count == 1 ? choices[0] : .choice(choices)
    }
    private mutating func sequence() throws(GrammarError) -> LarkNode {
        var elements: [LarkNode] = []
        while true {
            if depth > 0 { newlines() }
            if peek().kind == .eof || peek().kind == .newline || (peek().kind == .symbol && ["|", ")", "]", "}", "->", "&"].contains(peek().text))
                || (peek().kind == .directive && peek().text == "%if") { break }
            elements.append(try repeated())
        }
        if match("->") { _ = try name("expected alias name after '->'") }
        if isSymbol("&") { throw peek().error("terminal intersection '&' is not supported") }
        if peek().kind == .directive && peek().text == "%if" { throw peek().error("parametric %if conditions are not supported") }
        return elements.count == 1 ? elements[0] : .sequence(elements)
    }
    /// Upstream's ParseInteger: every malformed or out-of-range count reports "invalid repetition count".
    private mutating func integer() throws(GrammarError) -> Int32 {
        let token = take()
        guard token.kind == .number else { throw token.error("expected integer") }
        guard let count = Int32(token.text), count >= 0 else { throw token.error("invalid repetition count") }
        return count
    }
    private mutating func repeated() throws(GrammarError) -> LarkNode {
        let location = peek()
        let element = try atom()
        if match("*") { return .repeatNode(element, minimum: 0, maximum: -1) }
        if match("+") { return .repeatNode(element, minimum: 1, maximum: -1) }
        if match("?") { return .repeatNode(element, minimum: 0, maximum: 1) }
        var lower: Int32, upper: Int32
        if match("~") { lower = try integer(); upper = match("..") ? try integer() : lower }
        else if match("{") {
            lower = isSymbol(",") ? 0 : try integer()
            if match(",") { upper = isSymbol("}") ? -1 : try integer() } else { upper = lower }
            try expect("}", "expected '}' after repetition range")
        } else { return element }
        guard upper == -1 || upper >= lower else { throw location.error("repetition end must be greater than or equal to start") }
        return .repeatNode(element, minimum: lower, maximum: upper)
    }
    private mutating func atom() throws(GrammarError) -> LarkNode {
        let token = take()
        switch token.kind {
        case .string:
            if match("..") {
                let end = take()
                guard end.kind == .string else { throw end.error("expected string after '..'") }
                guard token.flags.isEmpty else { throw token.error("flags are not allowed on character ranges") }
                guard end.flags.isEmpty else { throw end.error("flags are not allowed on character ranges") }
                guard token.text.unicodeScalars.count == 1, end.text.unicodeScalars.count == 1 else { throw token.error("character range endpoints must be one character") }
                let lower = Int32(token.text.unicodeScalars.first!.value), upper = Int32(end.text.unicodeScalars.first!.value)
                guard lower <= upper else { throw token.error("character range start must not exceed end") }
                return .range(lower, upper)
            }
            return .string(token.text, flags: token.flags, at: token.location)
        case .regex: return .regex(token.text, flags: token.flags, at: token.location)
        case .name:
            if isSymbol("::") { throw peek().error("parametric grammar is not supported") }
            if isSymbol("{"), !isSymbol(",", 1), peek(1).kind != .number { throw peek().error("Lark templates are not supported") }
            return .name(token.text, at: token.location)
        case .special: return .special(token.text, at: token.location)
        case .reference: return .reference(token.text, at: token.location)
        case .embedded:
            switch token.flags {
            case "%json": return .json(token.text, at: token.location)
            case "%lark": return .nested(String(token.text.dropFirst().dropLast()), at: token.location)
            case "%regex": return .structuredRegex(token.text, at: token.location)
            default: throw token.error("directive \(token.flags) is not supported")
            }
        case .directive: throw token.error("directive \(token.text) is not supported")
        case .symbol where token.text == "~": throw token.error("regular-expression complement '~' is not supported")
        case .symbol where token.text == "(" || token.text == "[":
            guard depth < 200 else { throw token.error("groups are nested deeper than 200 levels") }
            guard StackGuard.hasRoom else { throw token.error(StackGuard.message) }
            depth += 1
            let content = try choice()
            try expect(token.text == "(" ? ")" : "]", token.text == "(" ? "expected ')' after group" : "expected ']' after optional group")
            depth -= 1
            return token.text == "[" ? .repeatNode(content, minimum: 0, maximum: 1) : content
        default: throw token.error("expected grammar expression")
        }
    }
}

enum LarkCommonTerminals {
    static let patterns: [String: String] = [
        "common.DIGIT": "[0-9]", "common.HEXDIGIT": "[a-fA-F0-9]", "common.INT": "[0-9]+",
        "common.SIGNED_INT": #"(\+|-)?[0-9]+"#, "common.DECIMAL": #"([0-9]+\.[0-9]*)|(\.[0-9]+)"#,
        "common._EXP": #"[eE](\+|-)?[0-9]+"#,
        "common.FLOAT": #"([0-9]+\.[0-9]*|\.[0-9]+)([eE](\+|-)?[0-9]+)?|[0-9]+[eE](\+|-)?[0-9]+"#,
        "common.SIGNED_FLOAT": #"(\+|-)?(([0-9]+\.[0-9]*|\.[0-9]+)([eE](\+|-)?[0-9]+)?|[0-9]+[eE](\+|-)?[0-9]+)"#,
        "common.NUMBER": #"([0-9]+)|([0-9]+\.[0-9]*|\.[0-9]+)([eE](\+|-)?[0-9]+)?|[0-9]+[eE](\+|-)?[0-9]+"#,
        "common.SIGNED_NUMBER": #"(\+|-)?(([0-9]+)|([0-9]+\.[0-9]*|\.[0-9]+)([eE](\+|-)?[0-9]+)?|[0-9]+[eE](\+|-)?[0-9]+)"#,
        "common.ESCAPED_STRING": #"\"([^\"\\]|\\.)*\""#,
        "common.LCASE_LETTER": "[a-z]", "common.UCASE_LETTER": "[A-Z]", "common.LETTER": "[A-Za-z]",
        "common.WORD": "[A-Za-z]+", "common.CNAME": "[_A-Za-z][_A-Za-z0-9]*",
        "common.WS_INLINE": #"[ \t]+"#, "common.WS": #"[ \t\f\r\n]+"#,
        "common.CR": #"\r"#, "common.LF": #"\n"#, "common.NEWLINE": #"(\r?\n)+"#,
        "common.SH_COMMENT": #"#[^\n]*"#, "common.CPP_COMMENT": #"//[^\n]*"#,
        "common.C_COMMENT": #"\/\*[^*]*\*+(?:[^/*][^*]*\*+)*\/"#, "common.SQL_COMMENT": #"--[^\n]*"#,
    ]
}
