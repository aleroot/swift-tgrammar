// Automaton algebra and normalization: the regular operators (star, plus, optional, union,
// concatenation, complement, intersection) and the state reducers run on every rule automaton
// (epsilon simplification, local equivalent-state merging) plus determinization and
// minimization for the converters.

extension FSMWithStartEnd {
    // MARK: Regular operators

    /// `self*`: a fresh accepting start state linked to the old start, with every end looping
    /// back to it.
    func star() -> FSMWithStartEnd {
        var fsm = self.fsm
        let newStart = fsm.addState()
        for end in ends { fsm.addEpsilonEdge(from: end, to: newStart) }
        fsm.addEpsilonEdge(from: newStart, to: start)
        return FSMWithStartEnd(fsm: fsm, start: newStart, ends: [newStart])
    }

    /// `self+`: every end state loops back to the start.
    func plus() -> FSMWithStartEnd {
        var fsm = self.fsm
        for end in ends { fsm.addEpsilonEdge(from: end, to: start) }
        return FSMWithStartEnd(fsm: fsm, start: start, ends: ends)
    }

    /// `self?`: a skip is taken only before entering this occurrence of the automaton.
    func optional() -> FSMWithStartEnd {
        var fsm = self.fsm
        // Upstream links the start to the first end state. That is only a skip when the end is a
        // sink and nothing re-enters the start: an end with outgoing edges (the state after `a`
        // in `a[0-9]{0,4}`) would let the remainder match without its prefix, and an internal
        // loop back to the start would skip a required suffix (`([a-]*a)?`).
        if let first = ends.first, fsm.edges[Int(first)].isEmpty,
           !fsm.edges.contains(where: { $0.contains(where: { $0.target == start }) }) {
            fsm.addEpsilonEdge(from: start, to: first)
            return FSMWithStartEnd(fsm: fsm, start: start, ends: ends)
        }
        let newStart = fsm.addState()
        fsm.addEpsilonEdge(from: newStart, to: start)
        return FSMWithStartEnd(fsm: fsm, start: newStart, ends: ends + [newStart])
    }

    /// The complement over byte strings. Requires a leaf automaton (no rule references).
    func complement(maxStates: Int = 1_000_000) throws(GrammarError) -> FSMWithStartEnd {
        precondition(isLeaf, "Not operation is not supported for FSM with rule references.")
        var result = isDFA ? self : try determinized(maxStates: maxStates)
        var newEnds: [Int32] = []
        for state in 0 ..< Int32(result.stateCount) where !result.isEndState(state) { newEnds.append(state) }
        let acceptAll = result.addState()
        newEnds.append(acceptAll)
        for state in 0 ..< Int32(result.stateCount) {
            var accepted = ByteSet()
            for edge in result.fsm.edges(of: state) where edge.isCharRange {
                accepted.insert(range: edge.min ... edge.max)
            }
            accepted.inverted.forEachRange { range in
                result.fsm.addEdge(from: state, to: acceptAll, min: range.lowerBound, max: range.upperBound)
            }
        }
        result.setEnds(newEnds)
        return result
    }

    /// The union of several automata: a new start state with epsilon edges into each.
    static func union(_ fsms: [FSMWithStartEnd]) -> FSMWithStartEnd {
        if fsms.count == 1 { return fsms[0] }
        precondition(fsms.count > 1, "Union of 0 FSMs is not allowed.")
        var fsm = FSM(stateCount: 1)
        let start: Int32 = 0
        var ends: [Int32] = []
        for part in fsms {
            let mapping = fsm.addFSM(part.fsm)
            fsm.addEpsilonEdge(from: start, to: mapping[Int(part.start)])
            for end in part.ends { ends.append(mapping[Int(end)]) }
        }
        return FSMWithStartEnd(fsm: fsm, start: start, ends: ends)
    }

