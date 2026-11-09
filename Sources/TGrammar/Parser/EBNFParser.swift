// Recursive-descent parser for the EBNF dialect. Produces un-normalized grammar storage; the
// normalization passes in `Transform/` bring it into the canonical form used by the matcher.

struct EBNFParser {
    /// Value of a macro argument such as `TagDispatch(("<tool>", tool), loop_after_dispatch=false)`.
    indirect enum MacroValue {
        case string([UInt8])
        case integer(Int64)
        case boolean(Bool)
        case identifier(String)
        case tuple([MacroValue])
    }

    struct MacroArguments {
        var positional: [MacroValue] = []
        var named: [String: MacroValue] = [:]
    }

    /// Macros look like function calls; the name selects the parser.
    private mutating func parseMacro(named name: String) throws(GrammarError) -> Int32? {
        switch name {
        case "TagDispatch": try parseTagDispatch()
        case "Token": try parseTokenSet()
        case "ExcludeToken": try parseExcludeToken()
        case "TokenTagDispatch": try parseTokenTagDispatch()
        case "Regex": try parseRegexMacro()
        case "Substring": try parseSubstringMacro()
        default: nil
        }
    }

    private let tokens: [EBNFToken]
    private var position = 0
    private var builder = GrammarBuilder()
    private var currentRuleName = ""
    private let rootRuleName: String
    private var nestDepth = 0
    private let maxNestDepth: Int

    private init(tokens: [EBNFToken], rootRuleName: String, maxNestDepth: Int) {
        self.tokens = tokens
        self.rootRuleName = rootRuleName
        self.maxNestDepth = maxNestDepth
    }

    /// Parses `source` into un-normalized storage rooted at `rootRule`.
    static func parse(_ source: String, rootRule: String = "root", maxNestDepth: Int = 1000) throws(GrammarError) -> GrammarStorage {
        let tokens = try EBNFLexer.tokenize(source)
        var parser = EBNFParser(tokens: tokens, rootRuleName: rootRule, maxNestDepth: maxNestDepth)
        return try parser.parseGrammar()
    }

    // MARK: Token cursor

    @inline(__always)
    private func peek(_ delta: Int = 0) -> EBNFToken {
        tokens[min(position &+ delta, tokens.count &- 1)]
    }

    @inline(__always)
    private mutating func consume(_ count: Int = 1) { position += count }

    private func error(_ message: String, delta: Int = 0) -> GrammarError {
        let token = peek(delta)
        return .parser(message: message, line: token.line, column: token.column)
    }

    private mutating func expect(_ kind: EBNFToken.Kind, _ message: String) throws(GrammarError) {
        guard peek().kind == kind else { throw error(message) }
        consume()
    }

    // MARK: Grammar

    private mutating func parseGrammar() throws(GrammarError) -> GrammarStorage {
        try declareRuleNames()
        while peek().kind != .endOfFile {
            try parseRule()
        }
        return try builder.finish(rootRuleName: rootRuleName)
    }

    /// Declares every rule up front so bodies can reference rules defined later.
    private mutating func declareRuleNames() throws(GrammarError) {
        for (index, token) in tokens.enumerated() where token.kind == .ruleName {
            let name = token.identifier
            if builder.ruleID(named: name) != nil {
                throw error("Rule \"\(name)\" is defined multiple times", delta: index &- position)
            }
            builder.addEmptyRule(name: name)
        }
        if builder.ruleID(named: rootRuleName) == nil {
            throw error("The root rule with name \"\(rootRuleName)\" is not found")
        }
    }

