extension GrammarBuilder {
    /// Emits a byte DFA as Unicode character transitions. Only scalar boundaries become rule
    /// boundaries: emitting continuation bytes independently would change an EBNF round trip.
    /// Used by JSON string intersections; the common unconstrained string stays a regex macro.
    mutating func addLeafFSM(_ automaton: FSMWithStartEnd, hint: String, closing: String = "") throws(GrammarError) -> Int32 {
        let automaton = automaton.isDFA ? automaton : try automaton.determinized(maxStates: 1_000_000)
        let count = automaton.stateCount
        var predecessors = Array(repeating: [Int32](), count: count)
        for state in 0 ..< Int32(count) {
            for edge in automaton.fsm.edges(of: state) { predecessors[Int(edge.target)].append(state) }
        }
        var productive = Array(repeating: false, count: count)
        var pending = automaton.ends
        for state in pending { productive[Int(state)] = true }
        var index = 0
        while index < pending.count {
            for state in predecessors[Int(pending[index])] where !productive[Int(state)] {
                productive[Int(state)] = true; pending.append(state)
            }
            index += 1
        }
        guard productive[Int(automaton.start)] else {
            return addCharacterClass([0 ... 0x10FFFF], isNegated: true)
        }
        struct Range { var low: Int32; var high: Int32; var target: Int32 }
        func merged(_ input: [Range]) -> [Range] {
            let sorted = input.sorted { ($0.target, $0.low, $0.high) < ($1.target, $1.low, $1.high) }
            var result: [Range] = []
            for range in sorted {
                if let last = result.last, last.target == range.target, range.low <= last.high + 1 {
                    result[result.count - 1].high = max(last.high, range.high)
                } else { result.append(range) }
            }
            return result
        }
        func append(_ ranges: inout [Range], low: Int32, high: Int32, shift: Int32, suffix: Range) {
            if suffix.low == 0, suffix.high == (1 << shift) - 1 {
                ranges.append(.init(low: low << shift, high: (high << shift) | suffix.high, target: suffix.target))
            } else {
                for prefix in low ... high {
                    ranges.append(.init(low: (prefix << shift) | suffix.low, high: (prefix << shift) | suffix.high, target: suffix.target))
                }
            }
        }
        struct SuffixKey: Hashable { var state: Int32; var remaining: Int32 }
        var suffixCache: [SuffixKey: [Range]] = [:]
        func suffixes(_ state: Int32, remaining: Int32) -> [Range] {
            let key = SuffixKey(state: state, remaining: remaining)
            if let cached = suffixCache[key] { return cached }
            var ranges: [Range] = []
            if remaining == 0 { ranges.append(.init(low: 0, high: 0, target: state)) }
            else {
                for edge in automaton.fsm.edges(of: state) where productive[Int(edge.target)] {
                    let low = max(edge.min, 0x80), high = min(edge.max, 0xBF)
                    guard low <= high else { continue }
                    for suffix in suffixes(edge.target, remaining: remaining - 1) {
                        append(&ranges, low: low & 0x3F, high: high & 0x3F, shift: 6 * (remaining - 1), suffix: suffix)
                    }
                }
            }
            let result = merged(ranges); suffixCache[key] = result
            return result
        }
        var ruleIDs = Array(repeating: Int32(-1), count: count)
        ruleIDs[Int(automaton.start)] = addEmptyRule(hint: hint)
        pending = [automaton.start]; index = 0
        let leadLow: [Int32] = [0, 0xC2, 0xE0, 0xF0], leadHigh: [Int32] = [0, 0xDF, 0xEF, 0xF4]
        let scalarLow: [Int32] = [0, 0x80, 0x800, 0x10000], scalarHigh: [Int32] = [0, 0x7FF, 0xFFFF, 0x10FFFF]
        while index < pending.count {
            let state = pending[index]; index += 1
            var ranges: [Range] = []
            for edge in automaton.fsm.edges(of: state) where productive[Int(edge.target)] {
                if edge.min < 128 { ranges.append(.init(low: edge.min, high: min(edge.max, 127), target: edge.target)) }
                for remaining in 1 ... 3 {
                    let low = max(edge.min, leadLow[remaining]), high = min(edge.max, leadHigh[remaining])
                    guard low <= high else { continue }
                    var unicode: [Range] = []
                    let mask: Int32 = (1 << (6 - remaining)) - 1
                    for suffix in suffixes(edge.target, remaining: Int32(remaining)) {
                        append(&unicode, low: low & mask, high: high & mask, shift: Int32(6 * remaining), suffix: suffix)
                    }
                    for var range in unicode {
                        range.low = max(range.low, scalarLow[remaining]); range.high = min(range.high, scalarHigh[remaining])
                        if range.low <= range.high { ranges.append(range) }
                    }
                }
            }
            var transitions: [Int32: [ClosedRange<Int32>]] = [:]
            for range in merged(ranges) { transitions[range.target, default: []].append(range.low ... range.high) }
            var choices: [Int32] = []
            if automaton.isEndState(state) { choices.append(closing.isEmpty ? addEmptyString() : addByteString(closing)) }
            for target in transitions.keys.sorted() {
                if ruleIDs[Int(target)] == -1 { ruleIDs[Int(target)] = addEmptyRule(hint: hint); pending.append(target) }
                choices.append(addSequence([addCharacterClass(transitions[target]!), addRuleRef(ruleIDs[Int(target)])]))
            }
            updateRuleBody(ruleIDs[Int(state)], addChoices(choices))
        }
        return addRuleRef(ruleIDs[Int(automaton.start)])
    }
}