    /// The concatenation of several automata, in order.
    static func concat(_ fsms: [FSMWithStartEnd]) -> FSMWithStartEnd {
        if fsms.count == 1 { return fsms[0] }
        precondition(fsms.count > 1, "Concatenation of 0 FSMs is not allowed.")
        var fsm = FSM()
        var start: Int32 = 0
        var ends: [Int32] = []
        var previousEnds: [Int32] = []
        for (index, part) in fsms.enumerated() {
            let mapping = fsm.addFSM(part.fsm)
            if index == 0 {
                start = mapping[Int(part.start)]
            } else {
                let thisStart = mapping[Int(part.start)]
                for end in previousEnds { fsm.addEpsilonEdge(from: end, to: thisStart) }
            }
            if index == fsms.count &- 1 {
                for end in part.ends { ends.append(mapping[Int(end)]) }
            } else {
                previousEnds.removeAll(keepingCapacity: true)
                for end in part.ends { previousEnds.append(mapping[Int(end)]) }
            }
        }
        return FSMWithStartEnd(fsm: fsm, start: start, ends: ends)
    }

    /// The intersection of two leaf automata (product construction over their DFAs).
    static func intersect(_ lhs: FSMWithStartEnd, _ rhs: FSMWithStartEnd, maxStates: Int = 1_000_000) throws(GrammarError) -> FSMWithStartEnd {
        guard lhs.isLeaf, rhs.isLeaf else { throw .compilation("Intersect only support leaf fsm!") }
        let lhsDFA = try lhs.determinized(maxStates: maxStates)
        let rhsDFA = try rhs.determinized(maxStates: maxStates)
        var result = FSMWithStartEnd(fsm: FSM(), start: 0, ends: [], isDFA: true)
        struct Pair: Hashable { var left: Int32; var right: Int32 }
        var stateMap: [Pair: Int32] = [:]
        var queue: [Pair] = [Pair(left: lhsDFA.start, right: rhsDFA.start)]
        var head = 0
        result.addState()
        stateMap[queue[0]] = 0
        while head < queue.count {
            let pair = queue[head]
            head &+= 1
            let source = stateMap[pair].unsafelyUnwrapped
            if lhsDFA.isEndState(pair.left), rhsDFA.isEndState(pair.right) { result.addEndState(source) }
            for lhsEdge in lhsDFA.fsm.edges(of: pair.left) {
                for rhsEdge in rhsDFA.fsm.edges(of: pair.right) {
                    assert(lhsEdge.isCharRange && rhsEdge.isCharRange)
                    if lhsEdge.min > rhsEdge.max || rhsEdge.min > lhsEdge.max { continue }
                    let low = max(lhsEdge.min, rhsEdge.min)
                    let high = min(lhsEdge.max, rhsEdge.max)
                    let targetPair = Pair(left: lhsEdge.target, right: rhsEdge.target)
                    let target: Int32
                    if let existing = stateMap[targetPair] {
                        target = existing
                    } else {
                        if result.stateCount >= maxStates {
                            throw .compilation("The number of states in the intersection exceeds the limit.")
                        }
                        target = result.addState()
                        stateMap[targetPair] = target
                        queue.append(targetPair)
                    }
                    result.fsm.addEdge(from: source, to: target, min: low, max: high)
                }
            }
        }
        return result
    }

    // MARK: Properties

    /// Checks (and caches) determinism: no epsilon edges and no overlapping byte or rule edges.
    mutating func checkIsDFA() -> Bool {
        if isDFA { return true }
        for state in 0 ..< Int32(stateCount) {
            var bytes = ByteSet()
            var rules = Set<Int32>()
            for edge in fsm.edges(of: state) {
                if edge.isEpsilon { return false }
                if edge.isCharRange {
                    for value in edge.min ... edge.max {
                        let byte = UInt8(truncatingIfNeeded: value)
                        if bytes.contains(byte) { return false }
                        bytes.insert(byte)
                    }
                } else if edge.isRuleRef {
                    if !rules.insert(edge.ruleID).inserted { return false }
                }
            }
        }
        isDFA = true
        return true
    }

    // MARK: Reducers

    /// Merges states joined by removable epsilon edges: `a --ε--> b` where `a` has no other
    /// outgoing edge, or `b` no other incoming edge.
    consuming func simplifyingEpsilon(maxStates: Int = 100_000_000) -> FSMWithStartEnd {
        if isDFA || stateCount > maxStates { return self }
        var workspace = FSMReductionWorkspace(self)
        guard workspace.simplifyEpsilon() else { return self }
        return workspace.makeFSM(auxData: fsm.auxData)
    }

