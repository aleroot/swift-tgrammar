// Suffix automaton over a chunk sequence, expanded to bytes. Accepts every contiguous
// sub-sequence of chunks (the `Substring(...)` macro); every state is accepting.

enum SuffixAutomaton {
    static func build(chunks: [[UInt8]]) -> FSMWithStartEnd {
        struct State {
            var length: Int32 = 0
            var suffixLink: Int32 = -1
            /// Keyed by chunk; kept sorted at expansion time for a deterministic layout.
            var transitions: [[UInt8]: Int32] = [:]
        }

        var states = [State()]
        var last: Int32 = 0
        for chunk in chunks {
            let current = Int32(states.count)
            states.append(State(length: states[Int(last)].length + 1))
            var parent = last
            while parent != -1, states[Int(parent)].transitions[chunk] == nil {
                states[Int(parent)].transitions[chunk] = current
                parent = states[Int(parent)].suffixLink
            }
            if parent == -1 {
                states[Int(current)].suffixLink = 0
            } else {
                let target = states[Int(parent)].transitions[chunk].unsafelyUnwrapped
                if states[Int(parent)].length + 1 == states[Int(target)].length {
                    states[Int(current)].suffixLink = target
                } else {
                    let clone = Int32(states.count)
                    var cloned = states[Int(target)]
                    cloned.length = states[Int(parent)].length + 1
                    states.append(cloned)
                    while parent != -1 {
                        guard states[Int(parent)].transitions[chunk] == target else { break }
                        states[Int(parent)].transitions[chunk] = clone
                        parent = states[Int(parent)].suffixLink
                    }
                    states[Int(target)].suffixLink = clone
                    states[Int(current)].suffixLink = clone
                }
            }
            last = current
        }

        var fsm = FSM(stateCount: states.count)
        let ends = Array(0 ..< Int32(states.count))
        for index in 0 ..< Int32(states.count) {
            let transitions = states[Int(index)].transitions.sorted { $0.key.lexicographicallyPrecedes($1.key) }
            for (chunk, target) in transitions {
                if chunk.isEmpty {
                    fsm.addEpsilonEdge(from: index, to: target)
                    continue
                }
                var current = index
                for (offset, byte) in chunk.enumerated() {
                    let next = offset + 1 == chunk.count ? target : fsm.addState()
                    fsm.addEdge(from: current, to: next, min: Int32(byte), max: Int32(byte))
                    current = next
                }
            }
        }
        return FSMWithStartEnd(fsm: fsm, start: 0, ends: ends)
    }
}
