// Finite-state automata used by the compiler and the Earley parser. `FSM` is the mutable graph
// used while building; `CompactFSM` is the immutable CSR form the matcher runs on. Both share one
// edge encoding (`FSMEdge`) so views over either (`FSMWithStartEnd`, `CompactFSMWithStartEnd`)
// expose the same traversal API.

/// One transition of an automaton.
///
/// The transition kind is folded into `min`: a non-negative `min` is an inclusive byte range
/// `[min, max]`; a negative `min` is one of ``FSMEdgeKind`` and `max` carries kind-specific data
/// (the rule id of a rule reference, or an index into the owning automaton's auxiliary data).
struct FSMEdge: Hashable, Sendable, Comparable {
    var min: Int32
    var max: Int32
    var target: Int32

    @inline(__always)
    init(min: Int32, max: Int32, target: Int32) {
        self.min = min
        self.max = max
        self.target = target
    }

    @inline(__always)
    init(kind: FSMEdgeKind, value: Int32, target: Int32) {
        self.min = kind.rawValue
        self.max = value
        self.target = target
    }

    static let maxByte: Int32 = 255

    @inline(__always) var isCharRange: Bool { min >= 0 }
    @inline(__always) var isEpsilon: Bool { min == FSMEdgeKind.epsilon.rawValue }
    @inline(__always) var isRuleRef: Bool { min == FSMEdgeKind.ruleRef.rawValue }
    @inline(__always) var isEOS: Bool { min == FSMEdgeKind.eos.rawValue }
    @inline(__always) var isRepeatRef: Bool { min == FSMEdgeKind.repeatRef.rawValue }
    @inline(__always) var isToken: Bool { min == FSMEdgeKind.token.rawValue }
    @inline(__always) var isExcludeToken: Bool { min == FSMEdgeKind.excludeToken.rawValue }
    /// Whether `max` indexes the auxiliary data table.
    @inline(__always) var isAuxEdge: Bool { isRepeatRef || isToken || isExcludeToken }

    /// Rule id for rule-reference edges, `-1` otherwise.
    @inline(__always) var ruleID: Int32 { isRuleRef ? max : -1 }
    /// Auxiliary-data index for repeat/token edges, `-1` otherwise.
    @inline(__always) var auxIndex: Int32 { isAuxEdge ? max : -1 }

    @inline(__always)
    static func < (lhs: FSMEdge, rhs: FSMEdge) -> Bool {
        if lhs.min != rhs.min { return lhs.min < rhs.min }
        if lhs.max != rhs.max { return lhs.max < rhs.max }
        return lhs.target < rhs.target
    }
}

/// Special edge kinds, stored in ``FSMEdge/min``.
enum FSMEdgeKind: Int32, Sendable {
    /// Byte range `[min, max]`; the only non-negative kind.
    case charRange = 0
    /// Free transition.
    case epsilon = -1
    /// Enter the rule `max`; the edge is taken when the rule completes.
    case ruleRef = -2
    /// Accepts the end-of-sequence token.
    case eos = -3
    /// Counted rule repetition; `max` indexes `[ruleID, lower, upper]` in the aux table.
    /// A state with a repeat edge has exactly that one outgoing edge.
    case repeatRef = -4
    /// Accepts one token from a set; `max` indexes `[count, id…]` in the aux table.
    case token = -5
    /// Accepts one token outside a set; `max` indexes `[count, id…]` in the aux table.
    case excludeToken = -6
}

/// Decoded auxiliary data of a repeat edge.
struct RepeatEdgeInfo: Sendable {
    var ruleID: Int32
    var lower: Int32
    var upper: Int32
}

/// Decoded auxiliary data of a token / exclude-token edge: a slice of token ids.
struct TokenEdgeInfo: Sendable {
    let tokenIDs: ArraySlice<Int32>

    @inline(__always)
    func contains(_ tokenID: Int32) -> Bool { tokenIDs.contains(tokenID) }
}

// MARK: - Shared traversal