    /// Merges locally equivalent states until a fixed point: siblings entered by identical
    /// labels from one source, sources leaving by identical labels to one target, and all
    /// terminal states of equal acceptance.
    consuming func mergingEquivalentStates(maxStates: Int = 100_000) -> FSMWithStartEnd {
        if maxStates < stateCount { return self }
        if stateCount < 4 { return self }
        var workspace = FSMReductionWorkspace(self)
        workspace.sortRows()
        guard workspace.mergeEquivalentStates() else {
            fsm.sortEdges()
            return self
        }
        return workspace.makeFSM(auxData: fsm.auxData)
    }

    /// `simplifyingEpsilon().mergingEquivalentStates()` with default limits, in one workspace:
    /// the automaton between the two steps is never turned back into per-state rows.
    consuming func reduced() -> FSMWithStartEnd {
        if stateCount > 100_000_000 { return self }
        var workspace = FSMReductionWorkspace(self)
        let simplified = !isDFA && workspace.simplifyEpsilon()
        if workspace.stateCount > 100_000 || workspace.stateCount < 4 {
            return simplified ? workspace.makeFSM(auxData: fsm.auxData) : self
        }
        workspace.sortRows()
        let merged = workspace.mergeEquivalentStates()
        guard simplified || merged else {
            fsm.sortEdges()
            return self
        }
        return workspace.makeFSM(auxData: fsm.auxData)
    }

    // MARK: Determinization

    /// Subset construction. Byte edges are split on the boundaries of every overlapping range;
    /// rule, repeat and token edges are grouped by their value.
    func determinized(maxStates: Int = 1000) throws(GrammarError) -> FSMWithStartEnd {
        if stateCount > maxStates { throw .compilation("The number of states exceeds the limit.") }
        var dfa = FSMWithStartEnd(fsm: FSM(), start: 0, ends: [], isDFA: true)
        var closures: [Set<Int32>] = []
        var initial: Set<Int32> = [start]
        fsm.expandEpsilonClosure(&initial)
        closures.append(initial)
        var closureIndices: [Set<Int32>: Int] = [initial: 0]

        func closureIndex(of closure: Set<Int32>) -> Int? {
            closureIndices[closure]
        }

        var current = 0
        while current < closures.count {
            var rules = Set<Int32>()
            var repeatAux = Set<Int32>()
            var tokenAux = Set<Int32>()
            var excludeAux = Set<Int32>()
            var intervalEnds = Set<Int32>()
            var allowed = ByteSet()
            dfa.addState()
            let closure = closures[current]
            for state in closure {
                if isEndState(state) { dfa.addEndState(Int32(current)) }
                for edge in fsm.edges(of: state) {
                    if edge.isCharRange {
                        intervalEnds.insert(edge.min)
                        intervalEnds.insert(edge.max &+ 1)
                        allowed.insert(range: edge.min ... edge.max)
                    } else if edge.isRuleRef {
                        rules.insert(edge.ruleID)
                    } else if edge.isRepeatRef {
                        repeatAux.insert(edge.auxIndex)
                    } else if edge.isToken {
                        tokenAux.insert(edge.auxIndex)
                    } else if edge.isExcludeToken {
                        excludeAux.insert(edge.auxIndex)
                    }
                }
            }

            var intervals: [ClosedRange<Int32>] = []
            var last: Int32 = -1
            for end in intervalEnds.sorted() {
                if last == -1 {
                    last = end
                    continue
                }
                var isAllowed = true
                for value in last ..< end where !allowed.contains(value) {
                    isAllowed = false
                    break
                }
                if isAllowed { intervals.append(last ... end &- 1) }
                last = end
            }

            func nextClosure(_ accepts: (FSMEdge) -> Bool) -> Set<Int32> {
                var next = Set<Int32>()
                for state in closure {
                    for edge in fsm.edges(of: state) where accepts(edge) && !next.contains(edge.target) {
                        var epsilon: Set<Int32> = [edge.target]
                        fsm.expandEpsilonClosure(&epsilon)
                        next.formUnion(epsilon)
                    }
                }
                return next
            }

            func link(_ next: Set<Int32>, _ addEdge: (inout FSM, Int32) -> Void) throws(GrammarError) {
                if let existing = closureIndex(of: next) {
                    addEdge(&dfa.fsm, Int32(existing))
                } else {
                    if closures.count >= maxStates { throw .compilation("The number of DFA states exceeds the limit.") }
                    addEdge(&dfa.fsm, Int32(closures.count))
                    closureIndices[next] = closures.count
                    closures.append(next)
                }
            }

            let source = Int32(current)
            for interval in intervals {
                let next = nextClosure { $0.isCharRange && interval.lowerBound >= $0.min && interval.upperBound <= $0.max }
                try link(next) { $0.addEdge(from: source, to: $1, min: interval.lowerBound, max: interval.upperBound) }
            }
            for rule in rules.sorted() {
                let next = nextClosure { $0.isRuleRef && $0.ruleID == rule }
                try link(next) { $0.addRuleEdge(from: source, to: $1, ruleID: rule) }
            }
            for aux in repeatAux.sorted() {
                let next = nextClosure { $0.isRepeatRef && $0.auxIndex == aux }
                try link(next) { $0.addEdge(from: source, to: $1, kind: .repeatRef, value: aux) }
            }
            for aux in tokenAux.sorted() {
                let next = nextClosure { $0.isToken && $0.auxIndex == aux }
                try link(next) { $0.addEdge(from: source, to: $1, kind: .token, value: aux) }
            }
            for aux in excludeAux.sorted() {
                let next = nextClosure { $0.isExcludeToken && $0.auxIndex == aux }
                try link(next) { $0.addEdge(from: source, to: $1, kind: .excludeToken, value: aux) }
            }
            current &+= 1
        }
        dfa.fsm.auxData = fsm.auxData
        dfa.isDFA = true
        return dfa
    }

