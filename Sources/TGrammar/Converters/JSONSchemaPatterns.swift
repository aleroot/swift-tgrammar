/// JSON escapes are decoded into scalar values before matching property-name exclusions.
/// Pairing UTF-16 surrogates also makes string-length bounds count supplementary scalars once.
enum JSONStringPatterns {
    private static let escape = #"\\u"#

    /// One decoded JSON string character: a raw scalar, a short escape or a Unicode escape.
    static let scalar = #"([^\x00-\x1F"\\\uD800-\uDFFF]|\\["\\/bfnrt]|"# + unicodeEscape() + ")"

    static let shortEscapes: [(Int32, String)] = [(8, "b"), (9, "t"), (10, "n"), (12, "f"), (13, "r"), (34, "\""), (47, "/"), (92, "\\")]

    static func shortEscape(for scalar: Int32) -> String? { shortEscapes.first { $0.0 == scalar }?.1 }

    static func unicodeEscape(for scalar: Int32) -> String {
        if scalar <= 0xFFFF { return escape + IntegerRangePattern.fixedHex(Int(scalar), Int(scalar)) }
        let offset = Int(scalar) - 0x10000
        let high = 0xD800 + (offset >> 10)
        let low = 0xDC00 + (offset & 0x3FF)
        return escape + IntegerRangePattern.fixedHex(high, high) + escape + IntegerRangePattern.fixedHex(low, low)
    }

    static func unicodeEscape(excluding scalars: [Int32] = []) -> String {
        func ranges(_ start: Int, _ end: Int, excluding values: [Int]) -> String? {
            var lower = start
            var patterns: [String] = []
            for value in Array(Set(values.filter { $0 >= start && $0 <= end })).sorted() + [end + 1] {
                if lower < value { patterns.append(IntegerRangePattern.fixedHex(lower, value - 1)) }
                lower = value + 1
            }
            return patterns.isEmpty ? nil : "(" + patterns.joined(separator: "|") + ")"
        }
        let bmp = scalars.filter { $0 < 0x10000 }.map(Int.init)
        var patterns = [ranges(0, 0xD7FF, excluding: bmp), ranges(0xE000, 0xFFFF, excluding: bmp)].compactMap { $0.map { escape + $0 } }
        var pairs: [Int: [Int]] = [:]
        for scalar in scalars where scalar >= 0x10000 {
            let offset = Int(scalar) - 0x10000
            pairs[0xD800 + (offset >> 10), default: []].append(0xDC00 + (offset & 0x3FF))
        }
        let allLow = ranges(0xDC00, 0xDFFF, excluding: [])!
        if let high = ranges(0xD800, 0xDBFF, excluding: Array(pairs.keys)) { patterns.append(escape + high + escape + allLow) }
        for high in pairs.keys.sorted() {
            if let low = ranges(0xDC00, 0xDFFF, excluding: pairs[high]!) {
                patterns.append(escape + IntegerRangePattern.fixedHex(high, high) + escape + low)
            }
        }
        return "(" + patterns.joined(separator: "|") + ")"
    }
}

/// Whole-key exclusion automata over decoded scalars, shared by the JSON and Gemma key rules.
enum JSONKeyAutomata {
    struct Trie {
        struct Node { var edges: [Int32: Int] = [:]; var terminal = false }
        var nodes = [Node()]

        init(_ names: [String]) {
            for name in names {
                var current = 0
                for scalar in name.unicodeScalars {
                    let cp = Int32(scalar.value)
                    if let next = nodes[current].edges[cp] { current = next }
                    else {
                        let next = nodes.count
                        nodes.append(Node())
                        nodes[current].edges[cp] = next
                        current = next
                    }
                }
                nodes[current].terminal = true
            }
        }
    }

