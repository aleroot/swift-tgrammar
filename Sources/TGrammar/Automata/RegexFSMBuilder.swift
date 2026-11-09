// Compiles a regular expression into an automaton over UTF-8 bytes. The pattern is parsed into
// a small IR (`RegexNode`) and then lowered with the FSM operators. Large bounded repetitions
// can be delegated to grammar rules (counted repeat edges) through `makeRepeatRule` so the
// automaton is never unrolled.

/// A code point range, inclusive.
typealias CodepointRange = ClosedRange<UInt32>

/// Builder for regex automata.
struct RegexFSMBuilder {
    /// Bounded repetitions above this threshold are compiled into a repeat edge (when a rule
    /// factory is available) instead of being unrolled. Matches `RepetitionRangeExpander`.
    static let largeRepeatThreshold = 128
    /// Hard cap of the estimated state count when a bounded repetition must be unrolled.
    static let maxUnrolledRepeatStates = 100_000
    static let maxCodepoint: UInt32 = 0x10FFFF

    /// Creates a rule (named after the hint) whose body is the regex given as bytes, marks it
    /// as an exact-lookahead rule and returns its id.
    typealias RepeatRuleFactory = (_ hint: String, _ regex: [UInt8]) -> Int32

    /// Builds the automaton for `regex`. A leading `(?i)` makes the match ASCII case-insensitive.
    static func build(_ regex: String, makeRepeatRule: RepeatRuleFactory? = nil, ruleHint: String = "") throws(GrammarError) -> FSMWithStartEnd {
        try build(Array(regex.utf8), makeRepeatRule: makeRepeatRule, ruleHint: ruleHint)
    }

    static func build(_ regex: [UInt8], makeRepeatRule: RepeatRuleFactory? = nil, ruleHint: String = "") throws(GrammarError) -> FSMWithStartEnd {
        if let memoized = automata.value(for: regex) { return memoized }
        let ir = try RegexParser(regex: regex, makeRepeatRule: makeRepeatRule, ruleHint: ruleHint).parse()
        let built = try ir.build()
        // Without large repetitions the automaton depends on the pattern alone: the rule factory
        // is never consulted. Lowering is pure, and converters emit the same patterns (the JSON
        // string body, above all) in grammar after grammar and several times within one.
        if !ir.nodes.contains(where: \.containsLargeRepetition) { automata.insert(built, for: regex) }
        return built
    }

    /// Automata of patterns without large repetitions, shared by every compilation.
    static let automata = BoundedMemo<[UInt8], FSMWithStartEnd>(capacity: 256)

    /// Builds the automaton, then removes `forbidden` bytes from every byte transition. The
    /// result accepts the intersection of the regex language and strings free of those bytes.
    static func build(_ regex: [UInt8], forbidding forbidden: ByteSet, makeRepeatRule: RepeatRuleFactory? = nil, ruleHint: String = "") throws(GrammarError) -> FSMWithStartEnd {
        let built = try build(regex, makeRepeatRule: makeRepeatRule, ruleHint: ruleHint)
        if forbidden.isEmpty { return built }
        var fsm = FSM(stateCount: built.stateCount)
        for state in 0 ..< Int32(built.stateCount) {
            for edge in built.fsm.edges(of: state) {
                guard edge.isCharRange else {
                    fsm.addEdge(from: state, to: edge.target, min: edge.min, max: edge.max)
                    continue
                }
                var rangeStart: Int32 = -1
                var value = edge.min
                while value <= edge.max &+ 1 {
                    if value <= edge.max, !forbidden.contains(value) {
                        if rangeStart == -1 { rangeStart = value }
                    } else if rangeStart != -1 {
                        fsm.addEdge(from: state, to: edge.target, min: rangeStart, max: value &- 1)
                        rangeStart = -1
                    }
                    value &+= 1
                }
            }
        }
        fsm.auxData = built.fsm.auxData
        return FSMWithStartEnd(fsm: fsm, start: built.start, ends: built.ends)
    }

    /// Whether the regex matches the empty string. Only parses; no automaton is built.
    /// Memoized like ``automata``: the optimizer asks for every regex rule, the same patterns
    /// recur within and across grammars, and parsing one (then freeing its tree) costs more than
    /// the rest of the question.
    static func matchesEmpty(_ regex: [UInt8]) throws(GrammarError) -> Bool {
        if let known = nullablePatterns.value(for: regex) { return known }
        let ir = try RegexParser(regex: regex, makeRepeatRule: nil, ruleHint: "").parse()
        let nullable = RegexNode.isNullable(sequence: ir.nodes)
        nullablePatterns.insert(nullable, for: regex)
        return nullable
    }

    /// Whether each recently seen pattern matches the empty string.
    static let nullablePatterns = BoundedMemo<[UInt8], Bool>(capacity: 1024)