    /// The minimal DFA under exact edge labels (determinizing first if needed), by Moore
    /// refinement: a state's class is its previous class plus its labelled transitions into
    /// classes, until no class splits. Classes are numbered by their first state, so the result
    /// is deterministic. Partition splitting against every class per label (Hopcroft over
    /// `Set`s) was quadratic: 190 ms for a 6,400-state key-exclusion automaton.
    func minimized(maxStates: Int = 1000) throws(GrammarError) -> FSMWithStartEnd {
        if stateCount > maxStates { throw .compilation("The number of states exceeds the limit.") }
        let dfa = isDFA ? self : try determinized(maxStates: maxStates)
        let n = dfa.stateCount
        let rows = (0 ..< n).map { state in
            dfa.fsm.edges(of: Int32(state)).sorted { ($0.min, $0.max) < ($1.min, $1.max) }
        }
        var classes = (0 ..< n).map { dfa.isEndState(Int32($0)) ? Int32(1) : 0 }
        var classCount = Set(classes).count
        var next = [Int32](repeating: 0, count: n)
        var signature: [Int32] = []
        var ids: [[Int32]: Int32] = [:]
        while true {
            ids.removeAll(keepingCapacity: true)
            for state in 0 ..< n {
                signature.removeAll(keepingCapacity: true)
                signature.append(classes[state])
                for edge in rows[state] {
                    signature.append(edge.min)
                    signature.append(edge.max)
                    signature.append(classes[Int(edge.target)])
                }
                if let id = ids[signature] {
                    next[state] = id
                } else {
                    let id = Int32(ids.count)
                    ids[signature] = id
                    next[state] = id
                }
            }
            swap(&classes, &next)
            if ids.count == classCount { break }
            classCount = ids.count
        }
        return dfa.rebuilt(mapping: classes, stateCount: classCount)
    }
}

/// An automaton in CSR form (one edge array plus row offsets) with every scratch buffer the
/// reducers need, allocated once and sized by the input: reducing never adds states or edges.
/// Upstream's reducers rebuild per-state rows after each step and each merge round; here rows
/// are built once, by ``makeFSM(auxData:)``, which keeps small automata from being dominated
/// by row allocation and reference counting.
private struct FSMReductionWorkspace: ~Copyable {
    struct EndpointEdge: Comparable {
        var peer: Int32
        var min: Int32
        var max: Int32
        static func < (lhs: EndpointEdge, rhs: EndpointEdge) -> Bool {
            if lhs.peer != rhs.peer { return lhs.peer < rhs.peer }
            if lhs.min != rhs.min { return lhs.min < rhs.min }
            return lhs.max < rhs.max
        }
    }

    private(set) var stateCount: Int
    private var start: Int32

    private let ints: UnsafeMutableBufferPointer<Int32>
    private let edgeStorage: UnsafeMutableBufferPointer<FSMEdge>
    private let endpointStorage: UnsafeMutableBufferPointer<EndpointEdge>