/// Operations common to the mutable and compact automata. Implementers provide random access to
/// a state's edges and to the auxiliary table.
protocol FSMGraph {
    associatedtype Edges: RandomAccessCollection<FSMEdge>
    var stateCount: Int { get }
    var auxData: [Int32] { get }
    func edges(of state: Int32) -> Edges
}

extension FSMGraph {
    @inline(__always)
    func repeatInfo(at auxIndex: Int32) -> RepeatEdgeInfo {
        let base = Int(auxIndex)
        return RepeatEdgeInfo(ruleID: auxData[base], lower: auxData[base &+ 1], upper: auxData[base &+ 2])
    }

    @inline(__always)
    func tokenInfo(at auxIndex: Int32) -> TokenEdgeInfo {
        let base = Int(auxIndex)
        let count = Int(auxData[base])
        return TokenEdgeInfo(tokenIDs: auxData[(base &+ 1) ..< (base &+ 1 &+ count)])
    }

    /// Grows `states` to its closure under epsilon transitions.
    func expandEpsilonClosure(_ states: inout Set<Int32>) {
        var queue = Array(states)
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head &+= 1
            for edge in edges(of: current) where edge.isEpsilon {
                if states.insert(edge.target).inserted { queue.append(edge.target) }
            }
        }
    }

    /// Rule ids referenced by the outgoing rule edges of `state`.
    func possibleRules(from state: Int32) -> Set<Int32> {
        var rules = Set<Int32>()
        for edge in edges(of: state) where edge.isRuleRef { rules.insert(edge.ruleID) }
        return rules
    }

    /// Every state reachable from `from` over any edge, including `from` itself.
    func reachableStates(from: some Sequence<Int32>) -> Set<Int32> {
        var result = Set<Int32>()
        var queue: [Int32] = []
        for state in from where result.insert(state).inserted { queue.append(state) }
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head &+= 1
            for edge in edges(of: current) where result.insert(edge.target).inserted {
                queue.append(edge.target)
            }
        }
        return result
    }

    /// Follows the edges matching `value` of kind `kind` out of every state of `from`, then
    /// takes the epsilon closure of the targets. `from` is first closed under epsilon unless
    /// `fromIsClosure` is set.
    func advance(from: Set<Int32>, value: Int32, kind: FSMEdgeKind = .charRange, fromIsClosure: Bool = false) -> Set<Int32> {
        var closure = from
        if !fromIsClosure { expandEpsilonClosure(&closure) }
        var result = Set<Int32>()
        for state in closure {
            for edge in edges(of: state) {
                switch kind {
                case .charRange:
                    if edge.isCharRange, edge.min <= value, edge.max >= value { result.insert(edge.target) }
                case .ruleRef:
                    if edge.isRuleRef, edge.max == value { result.insert(edge.target) }
                case .eos:
                    if edge.isEOS { result.insert(edge.target) }
                case .repeatRef:
                    if edge.isRepeatRef { result.insert(edge.target) }
                case .token, .excludeToken, .epsilon:
                    preconditionFailure("advance does not support edge kind \(kind)")
                }
            }
        }
        expandEpsilonClosure(&result)
        return result
    }

    /// Debug rendering of the edge table (`states` restricts and orders the rows).
    func edgesDescription(states: [Int32]? = nil) -> String {
        var result = "[\n"
        func describe(_ state: Int32) {
            result += "\(state): ["
            let row = edges(of: state)
            var first = true
            for edge in row {
                if !first { result += ", " }
                first = false
                if edge.isCharRange {
                    if edge.min == edge.max {
                        result += "'"
                        EscapeCodec.escape(edge.min, into: &result)
                        result += "'"
                    } else {
                        result += "["
                        EscapeCodec.escape(edge.min, into: &result)
                        result += "-"
                        EscapeCodec.escape(edge.max, into: &result)
                        result += "]"
                    }
                } else if edge.isRuleRef {
                    result += "Rule(\(edge.max))"
                } else if edge.isEpsilon {
                    result += "Eps"
                } else if edge.isEOS {
                    result += "EOS"
                } else if edge.isRepeatRef {
                    let info = repeatInfo(at: edge.max)
                    result += "Repeat(rule=\(info.ruleID), min=\(info.lower), max=\(info.upper))"
                } else if edge.isToken || edge.isExcludeToken {
                    result += edge.isToken ? "Token(" : "ExcludeToken("
                    result += tokenInfo(at: edge.max).tokenIDs.map(String.init).joined(separator: ", ")
                    result += ")"
                }
                result += "->\(edge.target)"
            }
            result += "]\n"
        }
        if let states {
            for state in states { describe(state) }
        } else {
            for state in 0 ..< Int32(stateCount) { describe(state) }
        }
        result += "]"
        return result
    }
}