    private mutating func parseRule() throws(GrammarError) {
        guard peek().kind == .ruleName else { throw error("Expect rule name") }
        let nameToken = peek()
        currentRuleName = nameToken.identifier
        let attributes = nameToken.attributes ?? RuleAttributes()
        consume()
        try expect(.assign, "Expect ::=")
        let bodyID = try parseChoices()
        var lookaheadID: Int32 = -1
        if peek().kind == .lookaheadLParen {
            let start = peek()
            consume()
            lookaheadID = try parseChoices()
            try expect(.rParen, "Expect )")
            if let problem = unsupportedLookahead(lookaheadID) {
                throw .parser(message: problem, line: start.line, column: start.column)
            }
        }
        let ruleID = builder.ruleID(named: currentRuleName)!
        builder.updateRuleBody(ruleID, bodyID)
        builder.updateLookaheadAssertion(ruleID, lookaheadID)
        builder.updateMaxTokens(ruleID, attributes.maxTokens)
        builder.updateMaxChars(ruleID, attributes.maxChars)
        builder.updateCaptureName(ruleID, attributes.captureName)
        builder.updateSuffixStopInfo(ruleID, attributes.suffixStopInfo)
        builder.updateLazy(ruleID, attributes.isLazy)
        builder.updateTemperature(ruleID, attributes.temperature)
    }

    /// Why the normalizer cannot turn a lookahead assertion into a flat sequence, looking
    /// through the single-element groups it unwraps.
    private func unsupportedLookahead(_ id: Int32) -> String? {
        let expr = builder.expr(id)
        switch expr.kind {
        case .sequence where expr.count == 1, .choices where expr.count == 1: return unsupportedLookahead(expr[0])
        case .sequence: return nil
        case .choices: return "Choices in lookahead assertion are not supported yet"
        case .emptyString: return "Empty string should not be in lookahead assertion"
        case .tagDispatch: return "TagDispatch should not be in lookahead assertion"
        case .regex: return "Regex should not be in lookahead assertion"
        case .substring: return "Substring should not be in lookahead assertion"
        default: return nil
        }
    }

    // MARK: Expressions

    private mutating func parseChoices() throws(GrammarError) -> Int32 {
        guard StackGuard.hasRoom else { throw error(StackGuard.message) }
        var choices = [try parseSequence()]
        while peek().kind == .pipe {
            consume()
            choices.append(try parseSequence())
        }
        return builder.addChoices(choices)
    }

    private mutating func parseSequence() throws(GrammarError) -> Int32 {
        var elements: [Int32] = []
        repeat {
            elements.append(try parseElementWithQuantifier())
        } while !Self.endsSequence(peek().kind)
        return builder.addSequence(elements)
    }

    private static func endsSequence(_ kind: EBNFToken.Kind) -> Bool {
        switch kind {
        case .pipe, .rParen, .lookaheadLParen, .ruleName, .endOfFile: true
        default: false
        }
    }

    private mutating func parseElementWithQuantifier() throws(GrammarError) -> Int32 {
        let exprID = try parseElement()
        switch peek().kind {
        case .star:
            consume()
            return starQuantifier(exprID)
        case .plus:
            consume()
            return plusQuantifier(exprID)
        case .question:
            consume()
            return questionQuantifier(exprID)
        case .lBrace:
            let (lower, upper) = try parseRepetitionRange()
            return builder.addRepeat(exprID: exprID, min: Int32(lower), max: upper == -1 ? -1 : Int32(upper), nameHint: currentRuleName)
        default:
            return exprID
        }
    }

    /// `a*` → `[a-z]*` stays a character-class star; otherwise `rule ::= "" | a rule`.
    private mutating func starQuantifier(_ exprID: Int32) -> Int32 {
        let expr = builder.expr(exprID)
        if expr.kind == .characterClass {
            let payload = Array(expr.data)
            return builder.addExpr(.characterClassStar, payload)
        }
        let ruleID = builder.addEmptyRule(hint: currentRuleName)
        let selfRef = builder.addRuleRef(ruleID)
        let empty = builder.addEmptyString()
        let body = builder.addChoices([empty, builder.addSequence([exprID, selfRef])])
        builder.updateRuleBody(ruleID, body)
        return builder.addRuleRef(ruleID)
    }