    private var rowStart: UnsafeMutablePointer<Int32>
    private var nextRowStart: UnsafeMutablePointer<Int32>
    private var edges: UnsafeMutablePointer<FSMEdge>
    private var nextEdges: UnsafeMutablePointer<FSMEdge>
    private let outgoing: UnsafeMutablePointer<EndpointEdge>
    private let incoming: UnsafeMutablePointer<EndpointEdge>
    private let incomingStart: UnsafeMutablePointer<Int32>
    private let fill: UnsafeMutablePointer<Int32>
    private let incomingDistinct: UnsafeMutablePointer<Int32>
    private let outgoingDistinct: UnsafeMutablePointer<Int32>
    private let singleSource: UnsafeMutablePointer<Int32>
    private let singleTarget: UnsafeMutablePointer<Int32>
    private let isEnd: UnsafeMutablePointer<Int32>
    private let present: UnsafeMutablePointer<Int32>
    private let parent: UnsafeMutablePointer<Int32>
    private let size: UnsafeMutablePointer<Int32>
    private let mapping: UnsafeMutablePointer<Int32>
    private let scratch: UnsafeMutablePointer<Int32>
    private let terminalEnds: UnsafeMutablePointer<Int32>
    private let terminalNonEnds: UnsafeMutablePointer<Int32>

    /// Loads `fsm` with its rows in their current order.
    init(_ fsm: borrowing FSMWithStartEnd) {
        let capacity = fsm.stateCount
        var edgeCapacity = 0
        for state in 0 ..< Int32(capacity) { edgeCapacity &+= fsm.fsm.edges(of: state).count }
        let edgeSlots = Swift.max(edgeCapacity, 1)

        ints = .allocate(capacity: 4 &* (capacity &+ 1) &+ 12 &* capacity)
        ints.initialize(repeating: 0)
        edgeStorage = .allocate(capacity: 2 &* edgeSlots)
        edgeStorage.initialize(repeating: FSMEdge(min: 0, max: 0, target: 0))
        endpointStorage = .allocate(capacity: 2 &* edgeSlots)
        endpointStorage.initialize(repeating: EndpointEdge(peer: 0, min: 0, max: 0))

        var cursor = ints.baseAddress.unsafelyUnwrapped
        func carve(_ count: Int) -> UnsafeMutablePointer<Int32> {
            defer { cursor += count }
            return cursor
        }
        rowStart = carve(capacity &+ 1)
        nextRowStart = carve(capacity &+ 1)
        incomingStart = carve(capacity &+ 1)
        fill = carve(capacity &+ 1)
        incomingDistinct = carve(capacity)
        outgoingDistinct = carve(capacity)
        singleSource = carve(capacity)
        singleTarget = carve(capacity)
        isEnd = carve(capacity)
        present = carve(capacity)
        parent = carve(capacity)
        size = carve(capacity)
        mapping = carve(capacity)
        scratch = carve(capacity)
        terminalEnds = carve(capacity)
        terminalNonEnds = carve(capacity)
        edges = edgeStorage.baseAddress.unsafelyUnwrapped
        nextEdges = edges + edgeSlots
        outgoing = endpointStorage.baseAddress.unsafelyUnwrapped
        incoming = outgoing + edgeSlots

        stateCount = capacity
        start = fsm.start
        var edgeCount = 0
        for state in 0 ..< capacity {
            for edge in fsm.fsm.edges(of: Int32(state)) {
                edges[edgeCount] = edge
                edgeCount &+= 1
            }
            rowStart[state &+ 1] = Int32(edgeCount)
        }
        for end in fsm.ends { isEnd[Int(end)] = 1 }
    }

    deinit {
        ints.deallocate()
        edgeStorage.deallocate()
        endpointStorage.deallocate()
    }

    /// The reduced automaton (never a DFA, like upstream's rebuilt automata).
    func makeFSM(auxData: [Int32]) -> FSMWithStartEnd {
        var rows: [[FSMEdge]] = []
        rows.reserveCapacity(stateCount)
        var ends: [Int32] = []
        for state in 0 ..< stateCount {
            let begin = Int(rowStart[state])
            rows.append(Array(UnsafeBufferPointer(start: edges + begin, count: Int(rowStart[state &+ 1]) &- begin)))
            if isEnd[state] != 0 { ends.append(Int32(state)) }
        }
        return FSMWithStartEnd(fsm: FSM(edges: rows, auxData: auxData), start: start, ends: ends)
    }