// MARK: - FSM

/// A mutable automaton: an adjacency list per state plus the auxiliary table referenced by
/// repeat and token edges.
struct FSM: FSMGraph, Sendable {
    static let noNextState: Int32 = -1

    private(set) var edges: [[FSMEdge]]
    var auxData: [Int32]

    init(stateCount: Int = 0) {
        edges = Array(repeating: [], count: stateCount)
        auxData = []
    }

    init(edges: [[FSMEdge]], auxData: [Int32] = []) {
        self.edges = edges
        self.auxData = auxData
    }

    @inline(__always) var stateCount: Int { edges.count }

    @inline(__always)
    func edges(of state: Int32) -> [FSMEdge] { edges[Int(state)] }

    /// Replaces the outgoing edges of `state`.
    mutating func setEdges(of state: Int32, _ newEdges: [FSMEdge]) { edges[Int(state)] = newEdges }

    /// In-place access to the outgoing edges of `state`.
    mutating func withEdges<R>(of state: Int32, _ body: (inout [FSMEdge]) -> R) -> R {
        body(&edges[Int(state)])
    }

    // MARK: Mutation

    @discardableResult
    mutating func addState() -> Int32 {
        edges.append([])
        return Int32(edges.count &- 1)
    }

    mutating func addEdge(from: Int32, to: Int32, min: Int32, max: Int32) {
        edges[Int(from)].append(FSMEdge(min: min, max: max, target: to))
    }

    mutating func addEdge(from: Int32, to: Int32, kind: FSMEdgeKind, value: Int32) {
        edges[Int(from)].append(FSMEdge(kind: kind, value: value, target: to))
    }

    mutating func addEpsilonEdge(from: Int32, to: Int32) { addEdge(from: from, to: to, kind: .epsilon, value: 0) }
    mutating func addRuleEdge(from: Int32, to: Int32, ruleID: Int32) { addEdge(from: from, to: to, kind: .ruleRef, value: ruleID) }
    mutating func addEOSEdge(from: Int32, to: Int32) { addEdge(from: from, to: to, kind: .eos, value: 0) }

    mutating func addRepeatEdge(from: Int32, to: Int32, ruleID: Int32, lower: Int32, upper: Int32) {
        assert(edges[Int(from)].isEmpty, "A state with a repeat edge must have no other outgoing edges.")
        let auxIndex = Int32(auxData.count)
        auxData.append(ruleID)
        auxData.append(lower)
        auxData.append(upper)
        addEdge(from: from, to: to, kind: .repeatRef, value: auxIndex)
    }

    mutating func addTokenEdge(from: Int32, to: Int32, tokenIDs: some Collection<Int32>) {
        assert(!tokenIDs.isEmpty, "Token set must not be empty")
        let auxIndex = Int32(auxData.count)
        auxData.append(Int32(tokenIDs.count))
        auxData.append(contentsOf: tokenIDs)
        addEdge(from: from, to: to, kind: .token, value: auxIndex)
    }

    mutating func addExcludeTokenEdge(from: Int32, to: Int32, tokenIDs: some Collection<Int32>) {
        let auxIndex = Int32(auxData.count)
        auxData.append(Int32(tokenIDs.count))
        auxData.append(contentsOf: tokenIDs)
        addEdge(from: from, to: to, kind: .excludeToken, value: auxIndex)
    }

