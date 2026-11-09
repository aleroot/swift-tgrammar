/// A named subgrammar embedded with `@name` in Lark source.
public enum NamedGrammar: Sendable {
    case grammar(Grammar)
    case lark(String)
}

extension Grammar {
    public convenience init(lark: String, tokenizerInfo: TokenizerInfo? = nil, namedGrammars: [String: NamedGrammar] = [:]) throws(GrammarError) {
        self.init(storage: try LarkConverter.convert(lark, tokenizer: tokenizerInfo, named: namedGrammars))
    }
}

extension GrammarCompiler {
    public func compile(lark: String, namedGrammars: [String: NamedGrammar] = [:]) throws(GrammarError) -> CompiledGrammar {
        let references = JSONValue.object(namedGrammars.keys.sorted().map { name in
            let source: String
            switch namedGrammars[name]! {
            case .grammar(let grammar): source = "ebnf:" + grammar.description
            case .lark(let lark): source = "lark:" + lark
            }
            return .init(key: name, value: .string(source))
        }).serialized()
        return try cached(.lark(lark, references: references)) { () throws(GrammarError) in
            try compileUncached(Grammar(lark: lark, tokenizerInfo: tokenizerInfo, namedGrammars: namedGrammars))
        }
    }
}

final class LarkConverter {
    private var builder = GrammarBuilder()
    private let document: LarkDocument
    private let tokenizer: TokenizerInfo?
    private let named: [String: NamedGrammar]
    private let referenceStack: [String]
    private let depth: Int
    private let source: String
    /// Upstream's terminal_mode: set while compiling terminals, plain lazy bodies and temperature rules.
    private var terminalMode = false
    private var definitions: [String: LarkDocument.Definition] = [:]
    private var imported: [String: Int32] = [:]
    private var skipRule: Int32?
    private var dynamicConsumedRules = Set<String>()