    /// Sorts every row (without deduplicating), as `FSM.sortEdges()` does.
    mutating func sortRows() {
        for state in 0 ..< stateCount {
            let begin = Int(rowStart[state]), end = Int(rowStart[state &+ 1])
            if end &- begin > 1 { sortInPlace(edges + begin, end &- begin) }
        }
    }

    // MARK: Union-find over the current states

    private func resetSets() {
        for state in 0 ..< stateCount {
            present[state] = 0
            parent[state] = Int32(state)
            size[state] = 1
        }
    }

    private func find(_ element: Int32) -> Int32 {
        var root = element
        while parent[Int(root)] != root { root = parent[Int(root)] }
        var current = element
        while parent[Int(current)] != root {
            let next = parent[Int(current)]
            parent[Int(current)] = root
            current = next
        }
        return root
    }

    private func unite(_ a: Int32, _ b: Int32) {
        present[Int(a)] = 1
        present[Int(b)] = 1
        var rootA = find(a), rootB = find(b)
        if rootA == rootB { return }
        if size[Int(rootA)] < size[Int(rootB)] { swap(&rootA, &rootB) }
        parent[Int(rootB)] = rootA
        size[Int(rootA)] &+= size[Int(rootB)]
    }

    /// Renumbers states by class (merged classes first, by smallest member; then the untouched
    /// states in order) and rebuilds the rows: epsilon self-loops dropped, each row sorted and
    /// deduplicated. Upstream's `RebuildWithMapping` after `GetAllSets`.
    private mutating func mergeSets() {
        let n = stateCount
        for state in 0 ..< n { scratch[state] = -1 }
        var count: Int32 = 0
        for state in 0 ..< n where present[state] != 0 {
            let root = Int(find(Int32(state)))
            if scratch[root] < 0 {
                scratch[root] = count
                count &+= 1
            }
            mapping[state] = scratch[root]
        }
        for state in 0 ..< n where present[state] == 0 {
            mapping[state] = count
            count &+= 1
        }
        let newCount = Int(count)

        nextRowStart.update(repeating: 0, count: newCount &+ 1)
        for source in 0 ..< n {
            let from = mapping[source]
            for index in Int(rowStart[source]) ..< Int(rowStart[source &+ 1]) {
                let edge = edges[index]
                if edge.isEpsilon, mapping[Int(edge.target)] == from { continue }
                nextRowStart[Int(from) &+ 1] &+= 1
            }
        }
        for state in 0 ..< newCount { nextRowStart[state &+ 1] &+= nextRowStart[state] }
        fill.update(from: nextRowStart, count: newCount &+ 1)
        for source in 0 ..< n {
            let from = mapping[source]
            for index in Int(rowStart[source]) ..< Int(rowStart[source &+ 1]) {
                let edge = edges[index]
                let to = mapping[Int(edge.target)]
                if edge.isEpsilon, to == from { continue }
                nextEdges[Int(fill[Int(from)])] = FSMEdge(min: edge.min, max: edge.max, target: to)
                fill[Int(from)] &+= 1
            }
        }
        // Rows only shrink when deduplicated, so compacting forward in place is safe.
        var write = 0
        for state in 0 ..< newCount {
            let begin = Int(nextRowStart[state]), end = Int(nextRowStart[state &+ 1])
            nextRowStart[state] = Int32(write)
            if end &- begin > 1 { sortInPlace(nextEdges + begin, end &- begin) }
            for read in begin ..< end where read == begin || nextEdges[read] != nextEdges[read &- 1] {
                nextEdges[write] = nextEdges[read]
                write &+= 1
            }
        }
        nextRowStart[newCount] = Int32(write)
        swap(&rowStart, &nextRowStart)
        swap(&edges, &nextEdges)

        scratch.update(repeating: 0, count: newCount)
        for state in 0 ..< n where isEnd[state] != 0 { scratch[Int(mapping[state])] = 1 }
        isEnd.update(from: scratch, count: newCount)
        start = mapping[Int(start)]
        stateCount = newCount
    }

    // MARK: Epsilon simplification