    /// `a+` → `rule ::= a rule | a`.
    private mutating func plusQuantifier(_ exprID: Int32) -> Int32 {
        let ruleID = builder.addEmptyRule(hint: currentRuleName)
        let selfRef = builder.addRuleRef(ruleID)
        let body = builder.addChoices([builder.addSequence([exprID, selfRef]), exprID])
        builder.updateRuleBody(ruleID, body)
        return builder.addRuleRef(ruleID)
    }

    /// `a?` → `rule ::= "" | a`.
    private mutating func questionQuantifier(_ exprID: Int32) -> Int32 {
        let empty = builder.addEmptyString()
        let body = builder.addChoices([empty, exprID])
        let ruleID = builder.addRule(hint: currentRuleName, bodyExprID: body)
        return builder.addRuleRef(ruleID)
    }

    private mutating func parseInteger() throws(GrammarError) -> Int64 {
        guard case let .integer(value) = peek().value, peek().kind == .integerLiteral else {
            throw error("Expect integer, but got \(peek().lexeme)")
        }
        consume()
        return value
    }

    /// `{n}`, `{n,}`, `{n,m}`; the printer's `{n, -1}` is accepted as `{n,}`.
    private mutating func parseRepetitionRange() throws(GrammarError) -> (Int64, Int64) {
        try expect(.lBrace, "Expect {")
        let lower = try parseInteger()
        if lower < 0 { throw error("Lower bound cannot be negative", delta: -1) }
        switch peek().kind {
        case .comma:
            consume()
            if peek().kind == .rBrace {
                consume()
                return (lower, -1)
            }
            if peek().kind == .identifier, peek().lexeme == "-1" {
                consume()
                try expect(.rBrace, "Expect }")
                return (lower, -1)
            }
            let upper = try parseInteger()
            if upper < lower {
                throw error("Lower bound is larger than upper bound: \(lower) > \(upper)", delta: -1)
            }
            try expect(.rBrace, "Expect }")
            return (lower, upper)
        case .rBrace:
            consume()
            return (lower, lower)
        default:
            throw error("Expect ',' or '}' in repetition range")
        }
    }

    private mutating func parseElement() throws(GrammarError) -> Int32 {
        switch peek().kind {
        case .lParen:
            nestDepth += 1
            if nestDepth > maxNestDepth { throw error("Nest layer exceeded the maximum limit", delta: -1) }
            consume()
            if peek().kind == .rParen {
                consume()
                nestDepth -= 1
                return builder.addEmptyString()
            }
            let exprID = try parseChoices()
            try expect(.rParen, "Expect )")
            nestDepth -= 1
            return exprID
        case .lBracket:
            return try parseCharacterClass()
        case .stringLiteral:
            return try parseString()
        case .identifier:
            if let exprID = try parseMacro(named: peek().identifier) { return exprID }
            return try parseRuleRef()
        default:
            throw error("Expect element, but got \(peek().lexeme)")
        }
    }

    private mutating func parseCharacterClass() throws(GrammarError) -> Int32 {
        try expect(.lBracket, "Expect [ in character class")
        var isNegated = false
        if peek().kind == .caret {
            isNegated = true
            consume()
        }
        var ranges: [ClosedRange<Codepoint>] = []
        while peek().kind != .rBracket, peek().kind != .endOfFile {
            if peek().kind == .escapeInCharClass {
                throw error("Character class escape is not supported yet in EBNF")
            }
            let lower = try characterClassCodepoint(peek())
            consume()
            if peek().kind == .dash, peek(1).kind == .charInCharClass || peek(1).kind == .dash {
                let upper = try characterClassCodepoint(peek(1))
                if lower > upper {
                    throw error("Invalid character class: lower bound is larger than upper bound", delta: -1)
                }
                ranges.append(lower ... upper)
                consume(2)
            } else {
                ranges.append(lower ... lower)
            }
        }
        try expect(.rBracket, "Expect ] in character class")
        return builder.addCharacterClass(ranges, isNegated: isNegated)
    }