    /// A finite whole-key exclusion automaton over decoded scalars. Every trie edge also accepts
    /// the scalar's JSON escape spellings, so an additional property cannot bypass a known field's
    /// value schema (`"city"` and `"\u0063ity"`).
    ///
    /// Built directly as a DFA: per trie node, the raw UTF-8 spellings and the `\uXXXX` hex digits
    /// of its outgoing scalars are tries, and every other scalar finishes through shared states into
    /// an absorbing "another key" state. The automaton accepts malformed spellings as well; callers
    /// intersect it with the JSON string automaton, which rejects them.
    static func keysExcluding(_ names: [String]) throws(GrammarError) -> FSMWithStartEnd {
        let trie = Trie(names)
        var fsm = FSM(stateCount: trie.nodes.count)
        func addState() -> Int32 { fsm.addState() }
        // Shared states: `other` absorbs any other key; `continuation[k]` reads k UTF-8
        // continuation bytes, `hex[k]` k hex digits, then both continue in `other`.
        let other = addState()
        let continuation = [other, addState(), addState(), addState()]
        let hex = [other, addState(), addState(), addState(), addState()]
        let hexDigits: [ClosedRange<Int32>] = [0x30 ... 0x39, 0x41 ... 0x46, 0x61 ... 0x66]
        for k in 1 ... 3 { fsm.addEdge(from: continuation[k], to: continuation[k - 1], min: 0x80, max: 0xBF) }
        for k in 1 ... 4 { for range in hexDigits { fsm.addEdge(from: hex[k], to: hex[k - 1], min: range.lowerBound, max: range.upperBound) } }

        /// Byte edges of a state that reads one raw scalar, `\` and an escape; `special` overrides
        /// the default target of single bytes.
        func addScalarEdges(from source: Int32, special: [Int32: Int32]) {
            var targets = [Int32](repeating: -1, count: 256)
            for byte in 0 ..< 0x80 { targets[byte] = other }
            for byte in 0xC0 ... 0xDF { targets[byte] = continuation[1] }
            for byte in 0xE0 ... 0xEF { targets[byte] = continuation[2] }
            for byte in 0xF0 ... 0xF7 { targets[byte] = continuation[3] }
            for (byte, target) in special { targets[Int(byte)] = target }
            var byte = 0
            while byte < 256 {
                let target = targets[byte]
                var last = byte
                while last + 1 < 256, targets[last + 1] == target { last += 1 }
                if target >= 0 { fsm.addEdge(from: source, to: target, min: Int32(byte), max: Int32(last)) }
                byte = last + 1
            }
        }
        let otherEscape = addState()
        addScalarEdges(from: other, special: [0x5C: otherEscape])
        for (_, suffix) in JSONStringPatterns.shortEscapes {
            let byte = Int32(suffix.utf8.first!)
            fsm.addEdge(from: otherEscape, to: other, min: byte, max: byte)
        }
        fsm.addEdge(from: otherEscape, to: hex[4], min: 0x75, max: 0x75)

        /// Hex-digit spellings of `\u` escapes: `digits` lists the digit values after the first
        /// `\u`, with -1 standing for the `\u` between the two halves of a surrogate pair.
        func escapeDigits(_ scalar: Int32) -> [Int32] {
            func four(_ value: Int) -> [Int32] { (0 ..< 4).map { Int32((value >> (12 - 4 * $0)) & 0xF) } }
            if scalar <= 0xFFFF { return four(Int(scalar)) }
            let offset = Int(scalar) - 0x10000
            return four(0xD800 + (offset >> 10)) + [-1] + four(0xDC00 + (offset & 0x3FF))
        }

        for (index, node) in trie.nodes.enumerated() {
            let source = Int32(index)
            let outgoing = node.edges.keys.sorted()
            if outgoing.isEmpty {
                addScalarEdges(from: source, special: [0x5C: otherEscape])
                continue
            }
            // Raw spellings: a trie over the UTF-8 bytes of the scalars JSON may write raw.
            var rawFirst: [Int32: Int32] = [:]                       // lead byte -> state
            var prefixStates: [[UInt8]: Int32] = [:]                 // multi-byte prefix -> state
            var rawChildren: [Int32: [UInt8: Int32]] = [:]           // prefix state -> byte -> state
            for cp in outgoing where cp >= 0x20 && cp != 0x22 && cp != 0x5C {
                let target = Int32(node.edges[cp]!)
                let bytes = Array(String(Unicode.Scalar(UInt32(cp))!).utf8)
                var parent: Int32? = nil
                for length in 1 ... bytes.count {
                    let next: Int32
                    if length == bytes.count { next = target }
                    else if let existing = prefixStates[Array(bytes[..<length])] { parent = existing; continue }
                    else { next = addState(); prefixStates[Array(bytes[..<length])] = next }
                    if let parent { rawChildren[parent, default: [:]][bytes[length - 1]] = next }
                    else { rawFirst[Int32(bytes[0])] = next }
                    parent = next
                }
            }
            // Inside a multi-byte scalar: matching bytes go deeper, other continuation bytes finish it.
            for (prefix, state) in prefixStates {
                let width = prefix[0] < 0xE0 ? 2 : prefix[0] < 0xF0 ? 3 : 4
                var targets = [Int32](repeating: continuation[width - prefix.count - 1], count: 0x40)
                for (byte, target) in rawChildren[state] ?? [:] { targets[Int(byte) - 0x80] = target }
                var byte = 0
                while byte < 0x40 {
                    var last = byte
                    while last + 1 < 0x40, targets[last + 1] == targets[byte] { last += 1 }
                    fsm.addEdge(from: state, to: targets[byte], min: Int32(0x80 + byte), max: Int32(0x80 + last))
                    byte = last + 1
                }
            }
            let escape = addState()
            rawFirst[0x5C] = escape
            addScalarEdges(from: source, special: rawFirst)
            // Short escapes, then `\u` followed by a trie over the hex digits of every scalar.
            for (cp, suffix) in JSONStringPatterns.shortEscapes {
                let byte = Int32(suffix.utf8.first!)
                fsm.addEdge(from: escape, to: node.edges[cp].map(Int32.init) ?? other, min: byte, max: byte)
            }
            let hexRoot = addState()
            fsm.addEdge(from: escape, to: hexRoot, min: 0x75, max: 0x75)
            var hexChildren: [Int32: [Int32: Int32]] = [:]   // state -> digit (or -1) -> state
            var hexRemaining: [Int32: Int] = [hexRoot: 4]       // digits left in the current group
            for cp in outgoing {
                let target = Int32(node.edges[cp]!)
                let digits = escapeDigits(cp)
                var state = hexRoot
                for (position, digit) in digits.enumerated() {
                    let isLast = position == digits.count - 1
                    if let next = hexChildren[state]?[digit] { state = next; continue }
                    let next: Int32
                    if isLast { next = target }
                    else if digit == -1 {
                        // `\` then `u` between the halves of a surrogate pair.
                        let u = addState()
                        next = addState()
                        fsm.addEdge(from: u, to: next, min: 0x75, max: 0x75)
                        hexChildren[state, default: [:]][-1] = u
                        hexRemaining[next] = 4
                        state = next
                        continue
                    } else {
                        next = addState()
                        hexRemaining[next] = hexRemaining[state]! - 1
                    }
                    hexChildren[state, default: [:]][digit] = next
                    state = next
                }
            }
            for (state, children) in hexChildren {
                if let u = children[-1] {
                    fsm.addEdge(from: state, to: u, min: 0x5C, max: 0x5C)
                    continue
                }
                let mismatch = hex[hexRemaining[state]! - 1]
                for range in hexDigits {
                    for byte in range {
                        let value = byte <= 0x39 ? byte - 0x30 : (byte | 0x20) - 0x61 + 10
                        fsm.addEdge(from: state, to: children[value] ?? mismatch, min: byte, max: byte)
                    }
                }
            }
        }
        var ends = trie.nodes.indices.filter { !trie.nodes[$0].terminal }.map(Int32.init)
        ends.append(other)
        return FSMWithStartEnd(fsm: fsm, start: 0, ends: ends, isDFA: true)
    }
}