    /// Upstream `SimplifyEpsilon`. Returns whether any states were merged.
    mutating func simplifyEpsilon() -> Bool {
        let n = stateCount
        let inDegree = incomingDistinct, hasExcludeToken = outgoingDistinct, equivalent = singleSource
        let pairs = incoming
        resetSets()
        for state in 0 ..< n {
            inDegree[state] = 0
            hasExcludeToken[state] = 0
            for index in Int(rowStart[state]) ..< Int(rowStart[state &+ 1]) where edges[index].isExcludeToken {
                hasExcludeToken[state] = 1
                break
            }
        }

        var pairCount = 0
        var anyMerged = false
        for state in 0 ..< n {
            let begin = Int(rowStart[state]), end = Int(rowStart[state &+ 1])
            for index in begin ..< end {
                let edge = edges[index]
                let target = Int(edge.target)
                inDegree[target] &+= 1
                guard edge.isEpsilon else { continue }
                // Do not merge an accepting `a` into a non-accepting `b`: the merged state would
                // accept, so other paths reaching `b` would wrongly accept too.
                if end &- begin == 1, hasExcludeToken[state] == 0, hasExcludeToken[target] == 0,
                   isEnd[state] == 0 || isEnd[target] != 0 {
                    unite(Int32(state), edge.target)
                    anyMerged = true
                    inDegree[target] &-= 1
                } else {
                    pairs[pairCount] = EndpointEdge(peer: Int32(state), min: edge.target, max: 0)
                    pairCount &+= 1
                }
            }
        }

        for state in 0 ..< n {
            if present[state] != 0 {
                let root = find(Int32(state))
                equivalent[state] = root
                if Int(root) != state { inDegree[Int(root)] &+= inDegree[state] }
            } else {
                equivalent[state] = Int32(state)
            }
        }

        let startClass = equivalent[Int(start)]
        for index in 0 ..< pairCount {
            let fromRaw = Int(pairs[index].peer), toRaw = Int(pairs[index].min)
            let from = equivalent[fromRaw], to = equivalent[toRaw]
            if inDegree[Int(to)] == 1, startClass != to, hasExcludeToken[fromRaw] == 0, hasExcludeToken[toRaw] == 0 {
                unite(from, to)
                anyMerged = true
            }
        }

        guard anyMerged else { return false }
        mergeSets()
        return true
    }

    // MARK: Equivalent-state merging