    private init(source: String, document: LarkDocument, tokenizer: TokenizerInfo?, named: [String: NamedGrammar], stack: [String], depth: Int) {
        self.source = source; self.document = document; self.tokenizer = tokenizer; self.named = named; referenceStack = stack; self.depth = depth
    }
    static func convert(_ source: String, tokenizer: TokenizerInfo?, named: [String: NamedGrammar], stack: [String] = [], depth: Int = 0) throws(GrammarError) -> GrammarStorage {
        guard depth < 200 else { throw .conversion("Lark subgrammar nesting exceeds 200 levels") }
        if stack.isEmpty, depth == 0 {
            for name in named.keys.sorted() {
                guard !name.isEmpty else { throw .invalidGrammar("Named grammar names must not be empty") }
                guard name.utf8.allSatisfy({ (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 95 || $0 == 45 }) else {
                    throw .invalidGrammar("Invalid named grammar name '\(name)': names may contain only letters, digits, underscores, and hyphens")
                }
            }
        }
        do {
            let converter = Self(source: source, document: try LarkParser.parse(source), tokenizer: tokenizer, named: named, stack: stack, depth: depth)
            return try converter.convert()
        } catch .lark(let message, let line, let column) {
            throw .lark(message: message + sourceContext(source, line: line, column: column), line: line, column: column)
        }
    }

    /// Upstream RaiseLarkError's suffix: the offending source line and a caret under the column.
    private static func sourceContext(_ source: String, line: Int, column: Int) -> String {
        let lines = source.utf8.split(separator: 10, omittingEmptySubsequences: false)
        guard line >= 1, line <= lines.count else { return "" }
        let text = String(decoding: lines[line - 1], as: UTF8.self)
        guard !text.isEmpty else { return "" }
        return "\n" + text + "\n" + String(repeating: " ", count: max(0, column - 1)) + "^"
    }

    /// Runs `body` as upstream's terminal_mode compilation.
    private func inTerminalMode<T>(_ body: () throws(GrammarError) -> T) throws(GrammarError) -> T {
        let saved = terminalMode
        terminalMode = true
        defer { terminalMode = saved }
        return try body()
    }
    private func error(_ message: String) -> GrammarError { .lark(message: message, line: 1, column: 1) }
    private func convert() throws(GrammarError) -> GrammarStorage {
        for definition in document.definitions {
            guard definitions[definition.name] == nil else { throw definition.location.error("duplicate rule or terminal '\(definition.name)'") }
            if definition.isTerminal, definition.attributes != RuleAttributes() || definition.marker != nil { throw definition.location.error("attributes are only supported on rules") }
            definitions[definition.name] = definition
            builder.addEmptyRule(name: definition.name)
        }
        guard let root = definitions["start"] else { throw error("no start rule found") }
        guard !root.isTerminal else { throw root.location.error("start must be a rule") }
        var terminalColors: [String: UInt8] = [:]
        func validate(_ name: String, depth: Int) throws(GrammarError) {
            let location = definitions[name]!.location
            guard depth < 200 else { throw location.error("terminal nesting exceeds 200 levels") }
            if terminalColors[name] == 1 { throw location.error("circular reference in terminal '\(name)'") }
            if terminalColors[name] == 2 { return }
            terminalColors[name] = 1
            for reference in references(definitions[name]!.body) {
                guard let target = definitions[reference] else { throw location.error("unknown name '\(reference)'") }
                guard target.isTerminal else { throw location.error("terminal '\(name)' cannot reference rule '\(reference)'") }
                try validate(reference, depth: depth + 1)
            }
            terminalColors[name] = 2
        }
        for definition in document.definitions where definition.isTerminal { try validate(definition.name, depth: 0) }
        if !document.ignores.isEmpty {
            let choices = try document.ignores.map { node throws(GrammarError) in try inTerminalMode { () throws(GrammarError) in try emit(node, terminal: true) } }
            let item = builder.addRule(hint: "lark_ignore_item", bodyExprID: builder.addChoices(choices))
            skipRule = builder.addRule(hint: "lark_ignore", bodyExprID: builder.addRepeat(ruleID: item, min: 0, max: -1))
        }
        let dynamicRoot = root.attributes.temperature == nil ? try dynamicStart(root) : nil
        for definition in document.definitions {
            let id = builder.ruleID(named: definition.name)!
            let attrs = definition.attributes
            let body: Int32
            var lazy = attrs.isLazy || definition.marker != nil
            var markerInfo = attrs.suffixStopInfo
            if dynamicConsumedRules.contains(definition.name) {
                // Upstream ignores max_chars here with a warning, but rejects budgets and captures
                // that the dispatch automaton could not honour.
                if let location = definition.maxTokensLocation {
                    throw location.error("max_tokens is not supported on rules consumed by dynamic dispatch")
                }
                if let location = definition.captureLocation {
                    throw location.error("capture is not supported on rules consumed by dynamic dispatch")
                }
                builder.updateRuleBody(id, builder.addEmptyString())
                continue
            } else if definition.name == "start", let dynamicRoot {
                if let location = definition.maxTokensLocation {
                    throw location.error("max_tokens is not supported on a dynamic dispatch start rule")
                }
                body = dynamicRoot; lazy = false
            } else if attrs.temperature != nil {
                body = try temperatureBody(definition)
            } else if definition.isTerminal {
                body = try inTerminalMode { () throws(GrammarError) in try emit(definition.body, terminal: true) }
            } else if let marker = definition.marker {
                let bodyPattern = try terminalPattern(definition.body), markerPattern = try terminalPattern(marker)
                let hiddenBytes: Int32
                if case .string(let text, _, _) = marker { hiddenBytes = Int32(text.utf8.count) } else { hiddenBytes = 1 }
                if definition.markerIsStop { markerInfo.hiddenStopBytes = hiddenBytes } else { markerInfo.hiddenSuffixBytes = hiddenBytes }
                if case .string = marker, attrs.maxTokens < 0, attrs.maxChars < 0 {
                    // Fixed markers can be trimmed without running a second automaton.
                } else {
                    markerInfo.bodyRuleID = builder.addRule(hint: definition.name + "_stop_body", bodyExprID: builder.addRegex(Array(bodyPattern.utf8)))
                    markerInfo.markerRuleID = builder.addRule(hint: definition.name + "_stop_marker", bodyExprID: builder.addRegex(Array(markerPattern.utf8)))
                }
                if let trigger = try lazyTrigger(definition) {
                    body = terminalDispatch(trigger); lazy = false
                } else { body = builder.addRegex(Array(("(?:" + bodyPattern + ")(?:" + markerPattern + ")").utf8)) }
            } else if attrs.isLazy, lazyRegexTrigger(definition.body) != nil {
                throw definition.location.error("lazy regex suffix is only supported on a head used by dynamic dispatch")
            } else if let trigger = try lazyTrigger(definition) {
                body = terminalDispatch(trigger); lazy = false
            } else if attrs.isLazy {
                // Swift flattens terminal composition into one regex FSM, so lazy bodies built from
                // terminals stay terminal-like; terminalPattern reports upstream's terminal-mode errors.
                body = builder.addRegex(Array(try terminalPattern(definition.body).utf8))
            } else {
                body = try emit(definition.body, terminal: definition.isTerminal || attrs.temperature != nil || !attrs.captureName.isEmpty || attrs.isLazy)
            }
            builder.updateRuleBody(id, body)
            let consumedByDispatch = definition.name == "start" && dynamicRoot != nil
            builder.updateMaxTokens(id, consumedByDispatch ? -1 : attrs.maxTokens); builder.updateMaxChars(id, consumedByDispatch ? -1 : attrs.maxChars)
            builder.updateCaptureName(id, attrs.captureName); builder.updateLazy(id, lazy)
            builder.updateTemperature(id, attrs.temperature)
            builder.updateSuffixStopInfo(id, markerInfo)
        }
        var rootID = builder.ruleID(named: "start")!
        if let skipRule {
            var parts = document.allowInitialSkip ? [builder.addRuleRef(skipRule)] : []
            parts.append(builder.addRuleRef(rootID))
            parts.append(builder.addRuleRef(skipRule))
            rootID = builder.addRule(hint: "start_with_skip", bodyExprID: builder.addSequence(parts))
        }
        return DeadCodeEliminator.apply(GrammarNormalizer.apply(builder.finish(rootRuleID: rootID)))
    }

    /// Upstream CompileTemperatureRule: a single subgrammar body is compiled as is; anything else
    /// must compile as a terminal.
    private func temperatureBody(_ definition: LarkDocument.Definition) throws(GrammarError) -> Int32 {
        var node = definition.body
        while case .sequence(let nodes) = node, nodes.count == 1 { node = nodes[0] }
        switch node {
        case .json, .nested, .reference: return try emit(node, terminal: true)
        default: break
        }
        do {
            return try inTerminalMode { () throws(GrammarError) in try emit(definition.body, terminal: true) }
        } catch {
            var text = error.description
            if case .lark(_, let line, let column) = error { text += Self.sourceContext(source, line: line, column: column) }
            throw definition.location.error(text + "; temperature is only supported on terminals and subgrammars")
        }
    }

    private enum Trigger { case text(String), tokens([Int32]) }

    private func isAnyText(_ node: LarkNode, visiting: Set<String> = []) -> Bool {
        switch node {
        case .regex(let source, let flags, _):
            guard flags.allSatisfy({ "isu".contains($0) }) else { return false }
            let pattern = source.filter { !" \t\r".contains($0) }
            if flags.contains("s") { return pattern == ".*" }
            return [#"(.|\n)*"#, #"(\n|.)*"#, #"(?:.|\n)*"#, #"(?:\n|.)*"#, #"[\s\S]*"#, "(?s:.*)"].contains(pattern)
        case .name(let name, _):
            guard !visiting.contains(name), visiting.count < 200, let definition = definitions[name] else { return false }
            return isAnyText(definition.body, visiting: visiting.union([name]))
        case .sequence(let nodes) where nodes.count == 1: return isAnyText(nodes[0], visiting: visiting)
        default: return false
        }
    }

    private func sequenceNodes(_ node: LarkNode) -> [LarkNode] {
        if case .sequence(let nodes) = node { return nodes }
        return [node]
    }

    private func tokenTrigger(_ source: String, at location: LarkLocation) throws(GrammarError) -> Trigger {
        let id = try special(source, at: location), value = builder.storage.expr(id)
        guard value.kind == .token else { throw error("a lazy/dynamic token trigger cannot be negated") }
        return .tokens(Array(value))
    }

    private func lazyTrigger(_ definition: LarkDocument.Definition) throws(GrammarError) -> Trigger? {
        if let marker = definition.marker {
            if isAnyText(definition.body), case .string(let text, let flags, _) = marker, flags.isEmpty { return .text(text) }
            return nil
        }
        guard definition.attributes.isLazy else { return nil }
        let nodes = sequenceNodes(definition.body)
        if nodes.count == 2, isAnyText(nodes[0]) {
            switch nodes[1] {
            case .string(let text, let flags, _) where !text.isEmpty && flags.isEmpty: return .text(text)
            case .special(let source, let location): return try tokenTrigger(source, at: location)
            default: break
            }
        }
        return lazyRegexTrigger(definition.body)
    }

    /// The literal suffix of a lazy `/(\n|.)*LITERAL/` head (upstream ExtractLazyRegexTrigger).
    private func lazyRegexTrigger(_ body: LarkNode) -> Trigger? {
        if case .regex(let pattern, let flags, _) = body, flags.allSatisfy({ "su".contains($0) }) {
            let prefixes = flags.contains("s") ? [".*"] : [#"(.|\n)*"#, #"(\n|.)*"#, #"(?:.|\n)*"#, #"(?:\n|.)*"#, #"[\s\S]*"#, "(?s:.*)"]
            for prefix in prefixes where pattern.hasPrefix(prefix) {
                if let literal = fixedRegexLiteral(String(pattern.dropFirst(prefix.count))), !literal.isEmpty { return .text(literal) }
            }
        }
        return nil
    }

    private func fixedRegexLiteral(_ pattern: String) -> String? {
        var result = "", escaped = false
        for scalar in pattern.unicodeScalars {
            if escaped {
                if scalar == "n" { result += "\n" }
                else if scalar == "r" { result += "\r" }
                else if scalar == "t" { result += "\t" }
                else if ".^$*+?{}[]\\|()/".unicodeScalars.contains(scalar) { result.unicodeScalars.append(scalar) }
                else { return nil }
                escaped = false
            } else if scalar == "\\" { escaped = true }
            else if ".^$*+?{}[]|()".unicodeScalars.contains(scalar) { return nil }
            else { result.unicodeScalars.append(scalar) }
        }
        return escaped ? nil : result
    }

    private func terminalDispatch(_ trigger: Trigger) -> Int32 {
        let end = builder.addRule(hint: "lark_lazy_end", bodyExprID: builder.addEmptyString())
        switch trigger {
        case .text(let text): return builder.addTagDispatch(.init(tagRulePairs: [(Array(text.utf8), end)], loopAfterDispatch: false))
        case .tokens(let ids): return builder.addTokenTagDispatch(.init(triggerRulePairs: ids.map { ($0, end) }, loopAfterDispatch: false))
        }
    }

    /// Rewrites `start: (tool | other)* tail` into a deterministic dispatch automaton. Once a
    /// complete opener is seen, its payload grammar is mandatory; the free-text tail cannot
    /// swallow a malformed tool call through an alternative Earley branch.
    private func dynamicStart(_ start: LarkDocument.Definition) throws(GrammarError) -> Int32? {
        let root = sequenceNodes(start.body)
        guard root.count == 2, case .repeatNode(let repeated, minimum: 0, maximum: -1) = root[0],
              case .name(let tail, _) = root[1], let tailDefinition = definitions[tail], isAnyText(tailDefinition.body) else { return nil }
        let choices: [LarkNode]
        if case .choice(let nodes) = repeated { choices = nodes } else { choices = [repeated] }
        var alternatives: [(Trigger, LarkNode, LarkDocument.Definition?)] = []
        var consumed: Set<String> = [tail]
        for choice in choices {
            guard case .name(let tool, _) = choice, let definition = definitions[tool], !definition.isTerminal else { return nil }
            let nodes = sequenceNodes(definition.body)
            guard let first = nodes.first else { return nil }
            var trigger: Trigger?, head: LarkDocument.Definition?, begin = 1
            if case .name(let name, _) = first, let candidate = definitions[name] {
                trigger = try lazyTrigger(candidate)
                if trigger != nil { consumed.insert(name); head = candidate }
            }
            if trigger == nil, nodes.count > 1, isAnyText(first), case .special(let token, let location) = nodes[1] {
                trigger = try tokenTrigger(token, at: location); begin = 2
            }
            guard let trigger else { return nil }
            consumed.insert(tool)
            alternatives.append((trigger, .sequence(Array(nodes.dropFirst(begin))), head))
        }
        guard !alternatives.isEmpty else { return nil }
        guard alternatives.allSatisfy({ references($0.1).allSatisfy { !consumed.contains($0) } }) else { return nil }
        var textOrder: [String] = [], textGroups: [String: [Int32]] = [:]
        var tokenOrder: [Int32] = [], tokenGroups: [Int32: [Int32]] = [:]
        for (trigger, remainder, head) in alternatives {
            var body = try emit(remainder, terminal: false)
            switch trigger {
            case .text(let text):
                if let head, head.markerIsStop || !head.attributes.stopCaptureName.isEmpty {
                    let event = builder.addRule(hint: head.name + "_dynamic_marker", bodyExprID: builder.addEmptyString())
                    let marker = builder.addRule(hint: head.name + "_dynamic_marker_text", bodyExprID: builder.addByteString(text))
                    var info = SuffixStopInfo()
                    info.bodyRuleID = event; info.markerRuleID = marker; info.stopCaptureName = head.attributes.stopCaptureName
                    if head.markerIsStop { info.hiddenStopBytes = Int32(text.utf8.count) } else { info.hiddenSuffixBytes = Int32(text.utf8.count) }
                    builder.updateSuffixStopInfo(event, info)
                    body = builder.addSequence([builder.addRuleRef(event), body])
                }
                if textGroups[text] == nil { textOrder.append(text) }
                textGroups[text, default: []].append(body)
            case .tokens(let ids):
                for id in ids {
                    if tokenGroups[id] == nil { tokenOrder.append(id) }
                    tokenGroups[id, default: []].append(body)
                }
            }
        }
        guard textOrder.isEmpty || tokenOrder.isEmpty else { throw error("a dynamic start cannot mix string and token triggers") }
        dynamicConsumedRules = consumed
        if !textOrder.isEmpty {
            let pairs = textOrder.map { text in (Array(text.utf8), builder.addRule(hint: "lark_dynamic_body", bodyExprID: builder.addChoices(textGroups[text]!))) }
            return builder.addTagDispatch(.init(tagRulePairs: pairs, loopAfterDispatch: true))
        }
        let pairs = tokenOrder.map { token in (token, builder.addRule(hint: "lark_dynamic_body", bodyExprID: builder.addChoices(tokenGroups[token]!))) }
        return builder.addTokenTagDispatch(.init(triggerRulePairs: pairs, loopAfterDispatch: true))
    }

    /// Terminal composition is flattened into a regex for committed-shortest marker matching.
    /// Keeping the body and marker in one FSM preserves the first valid completion boundary.
    private func terminalPattern(_ node: LarkNode, depth: Int = 0) throws(GrammarError) -> String {
        guard depth < 200 else { throw error("terminal nesting exceeds 200 levels") }
        func escaped(_ text: String) -> String {
            text.unicodeScalars.map { scalar in
                if scalar.value < 32 {
                    let hex = String(scalar.value, radix: 16)
                    return "\\x" + (hex.count == 1 ? "0" : "") + hex
                }
                return (".^$*+?{}[]\\|()".unicodeScalars.contains(scalar) ? "\\" : "") + String(scalar)
            }.joined()
        }
        switch node {
        case .string(let text, let flags, let location):
            guard flags.isEmpty || flags == "i" else { throw location.error("unsupported string literal flags '\(flags)'") }
            guard flags.isEmpty || text.unicodeScalars.allSatisfy({ $0.value < 128 }) else { throw location.error("case-insensitive string literals currently support ASCII characters only") }
            if flags.isEmpty { return escaped(text) }
            return text.utf8.map { byte in
                if (65 ... 90).contains(byte) || (97 ... 122).contains(byte) { return "[" + String(UnicodeScalar(byte | 32)) + String(UnicodeScalar((byte | 32) - 32)) + "]" }
                return escaped(String(UnicodeScalar(byte)))
            }.joined()
        case .regex(let source, let flags, let location):
            try validateRegexFlags(flags, location)
            guard !flags.contains("i") else { throw location.error("regular-expression flag 'i' is not supported with suffix or stop attributes") }
            return "(?:" + RegexFSMBuilder.rewriteDots(source, dotMatchesNewline: flags.contains("s")) + ")"
        case .range(let lower, let upper):
            func endpoint(_ cp: Int32) -> String {
                let value = String(UnicodeScalar(UInt32(cp))!)
                return "\\]-^".contains(value) ? "\\" + value : value
            }
            return "[" + endpoint(lower) + "-" + endpoint(upper) + "]"
        case .sequence(let nodes): return try nodes.map { node throws(GrammarError) in "(?:" + (try terminalPattern(node, depth: depth + 1)) + ")" }.joined()
        case .choice(let nodes): return "(?:" + (try nodes.map { node throws(GrammarError) in try terminalPattern(node, depth: depth + 1) }).joined(separator: "|") + ")"
        case .repeatNode(let node, let min, let max):
            let suffix = min == 0 && max == -1 ? "*" : min == 1 && max == -1 ? "+" : "{\(min)" + (max == min ? "}" : "," + (max == -1 ? "" : String(max)) + "}")
            return "(?:" + (try terminalPattern(node, depth: depth + 1)) + ")" + suffix
        case .name(let name, let location):
            guard let definition = definitions[name] else { throw location.error("unknown name '\(name)'") }
            guard definition.isTerminal else { throw location.error("terminal cannot reference rule '\(name)'") }
            return try terminalPattern(definition.body, depth: depth + 1)
        case .special(_, let location): throw location.error("special tokens cannot be used in terminals")
        case .json(_, let location): throw location.error("%json cannot be used in terminals")
        case .nested(_, let location): throw location.error("nested %lark cannot be used in terminals")
        case .structuredRegex(_, let location): throw location.error("structured %regex cannot be used with suffix or stop")
        case .reference(_, let location): throw location.error("named grammars cannot be used in terminals")
        }
    }

    private func references(_ node: LarkNode) -> [String] {
        switch node {
        case .name(let name, _): [name]
        case .sequence(let nodes), .choice(let nodes): nodes.flatMap(references)
        case .repeatNode(let node, _, _): references(node)
        default: []
        }
    }
    private func lexical(_ expression: Int32, terminal: Bool) -> Int32 {
        guard !terminal, let skipRule else { return expression }
        return builder.addSequence([expression, builder.addRuleRef(skipRule)])
    }
    private func validateRegexFlags(_ flags: String, _ location: LarkLocation) throws(GrammarError) {
        for flag in flags where !"isu".contains(flag) { throw location.error("regular-expression flag '\(flag)' is not supported") }
    }
    private func emit(_ node: LarkNode, terminal: Bool) throws(GrammarError) -> Int32 {
        switch node {
        case .string(let text, let flags, let location):
            guard flags.isEmpty || flags == "i" else { throw location.error("unsupported string literal flags '\(flags)'") }
            var expression: Int32
            if flags == "i" {
                guard text.unicodeScalars.allSatisfy({ $0.value < 128 }) else { throw location.error("case-insensitive string literals currently support ASCII characters only") }
                expression = builder.addSequence(text.utf8.map { byte in
                    if (65 ... 90).contains(byte) || (97 ... 122).contains(byte) {
                        let lower = Int32(byte | 32), upper = lower - 32
                        return builder.addCharacterClass([upper ... upper, lower ... lower])
                    }
                    return builder.addByteString([byte])
                })
            } else { expression = text.isEmpty ? builder.addEmptyString() : builder.addByteString(text) }
            return lexical(expression, terminal: terminal || text.isEmpty)
        case .regex(let source, let flags, let location):
            try validateRegexFlags(flags, location)
            var pattern = RegexFSMBuilder.rewriteDots(source, dotMatchesNewline: flags.contains("s"))
            if flags.contains("i") { pattern = "(?i)" + pattern }
            do { _ = try RegexFSMBuilder.matchesEmpty(Array(pattern.utf8)) } catch {
                throw location.error("failed to compile regular expression: \(error.message)")
            }
            return lexical(builder.addRegex(Array(pattern.utf8)), terminal: terminal)
        case .range(let lower, let upper): return lexical(builder.addCharacterClass([lower ... upper]), terminal: terminal)
        case .name(let name, let location):
            guard let definition = definitions[name] else { throw location.error("unknown name '\(name)'") }
            if terminalMode, !definition.isTerminal { throw location.error("terminal cannot reference rule '\(name)'") }
            let reference = builder.addRuleRef(builder.ruleID(named: name)!)
            return lexical(reference, terminal: terminal || (!definition.isTerminal && definition.attributes.temperature == nil && definition.attributes.captureName.isEmpty && !definition.attributes.isLazy && definition.marker == nil))
        case .sequence(let nodes): return builder.addSequence(try nodes.map { node throws(GrammarError) in try emit(node, terminal: terminal) })
        case .choice(let nodes): return builder.addChoices(try nodes.map { node throws(GrammarError) in try emit(node, terminal: terminal) })
        case .repeatNode(let node, let min, let max): return builder.addRepeat(exprID: try emit(node, terminal: terminal), min: min, max: max, nameHint: "lark_repeat")
        case .special(let token, let location):
            if terminalMode { throw location.error("special tokens cannot be used in terminals") }
            return lexical(try special(token, at: location), terminal: terminal)
        case .reference(let name, let location):
            if terminalMode { throw location.error("named grammars cannot be used in terminals") }
            if let id = imported[name] { return lexical(builder.addRuleRef(id), terminal: terminal) }
            guard !referenceStack.contains(name) else { throw location.error("circular named grammar reference: " + (referenceStack + [name]).map { "@" + $0 }.joined(separator: " -> ")) }
            guard let grammar = named[name] else { throw location.error("unknown named grammar '@\(name)'") }
            let storage: GrammarStorage
            switch grammar {
            case .grammar(let grammar): storage = grammar.storage
            case .lark(let source):
                do { storage = try Self.convert(source, tokenizer: tokenizer, named: named, stack: referenceStack + [name], depth: depth + 1) }
                catch { throw location.error("failed to compile named grammar '@\(name)': \(error)") }
            }
            let id = builder.importGrammar(storage)
            imported[name] = id
            return lexical(builder.addRuleRef(id), terminal: terminal)
        case .json(let source, let location):
            if terminalMode { throw location.error("%json cannot be used in terminals") }
            let storage: GrammarStorage
            do { storage = try JSONSchemaConverter.convert(JSONSchema(json: source), options: .init(anyWhitespace: true)) }
            catch { throw location.error("failed to compile inline JSON schema: \(error)") }
            return lexical(builder.addRuleRef(builder.importGrammar(storage)), terminal: terminal)
        case .nested(let source, let location):
            if terminalMode { throw location.error("nested %lark cannot be used in terminals") }
            let storage: GrammarStorage
            do { storage = try Self.convert(source, tokenizer: tokenizer, named: named, stack: referenceStack, depth: depth + 1) }
            catch { throw location.error("failed to compile nested Lark grammar: \(error)") }
            return lexical(builder.addRuleRef(builder.importGrammar(storage)), terminal: terminal)
        case .structuredRegex(let source, let location):
            let value: JSONValue
            do { value = try JSONValue.parse(source) } catch { throw location.error("failed to parse %regex: \(error.message)") }
            guard let members = value.members else { throw location.error("%regex value must be an object") }
            for member in members.sorted(by: { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) })
            where !["substring_chunks", "substring_chars", "substring_words"].contains(member.key) {
                throw location.error("unknown field '\(member.key)' in %regex")
            }
            let fields = members.filter { $0.value != .null }
            guard !fields.isEmpty else { throw location.error("no fields set on %regex") }
            guard fields.count == 1 else { throw location.error("only one field can be set on %regex") }
            let field = fields[0], chunks: [[UInt8]]
            switch field.key {
            case "substring_chars":
                guard let text = field.value.string else { throw location.error("substring_chars must be a string") }
                chunks = text.unicodeScalars.map { Array(String($0).utf8) }
            case "substring_chunks":
                guard let values = field.value.array, values.allSatisfy({ $0.string != nil }) else { throw location.error("substring_chunks must be an array of strings") }
                chunks = values.map { Array($0.string!.utf8) }
            default:
                guard field.value.string != nil else { throw location.error("substring_words must be a string") }
                throw location.error("substring_words is not supported yet")
            }
            let id = builder.addRule(hint: "lark_substring", bodyExprID: builder.addSubstring(chunks))
            return lexical(builder.addRuleRef(id), terminal: terminal)
        }
    }

    /// Upstream ResolveSpecialToken: syntax is validated first, the tokenizer is only needed for
    /// wildcards and named tokens.
    private func special(_ token: String, at location: LarkLocation) throws(GrammarError) -> Int32 {
        if token.utf8.count >= 4, token.hasPrefix("<["), token.hasSuffix("]>") {
            var contents = String(token.dropFirst(2).dropLast(2))
            var excluded = false
            if contents.hasPrefix("^") { excluded = true; contents.removeFirst() }
            if contents == "*" {
                guard !excluded else { throw location.error("negated wildcard special token is not supported") }
                guard tokenizer != nil else { throw location.error("wildcard special token requires tokenizer_info") }
                return builder.addExcludeTokenSet([])
            }
            guard !contents.contains("*") else { throw location.error("wildcard cannot be mixed with token ranges") }
            var ids = Set<Int32>()
            for part in contents.split(separator: ",", omittingEmptySubsequences: false) {
                let range = part.trimmingCharacters(in: .whitespaces)
                guard !range.isEmpty else { continue }
                let bounds = range.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                let invalid = location.error("invalid numeric special-token range '\(range)'")
                guard bounds.count == 1 || !bounds[1].contains("-") else { throw invalid }
                guard let first = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
                      let last = bounds.count == 1 ? first : Int64(bounds[1].trimmingCharacters(in: .whitespaces)) else { throw invalid }
                guard first >= 0, last >= first, last <= Int64(Int32.max) else { throw invalid }
                guard last - first <= 1_000_000 else { throw location.error("special-token range is too large") }
                if let tokenizer, last >= Int64(tokenizer.vocabSize) { throw invalid }
                for id in first ... last { ids.insert(Int32(id)) }
            }
            guard !ids.isEmpty else { throw location.error("empty numeric special-token range") }
            return excluded ? builder.addExcludeTokenSet(ids.sorted()) : builder.addTokenSet(ids.sorted())
        }
        guard let tokenizer else { throw location.error("named special token \(token) requires tokenizer_info") }
        let bytes = Array(token.utf8)
        let ids = tokenizer.tokenIDs(forPiece: bytes)
        guard !ids.isEmpty else { throw location.error("unknown special token \(token)") }
        return builder.addTokenSet(ids)
    }
}
