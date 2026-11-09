// Trie automaton over byte patterns, optionally completed into an Aho-Corasick automaton with
// failure transitions. Used for tag dispatch (trigger strings) and for stop-string detection.

enum TrieFSMBuilder {
    /// The built automaton and, for each input pattern in order, its terminal state.
    struct Result {
        var fsm: FSMWithStartEnd
        var patternEndStates: [Int32]
    }

    /// Builds the trie of `patterns`.
    ///
    /// - Parameters:
    ///   - excludedPatterns: Strings that must never be matched; only honoured together with
    ///     `addBackEdges` (their states are removed from the automaton).
    ///   - allowOverlap: When `false`, returns `nil` if a pattern is empty or a prefix of another.
    ///   - addBackEdges: Adds Aho-Corasick failure transitions so matching can resume on any
    ///     byte from every non-terminal state.
    static func build(
        patterns: [[UInt8]],
        excludedPatterns: [[UInt8]] = [],
        allowOverlap: Bool = true,
        addBackEdges: Bool = false
    ) -> Result? {
        var fsm = FSM(stateCount: 1)
        let start: Int32 = 0
        var ends = Set<Int32>()
        var endStates: [Int32] = []
        endStates.reserveCapacity(patterns.count)

        func insert(_ pattern: [UInt8]) -> Int32? {
            if !allowOverlap, pattern.isEmpty { return nil }
            var current = start
            for byte in pattern {
                let value = Int32(byte)
                var next = fsm.nextState(from: current, value: value)
                if next == FSM.noNextState {
                    next = fsm.addState()
                    fsm.addEdge(from: current, to: next, min: value, max: value)
                }
                current = next
                if !allowOverlap, ends.contains(current) { return nil }
            }
            if !allowOverlap, !fsm.edges(of: current).isEmpty { return nil }
            ends.insert(current)
            return current
        }

        for pattern in patterns {
            guard let end = insert(pattern) else { return nil }
            endStates.append(end)
        }

        var deadStates = Set<Int32>()
        if addBackEdges {
            for pattern in excludedPatterns {
                guard let end = insert(pattern) else { return nil }
                deadStates.insert(end)
            }
            addFailureTransitions(&fsm, start: start, ends: ends, deadStates: &deadStates)
            if !deadStates.isEmpty {
                for state in 0 ..< Int32(fsm.stateCount) {
                    fsm.withEdges(of: state) { edges in edges.removeAll { deadStates.contains($0.target) } }
                }
            }
        }

        return Result(fsm: FSMWithStartEnd(fsm: fsm, start: start, ends: Array(ends)), patternEndStates: endStates)
    }

    /// Completes the trie into an Aho-Corasick automaton: on a mismatch at state `u` on byte
    /// `b`, matching resumes from the longest proper suffix of `u`'s path that is still a trie
    /// path (the failure state). Every non-terminal state gets a fully resolved 256-entry row,
    /// compressed into range edges.
    private static func addFailureTransitions(_ fsm: inout FSM, start: Int32, ends: Set<Int32>, deadStates: inout Set<Int32>) {
        let stateCount = fsm.stateCount

        var bfsOrder: [Int32] = [start]
        bfsOrder.reserveCapacity(stateCount)
        var head = 0
        while head < bfsOrder.count {
            for edge in fsm.edges(of: bfsOrder[head]) { bfsOrder.append(edge.target) }
            head &+= 1
        }
        assert(bfsOrder.count == stateCount)

        var fail = [Int32](repeating: start, count: stateCount)
        var delta = [Int32](repeating: FSM.noNextState, count: stateCount &* 256)
        for state in 0 ..< Int32(stateCount) {
            for edge in fsm.edges(of: state) { delta[Int(state) &* 256 &+ Int(edge.min)] = edge.target }
        }
        for u in bfsOrder {
            // A trie child can complete an excluded suffix without entering its terminal state
            // (excludes {"abc", "xabcq"}: the state for "xabc" fails to "abc"); it is dead too.
            if deadStates.contains(fail[Int(u)]) { deadStates.insert(u) }
            let row = Int(u) &* 256
            let failRow = Int(fail[Int(u)]) &* 256
            for byte in 0 ..< 256 {
                let child = delta[row &+ byte]
                let fallback = u == start ? start : delta[failRow &+ byte]
                if child == FSM.noNextState {
                    delta[row &+ byte] = fallback
                } else {
                    fail[Int(child)] = fallback
                }
            }
        }

        for u in 0 ..< Int32(stateCount) {
            if u != start, ends.contains(u) { continue }
            let row = Int(u) &* 256
            var newEdges: [FSMEdge] = []
            var byte = 0
            while byte < 256 {
                let target = delta[row &+ byte]
                var rangeEnd = byte
                while rangeEnd &+ 1 < 256, delta[row &+ rangeEnd &+ 1] == target { rangeEnd &+= 1 }
                newEdges.append(FSMEdge(min: Int32(byte), max: Int32(rangeEnd), target: target))
                byte = rangeEnd &+ 1
            }
            fsm.setEdges(of: u, newEdges)
        }
    }
}