    /// Appends every state and edge of `other`, returning the mapping from its state ids to the
    /// new ids (always `old + previousStateCount`).
    @discardableResult
    mutating func addFSM(_ other: FSM) -> [Int32] {
        let offset = Int32(edges.count)
        let auxOffset = Int32(auxData.count)
        auxData.append(contentsOf: other.auxData)
        edges.reserveCapacity(edges.count &+ other.edges.count)
        for row in other.edges {
            var mapped: [FSMEdge] = []
            mapped.reserveCapacity(row.count)
            for edge in row {
                let max = edge.isAuxEdge && auxOffset > 0 ? edge.max &+ auxOffset : edge.max
                mapped.append(FSMEdge(min: edge.min, max: max, target: edge.target &+ offset))
            }
            edges.append(mapped)
        }
        return (0 ..< Int32(other.edges.count)).map { $0 &+ offset }
    }

    // MARK: Traversal

    /// First transition out of `from` accepting `value`, or ``noNextState``.
    func nextState(from: Int32, value: Int32, kind: FSMEdgeKind = .charRange) -> Int32 {
        let row = edges[Int(from)]
        switch kind {
        case .charRange:
            for edge in row where edge.isCharRange && edge.min <= value && edge.max >= value { return edge.target }
        case .ruleRef:
            for edge in row where edge.isRuleRef && edge.max == value { return edge.target }
        case .eos:
            for edge in row where edge.isEOS { return edge.target }
        case .repeatRef:
            assert(row.count == 1 && row[0].isRepeatRef)
            return row[0].target
        case .epsilon, .token, .excludeToken:
            preconditionFailure("nextState does not support edge kind \(kind)")
        }
        return Self.noNextState
    }

    // MARK: Construction helpers

    /// Renumbers states through `mapping` (several old states may merge into one), dropping
    /// epsilon self-loops and duplicate edges.
    func rebuilt(mapping: [Int32], stateCount newCount: Int) -> FSM {
        var newEdges = [[FSMEdge]](repeating: [], count: newCount)
        for (index, row) in edges.enumerated() {
            let from = mapping[index]
            for edge in row {
                let to = mapping[Int(edge.target)]
                if edge.isEpsilon, from == to { continue }
                newEdges[Int(from)].append(FSMEdge(min: edge.min, max: edge.max, target: to))
            }
        }
        for index in newEdges.indices {
            newEdges[index].sort()
            newEdges[index].removeDuplicatesSorted()
        }
        return FSM(edges: newEdges, auxData: auxData)
    }

    mutating func sortEdges() {
        for index in edges.indices where edges[index].count > 1 { edges[index].sort() }
    }

    /// Sorts the edges and packs them into a ``CompactFSM``.
    func compacted() -> CompactFSM {
        var copy = self
        copy.sortEdges()
        return CompactFSM(rows: copy.edges, auxData: copy.auxData)
    }
}

extension Array where Element: Equatable {
    /// Removes consecutive duplicates; the array must already be sorted.
    mutating func removeDuplicatesSorted() {
        guard count > 1 else { return }
        var write = 1
        for read in 1 ..< count where self[read] != self[write &- 1] {
            self[write] = self[read]
            write &+= 1
        }
        removeLast(count &- write)
    }
}

// MARK: - CompactFSM

/// An immutable automaton in CSR form: all edges in one buffer, sorted per state by
/// `(min, max, target)` so that special edges (negative `min`) precede byte ranges and scans can
/// stop early.
struct CompactFSM: FSMGraph, Sendable, Hashable {
    /// Start of each state's edges in ``edges``; has `stateCount + 1` entries.
    let offsets: [Int32]
    let edges: [FSMEdge]
    let auxData: [Int32]

    init(rows: [[FSMEdge]], auxData: [Int32]) {
        var offsets: [Int32] = []
        offsets.reserveCapacity(rows.count &+ 1)
        var flat: [FSMEdge] = []
        flat.reserveCapacity(rows.reduce(0) { $0 &+ $1.count })
        offsets.append(0)
        for row in rows {
            flat.append(contentsOf: row)
            offsets.append(Int32(flat.count))
        }
        self.offsets = offsets
        self.edges = flat
        self.auxData = auxData
    }