    /// Rewrites every unescaped `.` outside character classes to `[^\n]` unless
    /// `dotMatchesNewline` is set (standard regex dot semantics; the engine's `.` matches every
    /// code point).
    static func rewriteDots(_ pattern: String, dotMatchesNewline: Bool) -> String {
        if dotMatchesNewline { return pattern }
        var result = ""
        result.reserveCapacity(pattern.utf8.count)
        var escaped = false
        var inClass = false
        for scalar in pattern.unicodeScalars {
            if escaped {
                result.unicodeScalars.append(scalar)
                escaped = false
                continue
            }
            switch scalar {
            case "\\":
                result.unicodeScalars.append(scalar)
                escaped = true
            case "[":
                result.unicodeScalars.append(scalar)
                inClass = true
            case "]" where inClass:
                result.unicodeScalars.append(scalar)
                inClass = false
            case "." where !inClass:
                result += "[^\\n]"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

// MARK: - Code point range utilities

enum CodepointRanges {
    /// Sorts the ranges and merges overlapping or adjacent ones.
    static func normalize(_ ranges: inout [CodepointRange]) {
        ranges.sort { $0.lowerBound != $1.lowerBound ? $0.lowerBound < $1.lowerBound : $0.upperBound < $1.upperBound }
        var result: [CodepointRange] = []
        result.reserveCapacity(ranges.count)
        for range in ranges {
            if let last = result.last, range.lowerBound <= last.upperBound &+ 1, range.lowerBound >= last.lowerBound {
                result[result.count &- 1] = last.lowerBound ... max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        ranges = result
    }

    /// Complement of normalized ranges over `[0, maxCodepoint]`.
    static func complement(_ ranges: [CodepointRange]) -> [CodepointRange] {
        var result: [CodepointRange] = []
        var next: UInt32 = 0
        for range in ranges {
            if range.lowerBound > next { result.append(next ... range.lowerBound &- 1) }
            if range.upperBound >= RegexFSMBuilder.maxCodepoint { return result }
            next = max(next, range.upperBound &+ 1)
        }
        result.append(next ... RegexFSMBuilder.maxCodepoint)
        return result
    }

    /// Appends the ASCII case-folded counterpart of every letter contained in the ranges.
    static func foldASCIICase(_ ranges: inout [CodepointRange]) {
        let a = UInt32(UInt8(ascii: "a")), z = UInt32(UInt8(ascii: "z"))
        let upperA = UInt32(UInt8(ascii: "A")), upperZ = UInt32(UInt8(ascii: "Z"))
        let delta = a - upperA
        for index in 0 ..< ranges.count {
            let low = ranges[index].lowerBound
            let high = ranges[index].upperBound
            var foldLow = max(low, a)
            var foldHigh = min(high, z)
            if foldLow <= foldHigh { ranges.append((foldLow - delta) ... (foldHigh - delta)) }
            foldLow = max(low, upperA)
            foldHigh = min(high, upperZ)
            if foldLow <= foldHigh { ranges.append((foldLow + delta) ... (foldHigh + delta)) }
        }
    }

    /// Adds edges `from → to` accepting the UTF-8 encoding of every code point in the ranges.
    static func addEdges(_ fsm: inout FSM, from: Int32, to: Int32, ranges: [CodepointRange]) {
        for range in ranges {
            if range.lowerBound <= UTF8Ranges.max1Byte {
                fsm.addEdge(from: from, to: to, min: Int32(range.lowerBound), max: Int32(min(range.upperBound, UTF8Ranges.max1Byte)))
            }
            if range.upperBound > UTF8Ranges.max1Byte {
                // Split by encoded width first: a packed range spanning widths would start the
                // wider part at its smallest byte pattern (E0 80 80, F0 80 80 80), which are
                // overlong encodings.
                let multiByteLow = max(range.lowerBound, UTF8Ranges.max1Byte &+ 1)
                UTF8Ranges.addCodepointRangeEdges(&fsm, from: from, to: to, low: multiByteLow, high: range.upperBound)
            }
        }
    }
}

// MARK: - IR

/// One node of the parsed regex.
indirect enum RegexNode {
    enum Quantifier { case star, plus, optional }

    /// The empty string, a character class `[...]`, or a single literal / escape.
    case leaf([UInt8])
    case quantified(Quantifier, RegexNode)
    case union([RegexNode])
    case group([RegexNode])
    case `repeat`(RegexNode, lower: Int, upper: Int)
    /// A grammar rule reference, lowered to a rule edge.
    case ruleRef(Int32)
    /// A counted repetition of a grammar rule, lowered to a repeat edge.
    case repeatRule(Int32, lower: Int, upper: Int)

    static let noUpperBound = -1

    /// Whether lowering depends on the repeat-rule factory: a bounded repetition above
    /// ``RegexFSMBuilder/largeRepeatThreshold`` (unrolled without a factory) or the rules a
    /// factory already created.
    var containsLargeRepetition: Bool {
        switch self {
        case .leaf: false
        case let .quantified(_, child): child.containsLargeRepetition
        case let .union(children), let .group(children): children.contains(where: \.containsLargeRepetition)
        case let .repeat(child, lower, upper):
            (upper == Self.noUpperBound ? lower : upper) > RegexFSMBuilder.largeRepeatThreshold || child.containsLargeRepetition
        case .ruleRef, .repeatRule: true
        }
    }

    static func isNullable(sequence: [RegexNode]) -> Bool { sequence.allSatisfy(isNullable) }

    static func isNullable(_ node: RegexNode) -> Bool {
        switch node {
        case let .leaf(bytes): bytes.isEmpty
        case let .quantified(quantifier, child): quantifier != .plus || isNullable(child)
        case let .union(children): children.contains(where: isNullable)
        case let .group(children): isNullable(sequence: children)
        case let .repeat(child, lower, _): lower == 0 || isNullable(child)
        case .ruleRef: false
        case let .repeatRule(_, lower, _): lower == 0
        }
    }
}

/// The parsed pattern: a top-level sequence plus flags.
struct RegexIR {
    var nodes: [RegexNode] = []
    var caseInsensitive = false

    func build() throws(GrammarError) -> FSMWithStartEnd {
        if nodes.isEmpty { return FSMWithStartEnd(fsm: FSM(stateCount: 1), start: 0, ends: [0]) }
        var parts: [FSMWithStartEnd] = []
        parts.reserveCapacity(nodes.count)
        for node in nodes { parts.append(try visit(node)) }
        return parts.count > 1 ? .concat(parts) : parts[0]
    }

    private func visit(_ node: RegexNode) throws(GrammarError) -> FSMWithStartEnd {
        switch node {
        case let .leaf(bytes):
            return try buildLeaf(bytes)
        case let .union(children):
            var parts: [FSMWithStartEnd] = []
            parts.reserveCapacity(children.count)
            for child in children { parts.append(try visit(child)) }
            guard parts.count > 1 else { throw .conversion("Internal error: a union node in the regex IR has fewer than two branches") }
            return .union(parts)
        case let .quantified(quantifier, child):
            let built = try visit(child)
            switch quantifier {
            case .plus: return built.plus()
            case .star: return built.star()
            case .optional: return built.optional()
            }
        case let .group(children):
            if children.isEmpty { return FSMWithStartEnd(fsm: FSM(stateCount: 1), start: 0, ends: [0]) }
            var parts: [FSMWithStartEnd] = []
            parts.reserveCapacity(children.count)
            for child in children { parts.append(try visit(child)) }
            return .concat(parts)
        case let .ruleRef(ruleID):
            var fsm = FSM(stateCount: 2)
            fsm.addRuleEdge(from: 0, to: 1, ruleID: ruleID)
            return FSMWithStartEnd(fsm: fsm, start: 0, ends: [1])
        case let .repeatRule(ruleID, lower, upper):
            // Pad the repeat edge with epsilon transitions on both sides so that compositions
            // never add another outgoing edge to its source state.
            var fsm = FSM(stateCount: 4)
            fsm.addEpsilonEdge(from: 0, to: 1)
            fsm.addRepeatEdge(from: 1, to: 2, ruleID: ruleID, lower: Int32(lower), upper: Int32(upper))
            fsm.addEpsilonEdge(from: 2, to: 3)
            return FSMWithStartEnd(fsm: fsm, start: 0, ends: [3])
        case let .repeat(child, lower, upper):
            return try buildRepeat(child, lower: lower, upper: upper)
        }
    }

    private func buildRepeat(_ child: RegexNode, lower: Int, upper: Int) throws(GrammarError) -> FSMWithStartEnd {
        let hasUpper = upper != RegexNode.noUpperBound
        if hasUpper, upper == 0 {
            // {0}: exactly the empty string.
            return FSMWithStartEnd(fsm: FSM(stateCount: 1), start: 0, ends: [0])
        }
        let built = try visit(child)
        let copies = hasUpper ? upper : max(lower, 1)
        if built.stateCount * copies > RegexFSMBuilder.maxUnrolledRepeatStates {
            throw .conversion("The bounded repetition {\(lower),\(hasUpper ? String(upper) : "")} is too large to compile into a FSM")
        }

        var result = built
        var newEnds = Set<Int32>()
        if lower <= 1, !hasUpper || upper >= 1 {
            for end in 0 ..< Int32(result.stateCount) where result.isEndState(end) { newEnds.insert(end) }
        }

        func allowZeroRepetitions(_ fsm: inout FSMWithStartEnd) {
            // A fresh accepting start is required: making the original start accepting would
            // also accept strings that merely loop back to it inside the first copy.
            let newStart = fsm.addState()
            fsm.fsm.addEpsilonEdge(from: newStart, to: fsm.start)
            fsm.start = newStart
            fsm.addEndState(newStart)
        }

        if !hasUpper {
            var count = 2
            while count < lower {
                result = .concat([result, built])
                count += 1
            }
            var lowerBoundEnd: Int32 = -1
            for end in 0 ..< Int32(result.stateCount) where result.isEndState(end) {
                lowerBoundEnd = end
                break
            }
            assert(lowerBoundEnd != -1, "No end state found in the lower bound FSM.")
            result = .concat([result, built])
            for end in 0 ..< Int32(result.stateCount) where result.isEndState(end) {
                result.fsm.addEpsilonEdge(from: end, to: lowerBoundEnd)
            }
            for end in newEnds.sorted() { result.addEndState(end) }
            if lower == 0 { allowZeroRepetitions(&result) }
            return result
        }

        if upper >= 2 {
            for count in 2 ... upper {
                result = .concat([result, built])
                if count >= lower {
                    for end in 0 ..< Int32(result.stateCount) where result.isEndState(end) { newEnds.insert(end) }
                }
            }
        }
        for end in newEnds.sorted() { result.addEndState(end) }
        if lower == 0 { allowZeroRepetitions(&result) }
        return result
    }

    /// Adds the transitions accepting one code point (with ASCII case folding when enabled)
    /// from `current` to a new state, returning that state.
    private func addSingleCodepoint(_ result: inout FSMWithStartEnd, from current: Int32, _ codepoint: UInt32) -> Int32 {
        let next = result.addState()
        if codepoint <= UTF8Ranges.max1Byte {
            let value = Int32(codepoint)
            result.fsm.addEdge(from: current, to: next, min: value, max: value)
            if caseInsensitive {
                if codepoint >= 0x61, codepoint <= 0x7A {
                    let upper = value - 0x20
                    result.fsm.addEdge(from: current, to: next, min: upper, max: upper)
                } else if codepoint >= 0x41, codepoint <= 0x5A {
                    let lower = value + 0x20
                    result.fsm.addEdge(from: current, to: next, min: lower, max: lower)
                }
            }
            return next
        }
        let bytes = UTF8Codec.encode(Codepoint(bitPattern: codepoint))
        var state = current
        for (index, byte) in bytes.enumerated() {
            let target = index + 1 == bytes.count ? next : result.addState()
            result.fsm.addEdge(from: state, to: target, min: Int32(byte), max: Int32(byte))
            state = target
        }
        return next
    }

    /// A leaf is the empty string, a character class, or a short sequence of literals/escapes.
    private func buildLeaf(_ regex: [UInt8]) throws(GrammarError) -> FSMWithStartEnd {
        var result = FSMWithStartEnd(fsm: FSM(stateCount: 1), start: 0, ends: [])
        if regex.isEmpty {
            result.addEndState(0)
            return result
        }
        if regex[0] == UInt8(ascii: "[") {
            let ranges = try RegexEscapes.parseCharacterClass(regex, caseInsensitive: caseInsensitive)
            let end = result.addState()
            CodepointRanges.addEdges(&result.fsm, from: 0, to: end, ranges: ranges)
            result.addEndState(end)
            return result
        }
        var current: Int32 = 0
        var position = 0
        try regex.withUnsafeBufferPointer { (buffer) throws(GrammarError) in
            while position < buffer.count {
                let byte = buffer[position]
                if byte == UInt8(ascii: ".") {
                    position += 1
                    let next = result.addState()
                    CodepointRanges.addEdges(&result.fsm, from: current, to: next, ranges: [0 ... RegexFSMBuilder.maxCodepoint])
                    current = next
                    continue
                }
                if byte == UInt8(ascii: "\\") {
                    let item = try RegexEscapes.parseEscape(buffer, at: &position, inClass: false)
                    switch item {
                    case let .single(codepoint):
                        current = addSingleCodepoint(&result, from: current, codepoint)
                    case .classRanges(var ranges, let negated):
                        if caseInsensitive { CodepointRanges.foldASCIICase(&ranges) }
                        CodepointRanges.normalize(&ranges)
                        if negated { ranges = CodepointRanges.complement(ranges) }
                        let next = result.addState()
                        CodepointRanges.addEdges(&result.fsm, from: current, to: next, ranges: ranges)
                        current = next
                    }
                    continue
                }
                let (codepoint, length) = UTF8Codec.decode(buffer, at: position)
                if codepoint == UTF8Codec.invalid {
                    // Be permissive with non-UTF-8 patterns: match the raw byte.
                    let next = result.addState()
                    result.fsm.addEdge(from: current, to: next, min: Int32(byte), max: Int32(byte))
                    current = next
                    position += 1
                    continue
                }
                current = addSingleCodepoint(&result, from: current, UInt32(codepoint))
                position += length
            }
        }
        result.addEndState(current)
        return result
    }
}

// MARK: - Escapes and character classes

enum RegexEscapes {
    /// One parsed escape (or literal).
    enum Item {
        case single(UInt32)
        /// Class escapes such as `\d`, `\W`: a (possibly negated) set of ranges.
        case classRanges([CodepointRange], negated: Bool)
    }

    /// Parses the escape sequence starting with the backslash at `position`, advancing past it.
    /// Inside a class, `\b` is the backspace character instead of a word-boundary assertion.
    static func parseEscape(_ regex: UnsafeBufferPointer<UInt8>, at position: inout Int, inClass: Bool) throws(GrammarError) -> Item {
        assert(regex[position] == UInt8(ascii: "\\"))
        guard position + 1 < regex.count else { throw .conversion("Regex ends with a trailing backslash") }
        let escaped = regex[position + 1]
        position += 2
        switch escaped {
        case UInt8(ascii: "n"): return .single(0x0A)
        case UInt8(ascii: "t"): return .single(0x09)
        case UInt8(ascii: "r"): return .single(0x0D)
        case UInt8(ascii: "f"): return .single(0x0C)
        case UInt8(ascii: "v"): return .single(0x0B)
        case UInt8(ascii: "a"): return .single(0x07)
        case UInt8(ascii: "e"): return .single(0x1B)
        case UInt8(ascii: "0"): return .single(0)
        case UInt8(ascii: "b"):
            if inClass { return .single(0x08) }
            throw .conversion("Word boundary assertion \\b is not supported in regex")
        case UInt8(ascii: "B"): throw .conversion("Word boundary assertion \\B is not supported in regex")
        case UInt8(ascii: "p"), UInt8(ascii: "P"): throw .conversion("Unicode property escape \\p / \\P is not supported in regex")
        case UInt8(ascii: "k"): throw .conversion("Backreference \\k is not supported in regex")
        case UInt8(ascii: "1") ... UInt8(ascii: "9"):
            throw .conversion("Backreference \\\(Character(Unicode.Scalar(escaped))) is not supported in regex")
        case UInt8(ascii: "d"): return .classRanges(digitRanges, negated: false)
        case UInt8(ascii: "D"): return .classRanges(digitRanges, negated: true)
        case UInt8(ascii: "w"): return .classRanges(wordRanges, negated: false)
        case UInt8(ascii: "W"): return .classRanges(wordRanges, negated: true)
        case UInt8(ascii: "s"): return .classRanges(spaceRanges, negated: false)
        case UInt8(ascii: "S"): return .classRanges(spaceRanges, negated: true)
        case UInt8(ascii: "x"):
            guard position + 1 < regex.count else { throw .conversion("\\x must be followed by two hexadecimal digits in regex") }
            let high = EscapeCodec.hexValue(regex[position])
            let low = EscapeCodec.hexValue(regex[position + 1])
            guard high >= 0, low >= 0 else { throw .conversion("\\x must be followed by two hexadecimal digits in regex") }
            position += 2
            return .single(UInt32(high * 16 + low))
        case UInt8(ascii: "u"):
            if position < regex.count, regex[position] == UInt8(ascii: "{") {
                var close = position + 1
                while close < regex.count, regex[close] != UInt8(ascii: "}") { close += 1 }
                guard close < regex.count, close != position + 1, close <= position + 7 else {
                    throw .conversion("\\u{...} must contain one to six hexadecimal digits in regex")
                }
                var codepoint: UInt32 = 0
                for index in (position + 1) ..< close {
                    let digit = EscapeCodec.hexValue(regex[index])
                    guard digit >= 0 else { throw .conversion("\\u{...} must contain one to six hexadecimal digits in regex") }
                    codepoint = codepoint * 16 + UInt32(digit)
                }
                guard codepoint <= RegexFSMBuilder.maxCodepoint else { throw .conversion("\\u{...} escape is beyond the Unicode range in regex") }
                position = close + 1
                return .single(codepoint)
            }
            guard position + 3 < regex.count else { throw .conversion("\\u must be followed by four hexadecimal digits in regex") }
            var codepoint: UInt32 = 0
            for index in position ..< position + 4 {
                let digit = EscapeCodec.hexValue(regex[index])
                guard digit >= 0 else { throw .conversion("\\u must be followed by four hexadecimal digits in regex") }
                codepoint = codepoint * 16 + UInt32(digit)
            }
            position += 4
            return .single(codepoint)
        case UInt8(ascii: "c"):
            guard position < regex.count, isASCIILetter(regex[position]) else { throw .conversion("\\c must be followed by a letter in regex") }
            let codepoint = UInt32(regex[position] & 0x1F)
            position += 1
            return .single(codepoint)
        default:
            if escaped >= 0x80 {
                // Multi-byte UTF-8 character after the backslash: match it literally.
                position -= 1
                let (codepoint, length) = UTF8Codec.decode(regex, at: position)
                guard codepoint != UTF8Codec.invalid else { throw .conversion("Invalid UTF-8 in regex escape sequence") }
                position += length
                return .single(UInt32(codepoint))
            }
            return .single(UInt32(escaped))
        }
    }

    private static let digitRanges: [CodepointRange] = [0x30 ... 0x39]
    private static let wordRanges: [CodepointRange] = [0x30 ... 0x39, 0x41 ... 0x5A, 0x5F ... 0x5F, 0x61 ... 0x7A]
    /// `\s` in the ECMAScript dialect: WhiteSpace plus LineTerminator, not ASCII-only.
    private static let spaceRanges: [CodepointRange] = [
        0x09 ... 0x0D, 0x20 ... 0x20, 0xA0 ... 0xA0, 0x1680 ... 0x1680, 0x2000 ... 0x200A,
        0x2028 ... 0x2029, 0x202F ... 0x202F, 0x205F ... 0x205F, 0x3000 ... 0x3000, 0xFEFF ... 0xFEFF,
    ]

    @inline(__always)
    static func isASCIILetter(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }

    @inline(__always)
    static func isASCIIDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

    @inline(__always)
    static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool { isASCIILetter(byte) || isASCIIDigit(byte) }

    /// Parses a whole character class `[...]` into its accepted code point ranges. ASCII case
    /// folding (if requested) is applied before negation.
    static func parseCharacterClass(_ regex: [UInt8], caseInsensitive: Bool) throws(GrammarError) -> [CodepointRange] {
        assert(regex.count >= 2 && regex.first == UInt8(ascii: "[") && regex.last == UInt8(ascii: "]"))
        let text = String(decoding: regex, as: UTF8.self)
        return try regex.withUnsafeBufferPointer { (buffer) throws(GrammarError) -> [CodepointRange] in
            var position = 1
            let contentEnd = buffer.count - 1
            var negated = false
            if position < contentEnd, buffer[position] == UInt8(ascii: "^") {
                negated = true
                position += 1
            }
            if position == contentEnd { throw .conversion("Empty character class \(text) is not allowed in regex") }

            func parseUnit() throws(GrammarError) -> Item {
                if buffer[position] == UInt8(ascii: "\\") {
                    return try parseEscape(buffer, at: &position, inClass: true)
                }
                let (codepoint, length) = UTF8Codec.decode(buffer, at: position)
                guard codepoint != UTF8Codec.invalid, position + length <= contentEnd else {
                    throw .conversion("Invalid UTF-8 in regex character class \(text)")
                }
                position += length
                return .single(UInt32(codepoint))
            }

            var ranges: [CodepointRange] = []
            while position < contentEnd {
                let unit = try parseUnit()
                guard case let .single(low) = unit else {
                    if case .classRanges(var classRanges, let classNegated) = unit {
                        if classNegated {
                            CodepointRanges.normalize(&classRanges)
                            ranges.append(contentsOf: CodepointRanges.complement(classRanges))
                        } else {
                            ranges.append(contentsOf: classRanges)
                        }
                    }
                    continue
                }
                if position < contentEnd, buffer[position] == UInt8(ascii: "-"), position + 1 < contentEnd {
                    position += 1
                    guard case let .single(high) = try parseUnit() else {
                        throw .conversion("Invalid character range endpoint in regex character class \(text)")
                    }
                    guard high >= low else {
                        throw .conversion("Invalid character range (lower bound exceeds upper bound) in regex character class \(text)")
                    }
                    ranges.append(low ... high)
                } else {
                    ranges.append(low ... low)
                }
            }
            if caseInsensitive { CodepointRanges.foldASCIICase(&ranges) }
            CodepointRanges.normalize(&ranges)
            return negated ? CodepointRanges.complement(ranges) : ranges
        }
    }
}

// MARK: - Parser

/// Shunting parser from pattern bytes to ``RegexIR``.
struct RegexParser {
    private enum StackItem {
        case node(RegexNode)
        case marker(UInt8)
    }

    private struct Entry {
        var item: StackItem
        var spanBegin: Int
        var spanEnd: Int
    }

    private let regex: [UInt8]
    private let flagPrefixLength: Int
    private let caseInsensitive: Bool
    private let makeRepeatRule: RegexFSMBuilder.RepeatRuleFactory?
    private let ruleHint: String

    init(regex: [UInt8], makeRepeatRule: RegexFSMBuilder.RepeatRuleFactory?, ruleHint: String) {
        if regex.count >= 4, regex[0] == UInt8(ascii: "("), regex[1] == UInt8(ascii: "?"), regex[2] == UInt8(ascii: "i"), regex[3] == UInt8(ascii: ")") {
            self.regex = Array(regex[4...])
            flagPrefixLength = 4
            caseInsensitive = true
        } else {
            self.regex = regex
            flagPrefixLength = 0
            caseInsensitive = false
        }
        self.makeRepeatRule = makeRepeatRule
        self.ruleHint = ruleHint
    }

    /// Error format shared with the regex converter: 1-based position including the flag prefix.
    private func error(at position: Int, _ message: String) -> GrammarError {
        .conversion("Regex parsing error at position \(position + flagPrefixLength + 1): \(message)")
    }

    /// Position right after the `]` closing the class starting at `position`, or `nil`.
    private func skipCharacterClass(from start: Int) -> Int? {
        var position = start + 1
        if position < regex.count, regex[position] == UInt8(ascii: "^") { position += 1 }
        while position < regex.count {
            if regex[position] == UInt8(ascii: "\\") {
                position += 2
                continue
            }
            if regex[position] == UInt8(ascii: "]") { return position + 1 }
            position += 1
        }
        return nil
    }

    /// Parses `{n}`, `{n,}` or `{n,m}` starting at `position` (which must be `{`), leaving
    /// `position` on the closing brace.
    private func parseRepeatBounds(at position: inout Int) throws(GrammarError) -> (lower: Int, upper: Int) {
        let maxDigits = 9
        guard regex[position] == UInt8(ascii: "{") else { throw .conversion("Invalid repetition: expected '{'") }
        position += 1
        func skipSpaces() { while position < regex.count, regex[position] == UInt8(ascii: " ") { position += 1 } }
        func readNumber() -> String {
            var digits = ""
            while position < regex.count, RegexEscapes.isASCIIDigit(regex[position]) {
                digits.unicodeScalars.append(Unicode.Scalar(regex[position]))
                position += 1
            }
            return digits
        }
        func current() -> UInt8 { position < regex.count ? regex[position] : 0 }

        skipSpaces()
        let lowerText = readNumber()
        guard !lowerText.isEmpty else { throw .conversion("Invalid repetition count: expected a number after '{'") }
        guard lowerText.count <= maxDigits else { throw .conversion("Invalid repetition count: the count \(lowerText) is too large") }
        let lower = Int(lowerText).unsafelyUnwrapped
        skipSpaces()
        if current() == UInt8(ascii: "}") { return (lower, lower) }
        guard current() == UInt8(ascii: ",") else { throw .conversion("Invalid repetition count: expected ',' or '}' after the lower bound") }
        position += 1
        skipSpaces()
        if current() == UInt8(ascii: "}") { return (lower, RegexNode.noUpperBound) }
        let upperText = readNumber()
        guard !upperText.isEmpty else { throw .conversion("Invalid repetition count: expected a number or '}' after ','") }
        guard upperText.count <= maxDigits else { throw .conversion("Invalid repetition count: the count \(upperText) is too large") }
        let upper = Int(upperText).unsafelyUnwrapped
        guard upper >= lower else {
            throw .conversion("Invalid repetition count: the lower bound \(lower) is larger than the upper bound \(upper)")
        }
        skipSpaces()
        guard current() == UInt8(ascii: "}") else { throw .conversion("Invalid repetition count: expected '}' after the upper bound") }
        return (lower, upper)
    }

    func parse() throws(GrammarError) -> RegexIR {
        var ir = RegexIR()
        ir.caseInsensitive = caseInsensitive
        var stack: [Entry] = []
        let size = regex.count
        var i = 0
        while i < size {
            let byte = regex[i]
            defer { i += 1 }

            // Anchors are ignored (the matcher is anchored at both ends).
            if byte == UInt8(ascii: "^") || byte == UInt8(ascii: "$") { continue }

            if byte == UInt8(ascii: "[") {
                guard let classEnd = skipCharacterClass(from: i) else { throw error(at: i, "Unclosed '['") }
                var contentBegin = i + 1
                if contentBegin < size, regex[contentBegin] == UInt8(ascii: "^") { contentBegin += 1 }
                if contentBegin + 1 == classEnd { throw error(at: i, "Empty character class is not allowed in regex") }
                stack.append(Entry(item: .node(.leaf(Array(regex[i ..< classEnd]))), spanBegin: i, spanEnd: classEnd))
                i = classEnd - 1
                continue
            }
            if byte == UInt8(ascii: "]") { throw error(at: i, "Unmatched ']'") }

            if byte == UInt8(ascii: "+") || byte == UInt8(ascii: "*") || byte == UInt8(ascii: "?") {
                guard let atom = stack.last, case let .node(node) = atom.item else {
                    throw error(at: i, "There is nothing to repeat before '\(Character(Unicode.Scalar(byte)))'")
                }
                stack.removeLast()
                let quantifier: RegexNode.Quantifier = byte == UInt8(ascii: "+") ? .plus : byte == UInt8(ascii: "*") ? .star : .optional
                // Greedy and non-greedy quantifiers accept the same language.
                if i + 1 < size, regex[i + 1] == UInt8(ascii: "?") { i += 1 }
                stack.append(Entry(item: .node(.quantified(quantifier, node)), spanBegin: atom.spanBegin, spanEnd: i + 1))
                continue
            }

            if byte == UInt8(ascii: "(") {
                if i + 1 < size, regex[i + 1] == UInt8(ascii: "?") {
                    guard i + 2 < size else { throw error(at: i, "Group modifier is not finished") }
                    let modifier = regex[i + 2]
                    if modifier == UInt8(ascii: ":") {
                        stack.append(Entry(item: .marker(UInt8(ascii: "(")), spanBegin: i, spanEnd: i + 1))
                        i += 2
                        continue
                    }
                    if modifier == UInt8(ascii: "=") || modifier == UInt8(ascii: "!") {
                        // Lookahead assertions are not supported: skip the group as the empty string.
                        var depth = 1
                        var j = i + 3
                        while j < size, depth > 0 {
                            if regex[j] == UInt8(ascii: "\\") {
                                j += 2
                                continue
                            }
                            if regex[j] == UInt8(ascii: "[") {
                                guard let classEnd = skipCharacterClass(from: j) else { throw error(at: j, "Unclosed '['") }
                                j = classEnd
                                continue
                            }
                            if regex[j] == UInt8(ascii: "(") { depth += 1 } else if regex[j] == UInt8(ascii: ")") { depth -= 1 }
                            j += 1
                        }
                        guard depth == 0 else { throw error(at: i, "The parenthesis is not closed") }
                        stack.append(Entry(item: .node(.leaf([])), spanBegin: i, spanEnd: j))
                        i = j - 1
                        continue
                    }
                    if modifier == UInt8(ascii: "<") || (modifier == UInt8(ascii: "P") && i + 3 < size && regex[i + 3] == UInt8(ascii: "<")) {
                        let nameBegin = modifier == UInt8(ascii: "<") ? i + 3 : i + 4
                        if nameBegin < size, regex[nameBegin] == UInt8(ascii: "=") || regex[nameBegin] == UInt8(ascii: "!") {
                            throw error(at: i, "Lookbehind assertion is not supported in regex")
                        }
                        var j = nameBegin
                        while j < size, RegexEscapes.isASCIIAlphanumeric(regex[j]) || regex[j] == UInt8(ascii: "_") { j += 1 }
                        guard j != nameBegin, j < size, regex[j] == UInt8(ascii: ">") else { throw error(at: i, "Invalid named capturing group") }
                        stack.append(Entry(item: .marker(UInt8(ascii: "(")), spanBegin: i, spanEnd: i + 1))
                        i = j
                        continue
                    }
                    throw error(at: i, "Unsupported group modifier '(?\(Character(Unicode.Scalar(modifier)))'")
                }
                stack.append(Entry(item: .marker(UInt8(ascii: "(")), spanBegin: i, spanEnd: i + 1))
                continue
            }

            if byte == UInt8(ascii: "|") {
                stack.append(Entry(item: .marker(UInt8(ascii: "|")), spanBegin: i, spanEnd: i + 1))
                continue
            }

            if byte == UInt8(ascii: ")") {
                var popped: [Entry] = []
                var paired = false
                var unioned = false
                var groupBegin = 0
                while let entry = stack.popLast() {
                    if case let .marker(marker) = entry.item {
                        if marker == UInt8(ascii: "(") {
                            paired = true
                            groupBegin = entry.spanBegin
                            break
                        }
                        unioned = true
                    }
                    popped.append(entry)
                }
                guard paired else { throw error(at: i, "Unmatched ')'") }
                if !unioned {
                    var children: [RegexNode] = []
                    for entry in popped.reversed() {
                        if case let .node(node) = entry.item { children.append(node) }
                    }
                    stack.append(Entry(item: .node(.group(children)), spanBegin: groupBegin, spanEnd: i + 1))
                } else {
                    var branches: [RegexNode] = []
                    var current: [RegexNode] = []
                    for entry in popped.reversed() {
                        switch entry.item {
                        case .marker:
                            branches.append(.group(current))
                            current = []
                        case let .node(node):
                            current.append(node)
                        }
                    }
                    branches.append(.group(current))
                    stack.append(Entry(item: .node(.union(branches)), spanBegin: groupBegin, spanEnd: i + 1))
                }
                continue
            }

            if byte == UInt8(ascii: "{") {
                guard let atom = stack.last, case let .node(atomNode) = atom.item else {
                    throw error(at: i, "There is nothing to repeat before the repetition")
                }
                stack.removeLast()
                let repeatBegin = i
                let bounds: (lower: Int, upper: Int)
                do {
                    bounds = try parseRepeatBounds(at: &i)
                } catch {
                    throw self.error(at: repeatBegin, error.message)
                }
                var lower = bounds.lower
                let upper = bounds.upper
                if i + 1 < size, regex[i + 1] == UInt8(ascii: "?") { i += 1 }
                let isLarge = upper == RegexNode.noUpperBound
                    ? lower > RegexFSMBuilder.largeRepeatThreshold
                    : upper > RegexFSMBuilder.largeRepeatThreshold
                if isLarge, let makeRepeatRule {
                    // Compile the repeated sub-pattern into a rule and keep the repetition as a
                    // counted repeat edge; the parser executes it with a counter at runtime.
                    var inner = Array(regex[atom.spanBegin ..< atom.spanEnd])
                    if caseInsensitive { inner = Array("(?i)".utf8) + inner }
                    if RegexNode.isNullable(atomNode) {
                        // The count cannot be enforced on a nullable element (RepetitionNormalizer).
                        lower = 0
                    }
                    let hint = (ruleHint.isEmpty ? "regex" : ruleHint) + "_repeat"
                    let innerRuleID = makeRepeatRule(hint, inner)
                    if upper == RegexNode.noUpperBound {
                        let starred = RegexNode.quantified(.star, .ruleRef(innerRuleID))
                        if lower > 0 {
                            let group = RegexNode.group([.repeatRule(innerRuleID, lower: lower, upper: lower), starred])
                            stack.append(Entry(item: .node(group), spanBegin: atom.spanBegin, spanEnd: i + 1))
                        } else {
                            stack.append(Entry(item: .node(starred), spanBegin: atom.spanBegin, spanEnd: i + 1))
                        }
                    } else {
                        stack.append(Entry(item: .node(.repeatRule(innerRuleID, lower: lower, upper: upper)), spanBegin: atom.spanBegin, spanEnd: i + 1))
                    }
                } else {
                    stack.append(Entry(item: .node(.repeat(atomNode, lower: lower, upper: upper)), spanBegin: atom.spanBegin, spanEnd: i + 1))
                }
                continue
            }

            // Literal characters and escapes: one leaf per code point so a following quantifier
            // applies to the whole character.
            if byte == UInt8(ascii: "\\") {
                var escapeEnd = i
                do {
                    _ = try regex.withUnsafeBufferPointer { (buffer) throws(GrammarError) in
                        try RegexEscapes.parseEscape(buffer, at: &escapeEnd, inClass: false)
                    }
                } catch {
                    throw self.error(at: i, error.message)
                }
                stack.append(Entry(item: .node(.leaf(Array(regex[i ..< escapeEnd]))), spanBegin: i, spanEnd: escapeEnd))
                i = escapeEnd - 1
                continue
            }
            var length = regex.withUnsafeBufferPointer { UTF8Codec.decode($0, at: i).length }
            if length == 0 { length = 1 }
            stack.append(Entry(item: .node(.leaf(Array(regex[i ..< i + length]))), spanBegin: i, spanEnd: i + length))
            i += length - 1
        }

        var segment: [RegexNode] = []
        var branches: [[RegexNode]] = []
        var unioned = false
        for entry in stack {
            switch entry.item {
            case let .marker(marker):
                guard marker == UInt8(ascii: "|") else { throw error(at: entry.spanBegin, "The parenthesis is not closed") }
                branches.append(segment)
                segment = []
                unioned = true
            case let .node(node):
                segment.append(node)
            }
        }
        if !unioned {
            ir.nodes = segment
        } else {
            branches.append(segment)
            ir.nodes = [.union(branches.map { RegexNode.group($0) })]
        }
        return ir
    }
}