    private func characterClassCodepoint(_ token: EBNFToken) throws(GrammarError) -> Codepoint {
        switch token.kind {
        case .charInCharClass:
            if case let .codepoint(value) = token.value { return value }
        case .dash:
            return Codepoint(UInt8(ascii: "-"))
        default:
            break
        }
        throw error("Unexpected character in character class: \(token.lexeme)")
    }

    private mutating func parseString() throws(GrammarError) -> Int32 {
        guard peek().kind == .stringLiteral, case let .string(bytes) = peek().value else {
            throw error("Expect string literal")
        }
        consume()
        return bytes.isEmpty ? builder.addEmptyString() : builder.addByteString(bytes)
    }

    private mutating func parseRuleRef() throws(GrammarError) -> Int32 {
        guard peek().kind == .identifier else { throw error("Expect identifier") }
        let name = peek().identifier
        consume()
        guard let ruleID = builder.ruleID(named: name) else {
            throw error("Rule \"\(name)\" is not defined", delta: -1)
        }
        return builder.addRuleRef(ruleID)
    }

    // MARK: Macros

    private mutating func parseMacroArguments() throws(GrammarError) -> MacroArguments {
        var arguments = MacroArguments()
        try expect(.lParen, "Expect ( after macro function name")
        if peek().kind != .rParen {
            while true {
                if peek().kind == .identifier, peek(1).kind == .equal {
                    let name = peek().identifier
                    consume(2)
                    arguments.named[name] = try parseMacroValue()
                } else {
                    arguments.positional.append(try parseMacroValue())
                }
                if peek().kind == .comma {
                    consume()
                } else if peek().kind == .rParen {
                    break
                } else {
                    throw error("Expect , or ) in macro arguments")
                }
            }
        }
        try expect(.rParen, "Expect ) after macro arguments")
        return arguments
    }

    private mutating func parseMacroValue() throws(GrammarError) -> MacroValue {
        let token = peek()
        switch (token.kind, token.value) {
        case let (.stringLiteral, .string(bytes)):
            consume()
            return .string(bytes)
        case let (.integerLiteral, .integer(value)):
            consume()
            return .integer(value)
        case let (.booleanLiteral, .boolean(value)):
            consume()
            return .boolean(value)
        case let (.identifier, .identifier(name)):
            consume()
            return .identifier(name)
        case (.lParen, _):
            nestDepth += 1
            if nestDepth > maxNestDepth { throw error("Nest layer exceeded the maximum limit", delta: -1) }
            consume()
            var elements: [MacroValue] = []
            if peek().kind != .rParen {
                while true {
                    elements.append(try parseMacroValue())
                    if peek().kind == .comma {
                        consume()
                        if peek().kind == .rParen { break }
                    } else if peek().kind == .rParen {
                        break
                    } else {
                        throw error("Expect , or ) in tuple")
                    }
                }
            }
            consume()
            nestDepth -= 1
            return .tuple(elements)
        default:
            throw error("Expect string, integer, boolean, or tuple in macro argument")
        }
    }

    private mutating func parseTagDispatch() throws(GrammarError) -> Int32 {
        consume()
        let start = position
        let arguments = try parseMacroArguments()
        let delta = start &- position
        for name in arguments.named.keys where name != "loop_after_dispatch" && name != "excludes" {
            throw error("Unknown named argument for TagDispatch: \(name)", delta: delta)
        }
        var dispatch = TagDispatch()
        for argument in arguments.positional {
            guard case let .tuple(elements) = argument else {
                throw error("Each tag dispatch element must be a tuple", delta: delta)
            }
            guard elements.count == 2 else {
                throw error("Each tag dispatch element must be a pair (tag, rule)", delta: delta)
            }
            guard case let .string(tag) = elements[0], !tag.isEmpty else {
                throw error("Tag must be a non-empty string literal", delta: delta)
            }
            guard case let .identifier(ruleName) = elements[1] else {
                throw error("Rule reference must be an identifier", delta: delta)
            }
            guard let ruleID = builder.ruleID(named: ruleName) else {
                throw error("Rule \"\(ruleName)\" is not defined", delta: delta)
            }
            dispatch.tagRulePairs.append((tag, ruleID))
        }
        if let value = arguments.named["loop_after_dispatch"] {
            guard case let .boolean(loop) = value else {
                throw error("loop_after_dispatch must be a boolean literal", delta: delta)
            }
            dispatch.loopAfterDispatch = loop
        }
        if let value = arguments.named["excludes"] {
            guard case let .tuple(elements) = value else { throw error("excludes must be a tuple", delta: delta) }
            for element in elements {
                guard case let .string(exclude) = element, !exclude.isEmpty else {
                    throw error("Exclude must be a non-empty string literal", delta: delta)
                }
                dispatch.excludes.append(exclude)
            }
        }
        for exclude in dispatch.excludes {
            for pair in dispatch.tagRulePairs where pair.tag.starts(with: exclude) {
                throw error("Exclude string must not be a prefix of trigger string: \(String(decoding: exclude, as: UTF8.self))", delta: delta)
            }
        }
        return builder.addTagDispatch(dispatch)
    }