    init(offsets: [Int32], edges: [FSMEdge], auxData: [Int32]) {
        self.offsets = offsets
        self.edges = edges
        self.auxData = auxData
    }

    init() {
        self.init(offsets: [0], edges: [], auxData: [])
    }

    @inline(__always) var stateCount: Int { offsets.count &- 1 }
    @inline(__always) var edgeCount: Int { edges.count }

    @inline(__always)
    func edges(of state: Int32) -> ArraySlice<FSMEdge> {
        edges[Int(offsets[Int(state)]) ..< Int(offsets[Int(state) &+ 1])]
    }

    /// Appends every target reachable from `from` over an edge accepting `value` to `targets`.
    @inline(__always)
    func nextStates(from: Int32, value: Int32, kind: FSMEdgeKind = .charRange, into targets: inout [Int32]) {
        targets.removeAll(keepingCapacity: true)
        let row = edges(of: from)
        switch kind {
        case .charRange:
            for edge in row {
                if edge.min < 0 { continue }
                if edge.min > value { break }
                if edge.max >= value { targets.append(edge.target) }
            }
        case .ruleRef:
            let kindValue = FSMEdgeKind.ruleRef.rawValue
            for edge in row {
                if edge.min < kindValue { continue }
                if edge.min > kindValue { break }
                if edge.max == value { targets.append(edge.target) }
            }
        case .eos:
            let kindValue = FSMEdgeKind.eos.rawValue
            for edge in row {
                if edge.min < kindValue { continue }
                if edge.min > kindValue { break }
                targets.append(edge.target)
            }
        case .repeatRef:
            for edge in row where edge.isRepeatRef {
                targets.append(edge.target)
                break
            }
        case .epsilon, .token, .excludeToken:
            preconditionFailure("nextStates does not support edge kind \(kind)")
        }
    }

    /// Expands back into a mutable automaton.
    func expanded() -> FSM {
        var rows: [[FSMEdge]] = []
        rows.reserveCapacity(stateCount)
        for state in 0 ..< Int32(stateCount) { rows.append(Array(edges(of: state))) }
        return FSM(edges: rows, auxData: auxData)
    }

    /// Checks that every edge target and auxiliary reference is in range (used after
    /// deserialization, where the fields are restored verbatim).
    func validate() -> String? {
        let auxSize = auxData.count
        for state in 0 ..< Int32(stateCount) {
            for edge in edges(of: state) {
                if edge.target < 0 || Int(edge.target) >= stateCount {
                    return "Edge target \(edge.target) is out of range"
                }
                guard edge.isAuxEdge else { continue }
                let index = Int(edge.max)
                var inRange = index >= 0 && index < auxSize
                if inRange, edge.isRepeatRef {
                    inRange = index &+ 3 <= auxSize
                } else if inRange {
                    inRange = auxData[index] >= 0 && index &+ 1 &+ Int(auxData[index]) <= auxSize
                }
                if !inRange { return "Edge aux index \(index) is out of range" }
            }
        }
        return nil
    }
}

// MARK: - Start/end views

/// Behaviour shared by the mutable and compact start/end views.
protocol FSMWithStartEndProtocol {
    associatedtype Graph: FSMGraph
    var fsm: Graph { get }
    var start: Int32 { get }
    /// Sorted, deduplicated accepting states.
    var ends: [Int32] { get }
}

extension FSMWithStartEndProtocol {
    @inline(__always) var stateCount: Int { fsm.stateCount }

    @inline(__always)
    func isEndState(_ state: Int32) -> Bool { ends.binarySearchContains(state) }

    /// Whether `state` has an outgoing byte or token edge.
    func isScanableState(_ state: Int32) -> Bool {
        fsm.edges(of: state).contains { $0.isCharRange || $0.isToken || $0.isExcludeToken }
    }

    /// Whether `state` has an outgoing rule, repeat or epsilon edge.
    func isNonTerminalState(_ state: Int32) -> Bool {
        fsm.edges(of: state).contains { $0.isRuleRef || $0.isEpsilon || $0.isRepeatRef }
    }