enum IntegerRangePattern {
    static func make(minimum: Int64?, maximum: Int64?) -> String {
        if minimum == nil && maximum == nil { return #"(0|-?[1-9][0-9]*)"# }
        var parts: [String] = []
        if (minimum ?? .min) <= 0, (maximum ?? .max) >= 0 { parts.append("0") }
        if (maximum ?? .max) >= 1 {
            parts.append(positive(lower: UInt64(Swift.max(1, minimum ?? 1)), upper: maximum.map { UInt64($0) }))
        }
        if (minimum ?? .min) <= -1 {
            let lower: UInt64 = maximum.map { $0 < -1 ? $0.magnitude : 1 } ?? 1
            let upper = minimum.map(\.magnitude)
            parts.append("-" + positive(lower: lower, upper: upper))
        }
        return "(" + parts.joined(separator: "|") + ")"
    }

    private static func positive(lower: UInt64, upper: UInt64?) -> String {
        let low = String(lower)
        let high = upper.map(String.init)
        var parts: [String] = []
        let maxLength = high?.count ?? low.count
        for length in low.count ... maxLength {
            let start = length == low.count ? low : "1" + String(repeating: "0", count: length - 1)
            let end = length == high?.count ? high! : String(repeating: "9", count: length)
            parts.append(fixed(Array(start.utf8), Array(end.utf8), radix: 10))
        }
        if upper == nil { parts.append("[1-9][0-9]{\(low.count),}") }
        return "(" + parts.joined(separator: "|") + ")"
    }

    static func fixedHex(_ low: Int, _ high: Int) -> String {
        func digits(_ value: Int) -> [UInt8] {
            let s = String(value, radix: 16)
            return Array((String(repeating: "0", count: 4 - s.count) + s).utf8)
        }
        return fixed(digits(low), digits(high), radix: 16)
    }

    static func decimal(lower: String, upper: String?, fractionDigits: Int) -> String {
        let minLength = Swift.max(lower.count, fractionDigits + 1)
        let maxLength = upper.map { Swift.max($0.count, fractionDigits + 1) } ?? minLength
        var parts: [String] = []
        for length in minLength ... maxLength {
            let lo = length == minLength ? String(repeating: "0", count: length - lower.count) + lower : "1" + String(repeating: "0", count: length - 1)
            let hi = length == maxLength && upper != nil ? String(repeating: "0", count: length - upper!.count) + upper! : String(repeating: "9", count: length)
            if lo <= hi { parts.append(fixed(Array(lo.utf8), Array(hi.utf8), radix: 10, decimalAfter: fractionDigits == 0 ? nil : length - fractionDigits)) }
        }
        if upper == nil {
            if fractionDigits == 0 { parts.append("[1-9][0-9]{\(minLength),}") }
            else { parts.append("[1-9][0-9]{\(minLength - fractionDigits),}\\.[0-9]{\(fractionDigits)}") }
        }
        return "(" + parts.joined(separator: "|") + ")"
    }

    private static func fixed(_ low: [UInt8], _ high: [UInt8], radix: Int, decimalAfter: Int? = nil) -> String {
        func value(_ byte: UInt8) -> Int { Int(byte >= 97 ? byte - 87 : byte - 48) }
        func digit(_ value: Int) -> String {
            if value < 10 { return String(value) }
            let s = String(value, radix: 16)
            return "[" + s + s.uppercased() + "]"
        }
        func range(_ low: Int, _ high: Int) -> String {
            if low == high { return digit(low) }
            if radix == 10 { return "[\(low)-\(high)]" }
            return "(" + (low ... high).map(digit).joined(separator: "|") + ")"
        }
        func visit(_ index: Int, _ lowerTight: Bool, _ upperTight: Bool) -> String {
            if index == low.count { return "" }
            if !lowerTight && !upperTight {
                let remaining = low.count - index
                let all = radix == 10 ? "[0-9]" : "[0-9a-fA-F]"
                if let dot = decimalAfter, dot >= index {
                    func run(_ count: Int) -> String { count == 0 ? "" : count == 1 ? all : all + "{\(count)}" }
                    return run(dot - index) + "\\." + run(low.count - dot)
                }
                return remaining == 1 ? all : all + "{\(remaining)}"
            }
            let a = lowerTight ? value(low[index]) : 0
            let b = upperTight ? value(high[index]) : radix - 1
            var groups: [(String, Int, Int)] = []
            for d in a ... b {
                let suffix = visit(index + 1, lowerTight && d == a, upperTight && d == b)
                if let last = groups.last, last.0 == suffix { groups[groups.count - 1].2 = d }
                else { groups.append((suffix, d, d)) }
            }
            let parts = groups.map { range($0.1, $0.2) + $0.0 }
            let prefix = decimalAfter == index ? "\\." : ""
            return prefix + (parts.count == 1 ? parts[0] : "(" + parts.joined(separator: "|") + ")")
        }
        return visit(0, true, true)
    }
}