    private mutating func parseRegexMacro() throws(GrammarError) -> Int32 {
        consume()
        let start = position
        let arguments = try parseMacroArguments()
        let delta = start &- position
        guard arguments.positional.count == 1 else {
            throw error("Regex expects exactly one string argument", delta: delta)
        }
        guard case let .string(patternBytes) = arguments.positional[0] else {
            throw error("Regex pattern must be a string literal", delta: delta)
        }
        for name in arguments.named.keys where name != "json_string" && name != "flags" {
            throw error("Regex does not support the named argument \(name)", delta: delta)
        }
        var isJSONString = false
        if let value = arguments.named["json_string"] {
            guard case let .boolean(flag) = value else { throw error("json_string must be a boolean", delta: delta) }
            isJSONString = flag
        }
        var pattern = patternBytes
        if let value = arguments.named["flags"] {
            guard case let .string(flags) = value else { throw error("flags must be a string", delta: delta) }
            var caseInsensitive = false
            var dotAll = false
            for flag in flags {
                switch flag {
                case UInt8(ascii: "i"): caseInsensitive = true
                case UInt8(ascii: "s"): dotAll = true
                case UInt8(ascii: "u"): break
                default:
                    throw error("regular-expression flag '\(String(decoding: [flag], as: UTF8.self))' is not supported", delta: delta)
                }
            }
            pattern = RegexSyntax.rewriteDots(pattern, dotMatchesNewline: dotAll)
            if caseInsensitive, !pattern.starts(with: Array("(?i)".utf8)) {
                pattern = Array("(?i)".utf8) + pattern
            }
        }
        return builder.addRegex(pattern, isJSONString: isJSONString)
    }

    private mutating func parseSubstringMacro() throws(GrammarError) -> Int32 {
        consume()
        let start = position
        let arguments = try parseMacroArguments()
        let delta = start &- position
        guard arguments.named.isEmpty else {
            throw error("Substring() does not accept named arguments", delta: delta)
        }
        var chunks: [[UInt8]] = []
        chunks.reserveCapacity(arguments.positional.count)
        for argument in arguments.positional {
            guard case let .string(chunk) = argument else {
                throw error("Substring() arguments must be strings", delta: delta)
            }
            chunks.append(chunk)
        }
        return builder.addSubstring(chunks)
    }

    private mutating func parseTokenIDList(macro: String) throws(GrammarError) -> [Int32] {
        consume()
        let start = position
        let arguments = try parseMacroArguments()
        let delta = start &- position
        guard arguments.named.isEmpty else {
            throw error("\(macro)() does not accept named arguments", delta: delta)
        }
        guard !arguments.positional.isEmpty else {
            throw error("\(macro)() requires at least one integer argument", delta: delta)
        }
        var tokenIDs: [Int32] = []
        tokenIDs.reserveCapacity(arguments.positional.count)
        for argument in arguments.positional {
            guard case let .integer(value) = argument, value >= 0 else {
                throw error("\(macro)() arguments must be non-negative integers", delta: delta)
            }
            tokenIDs.append(Int32(truncatingIfNeeded: value))
        }
        tokenIDs.sort()
        var unique: [Int32] = []
        unique.reserveCapacity(tokenIDs.count)
        for id in tokenIDs where unique.last != id { unique.append(id) }
        return unique
    }