    /// Whether the automaton accepts `bytes` from `start`.
    func accepts(_ bytes: some Sequence<UInt8>) -> Bool {
        var states: Set<Int32> = [start]
        fsm.expandEpsilonClosure(&states)
        for byte in bytes {
            states = fsm.advance(from: states, value: Int32(byte), kind: .charRange, fromIsClosure: true)
            if states.isEmpty { return false }
        }
        return states.contains { isEndState($0) }
    }

    func accepts(_ string: String) -> Bool { accepts(Array(string.utf8)) }

    /// States reachable from `start`.
    func reachableStates() -> Set<Int32> { fsm.reachableStates(from: CollectionOfOne(start)) }

    /// Whether no reachable state has a rule or repeat edge.
    var isLeaf: Bool {
        for state in reachableStates() {
            for edge in fsm.edges(of: state) where edge.isRuleRef || edge.isRepeatRef { return false }
        }
        return true
    }
}

extension Array where Element: Comparable {
    /// Binary search in a sorted array.
    @inline(__always)
    func binarySearchContains(_ value: Element) -> Bool {
        var low = 0
        var high = count
        while low < high {
            let mid = (low &+ high) >> 1
            let candidate = self[mid]
            if candidate == value { return true }
            if candidate < value { low = mid &+ 1 } else { high = mid }
        }
        return false
    }

    /// Insertion point keeping the array sorted.
    @inline(__always)
    func sortedInsertionIndex(of value: Element) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low &+ high) >> 1
            if self[mid] < value { low = mid &+ 1 } else { high = mid }
        }
        return low
    }
}

/// A mutable automaton with a start state and a set of accepting states.
struct FSMWithStartEnd: FSMWithStartEndProtocol, Sendable {
    var fsm: FSM
    var start: Int32
    private(set) var ends: [Int32]
    var isDFA: Bool

    init(fsm: FSM, start: Int32, ends: [Int32], isDFA: Bool = false) {
        self.fsm = fsm
        self.start = start
        self.ends = ends
        self.isDFA = isDFA
        normalizeEnds()
    }

    private mutating func normalizeEnds() {
        ends.sort()
        ends.removeDuplicatesSorted()
    }

    mutating func setEnds(_ newEnds: [Int32]) {
        ends = newEnds
        normalizeEnds()
    }

    mutating func addEndState(_ state: Int32) {
        let index = ends.sortedInsertionIndex(of: state)
        if index == ends.count || ends[index] != state { ends.insert(state, at: index) }
    }

    @discardableResult
    mutating func addState() -> Int32 { fsm.addState() }

    var description: String {
        let reachable = reachableStates().sorted()
        return "FSM(num_states=\(stateCount), start=\(start), end=[\(ends.map(String.init).joined(separator: ", "))], edges=\(fsm.edgesDescription(states: reachable)))"
    }

    func rebuilt(mapping: [Int32], stateCount newCount: Int) -> FSMWithStartEnd {
        FSMWithStartEnd(
            fsm: fsm.rebuilt(mapping: mapping, stateCount: newCount),
            start: mapping[Int(start)],
            ends: ends.map { mapping[Int($0)] }
        )
    }

    func compacted() -> CompactFSMWithStartEnd {
        CompactFSMWithStartEnd(fsm: fsm.compacted(), start: start, ends: ends, isDFA: isDFA)
    }

}

/// Packs automata one after another into a single ``CompactFSM`` (each row sorted, as
/// ``FSM/compacted()`` does), without an intermediate row-per-state ``FSM``. A grammar's
/// complete automaton is built this way, one rule at a time.
struct CompactFSMAppender {
    private var offsets: [Int32] = [0]
    private var edges: [FSMEdge] = []
    private var auxData: [Int32] = []