    /// Upstream `MergeEquivalentStates` on sorted rows. Each round merges what it can and
    /// renumbers, so a long shared suffix takes one round per state (upstream runs the same
    /// rounds; the numbering depends on them). Returns whether any states were merged.
    mutating func mergeEquivalentStates() -> Bool {
        var changedAny = false
        while true {
            let n = stateCount
            resetSets()
            incomingStart.update(repeating: 0, count: n &+ 1)
            for source in 0 ..< n {
                let begin = Int(rowStart[source]), end = Int(rowStart[source &+ 1])
                for index in begin ..< end {
                    let edge = edges[index]
                    outgoing[index] = EndpointEdge(peer: edge.target, min: edge.min, max: edge.max)
                    incomingStart[Int(edge.target) &+ 1] &+= 1
                }
                if end &- begin > 1 { sortInPlace(outgoing + begin, end &- begin) }
            }
            for state in 0 ..< n { incomingStart[state &+ 1] &+= incomingStart[state] }
            fill.update(from: incomingStart, count: n &+ 1)
            for source in 0 ..< n {
                for index in Int(rowStart[source]) ..< Int(rowStart[source &+ 1]) {
                    let edge = edges[index]
                    let target = Int(edge.target)
                    incoming[Int(fill[target])] = EndpointEdge(peer: Int32(source), min: edge.min, max: edge.max)
                    fill[target] &+= 1
                }
            }

            for state in 0 ..< n {
                incomingDistinct[state] = 0
                singleSource[state] = -1
                let inBegin = Int(incomingStart[state]), inEnd = Int(incomingStart[state &+ 1])
                if inBegin < inEnd {
                    incomingDistinct[state] = 1
                    singleSource[state] = incoming[inBegin].peer
                    for index in inBegin &+ 1 ..< inEnd where incoming[index].peer != incoming[index &- 1].peer {
                        incomingDistinct[state] &+= 1
                        singleSource[state] = -1
                    }
                }
                outgoingDistinct[state] = 0
                singleTarget[state] = -1
                let outBegin = Int(rowStart[state]), outEnd = Int(rowStart[state &+ 1])
                if outBegin < outEnd {
                    outgoingDistinct[state] = 1
                    singleTarget[state] = outgoing[outBegin].peer
                    for index in outBegin &+ 1 ..< outEnd where outgoing[index].peer != outgoing[index &- 1].peer {
                        outgoingDistinct[state] &+= 1
                        singleTarget[state] = -1
                    }
                }
            }

            // Case 1: ab | ac | ad → a(b | c | d).
            var changed = false
            for index in 0 ..< n {
                let state = Int32(index)
                if incomingDistinct[index] != 1 || present[index] != 0 || state == start { continue }
                let previous = Int(singleSource[index])
                let toStateBegin = Int(incomingStart[index]), toStateCount = Int(incomingStart[index &+ 1]) &- toStateBegin
                var groupBegin = Int(rowStart[previous])
                let siblingsEnd = Int(rowStart[previous &+ 1])
                while groupBegin < siblingsEnd {
                    let sibling = outgoing[groupBegin].peer
                    var groupEnd = groupBegin &+ 1
                    while groupEnd < siblingsEnd, outgoing[groupEnd].peer == sibling { groupEnd &+= 1 }
                    let toSiblingBegin = groupBegin
                    groupBegin = groupEnd
                    if sibling <= state || incomingDistinct[Int(sibling)] != 1 || sibling == start
                        || isEnd[Int(sibling)] != isEnd[index] || toStateCount != groupEnd &- toSiblingBegin {
                        continue
                    }
                    var equivalent = true
                    for offset in 0 ..< toStateCount {
                        let a = incoming[toStateBegin &+ offset], b = outgoing[toSiblingBegin &+ offset]
                        if a.min != b.min || a.max != b.max {
                            equivalent = false
                            break
                        }
                    }
                    if equivalent {
                        unite(state, sibling)
                        changed = true
                    }
                }
            }

            // Case 2: ba | ca | da → (b | c | d)a.
            var terminalEndCount = 0, terminalNonEndCount = 0
            for index in 0 ..< n {
                let state = Int32(index)
                let outCount = outgoingDistinct[index]
                if outCount == 0 {
                    if isEnd[index] != 0 {
                        terminalEnds[terminalEndCount] = state
                        terminalEndCount &+= 1
                    } else {
                        terminalNonEnds[terminalNonEndCount] = state
                        terminalNonEndCount &+= 1
                    }
                    continue
                }
                if outCount != 1 || present[index] != 0 { continue }
                let next = Int(singleTarget[index])
                let nodeBegin = Int(rowStart[index]), nodeCount = Int(rowStart[index &+ 1]) &- nodeBegin
                var groupBegin = Int(incomingStart[next])
                let siblingsEnd = Int(incomingStart[next &+ 1])
                while groupBegin < siblingsEnd {
                    let sibling = incoming[groupBegin].peer
                    while groupBegin < siblingsEnd, incoming[groupBegin].peer == sibling { groupBegin &+= 1 }
                    let siblingIndex = Int(sibling)
                    if sibling <= state || present[siblingIndex] != 0 || outgoingDistinct[siblingIndex] != 1
                        || isEnd[index] != isEnd[siblingIndex] {
                        continue
                    }
                    let siblingBegin = Int(rowStart[siblingIndex])
                    if Int(rowStart[siblingIndex &+ 1]) &- siblingBegin != nodeCount { continue }
                    var equivalent = true
                    for offset in 0 ..< nodeCount {
                        let a = outgoing[nodeBegin &+ offset], b = outgoing[siblingBegin &+ offset]
                        if a.min != b.min || a.max != b.max {
                            equivalent = false
                            break
                        }
                    }
                    if equivalent {
                        unite(state, sibling)
                        changed = true
                    }
                }
            }

            for other in 1 ..< Swift.max(terminalEndCount, 1) {
                unite(terminalEnds[0], terminalEnds[other])
                changed = true
            }
            for other in 1 ..< Swift.max(terminalNonEndCount, 1) {
                unite(terminalNonEnds[0], terminalNonEnds[other])
                changed = true
            }

            guard changed else { return changedAny }
            changedAny = true
            mergeSets()
        }
    }
}

/// Sorts `count` elements starting at `base`.
@inline(__always)
private func sortInPlace<Element: Comparable>(_ base: UnsafeMutablePointer<Element>, _ count: Int) {
    var buffer = UnsafeMutableBufferPointer(start: base, count: count)
    buffer.sort()
}