    private mutating func parseTokenSet() throws(GrammarError) -> Int32 {
        builder.addTokenSet(try parseTokenIDList(macro: "Token"))
    }

    private mutating func parseExcludeToken() throws(GrammarError) -> Int32 {
        builder.addExcludeTokenSet(try parseTokenIDList(macro: "ExcludeToken"))
    }

    private mutating func parseTokenTagDispatch() throws(GrammarError) -> Int32 {
        consume()
        let start = position
        let arguments = try parseMacroArguments()
        let delta = start &- position
        for name in arguments.named.keys where name != "loop_after_dispatch" && name != "excludes" {
            throw error("Unknown named argument for TokenTagDispatch: \(name)", delta: delta)
        }
        var dispatch = TokenTagDispatch()
        for argument in arguments.positional {
            guard case let .tuple(elements) = argument, elements.count == 2 else {
                throw error("Each TokenTagDispatch element must be a pair (token_id, rule)", delta: delta)
            }
            guard case let .integer(tokenID) = elements[0], tokenID >= 0 else {
                throw error("Token trigger ID must be a non-negative integer", delta: delta)
            }
            guard case let .identifier(ruleName) = elements[1] else {
                throw error("Rule reference must be an identifier", delta: delta)
            }
            guard let ruleID = builder.ruleID(named: ruleName) else {
                throw error("Rule \"\(ruleName)\" is not defined", delta: delta)
            }
            dispatch.triggerRulePairs.append((Int32(truncatingIfNeeded: tokenID), ruleID))
        }
        if let value = arguments.named["loop_after_dispatch"] {
            guard case let .boolean(loop) = value else { throw error("loop_after_dispatch must be a boolean", delta: delta) }
            dispatch.loopAfterDispatch = loop
        }
        if let value = arguments.named["excludes"] {
            guard case let .tuple(elements) = value else { throw error("excludes must be a tuple", delta: delta) }
            for element in elements {
                guard case let .integer(tokenID) = element, tokenID >= 0 else {
                    throw error("Exclude token ID must be a non-negative integer", delta: delta)
                }
                dispatch.excludes.append(Int32(truncatingIfNeeded: tokenID))
            }
        }
        for exclude in dispatch.excludes {
            for pair in dispatch.triggerRulePairs where pair.tokenID == exclude {
                throw error("Token trigger ID \(pair.tokenID) must not overlap with exclude token ID", delta: delta)
            }
        }
        return builder.addTokenTagDispatch(dispatch)
    }
}

/// Small regex-source rewrites shared by the EBNF and Lark front ends.
enum RegexSyntax {
    /// Replaces every unescaped `.` outside a character class with `[^\n]` so that the pattern
    /// follows standard dot semantics. With `dotMatchesNewline` the pattern is returned as is.
    static func rewriteDots(_ pattern: [UInt8], dotMatchesNewline: Bool) -> [UInt8] {
        if dotMatchesNewline { return pattern }
        var result: [UInt8] = []
        result.reserveCapacity(pattern.count)
        var escaped = false
        var inClass = false
        for byte in pattern {
            if escaped {
                result.append(byte)
                escaped = false
                continue
            }
            switch byte {
            case UInt8(ascii: "\\"):
                result.append(byte)
                escaped = true
            case UInt8(ascii: "["):
                result.append(byte)
                inClass = true
            case UInt8(ascii: "]") where inClass:
                result.append(byte)
                inClass = false
            case UInt8(ascii: ".") where !inClass:
                result.append(contentsOf: "[^\\n]".utf8)
            default:
                result.append(byte)
            }
        }
        return result
    }
}