    /// Appends `fsm` and returns the fragment it became: renumbered start and ends plus the
    /// number of states and edges it contributed.
    mutating func append(_ fsm: FSMWithStartEnd) -> (start: Int32, ends: [Int32], edgeCount: Int, nodeCount: Int) {
        let stateOffset = Int32(offsets.count &- 1)
        let auxOffset = Int32(auxData.count)
        auxData.append(contentsOf: fsm.fsm.auxData)
        let firstEdge = edges.count
        for state in 0 ..< Int32(fsm.stateCount) {
            let begin = edges.count
            for edge in fsm.fsm.edges(of: state) {
                let max = edge.isAuxEdge && auxOffset > 0 ? edge.max &+ auxOffset : edge.max
                edges.append(FSMEdge(min: edge.min, max: max, target: edge.target &+ stateOffset))
            }
            if edges.count &- begin > 1 { edges.withUnsafeMutableBufferPointer { $0[begin...].sort() } }
            offsets.append(Int32(edges.count))
        }
        return (fsm.start &+ stateOffset, fsm.ends.map { $0 &+ stateOffset }, edges.count &- firstEdge, fsm.stateCount)
    }

    func finish() -> CompactFSM { CompactFSM(offsets: offsets, edges: edges, auxData: auxData) }
}

/// Breadth-first reachability over the fragments of one ``CompactFSM`` with reusable storage:
/// a generation stamp per state instead of a fresh `Set` per fragment, for passes that visit
/// every rule of a grammar.
struct ReachableStateWalker {
    private let fsm: CompactFSM
    private var stamps: [UInt32]
    private var generation: UInt32 = 0
    /// The states found by the last ``walk(from:)``, in breadth-first order.
    private(set) var states: [Int32] = []

    init(_ fsm: CompactFSM) {
        self.fsm = fsm
        stamps = Array(repeating: 0, count: fsm.stateCount)
    }

    mutating func walk(from start: Int32) {
        generation &+= 1
        if generation == 0 {
            stamps.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            generation = 1
        }
        states.removeAll(keepingCapacity: true)
        let generation = generation
        stamps.withUnsafeMutableBufferPointer { stamps in
            fsm.offsets.withUnsafeBufferPointer { offsets in
                fsm.edges.withUnsafeBufferPointer { edges in
                    stamps[Int(start)] = generation
                    states.append(start)
                    var head = 0
                    while head < states.count {
                        let state = Int(states[head])
                        head &+= 1
                        for index in Int(offsets[state]) ..< Int(offsets[state &+ 1]) {
                            let target = Int(edges[index].target)
                            if stamps[target] != generation {
                                stamps[target] = generation
                                states.append(Int32(target))
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A compact automaton with a start state and a set of accepting states. Many views usually
/// share one ``CompactFSM`` (every rule of a grammar is a view into the grammar's complete FSM).
struct CompactFSMWithStartEnd: FSMWithStartEndProtocol, Sendable, Hashable {
    var fsm: CompactFSM
    var start: Int32
    private(set) var ends: [Int32]
    var isDFA: Bool

    init(fsm: CompactFSM, start: Int32, ends: [Int32], isDFA: Bool = false) {
        self.fsm = fsm
        self.start = start
        var sorted = ends
        sorted.sort()
        sorted.removeDuplicatesSorted()
        self.ends = sorted
        self.isDFA = isDFA
    }

    var edgeCount: Int { fsm.edgeCount }

    var description: String {
        let reachableSet = reachableStates()
        let reachable = reachableSet.sorted()
        let visibleEnds = ends.filter { reachableSet.contains($0) }
        return "CompactFSM(num_states=\(stateCount), start=\(start), end=[\(visibleEnds.map(String.init).joined(separator: ", "))], edges=\(fsm.edgesDescription(states: reachable)))"
    }

    func expanded() -> FSMWithStartEnd {
        FSMWithStartEnd(fsm: fsm.expanded(), start: start, ends: ends, isDFA: isDFA)
    }
}

/// A ``CompactFSMWithStartEnd`` together with the size of the fragment it describes.
struct CompactFSMWithStartEndWithSize: Sendable, Hashable {
    var fsm: CompactFSMWithStartEnd
    var edgeCount: Int
    var nodeCount: Int
}
