// Canonical hashes of each rule's automaton. Two rules with the same hash (and state/edge
// counts) accept the same language from corresponding states, so token masks computed for one
// grammar can be reused for another: the rule-level cache of `GrammarCompiler` is keyed by
// these hashes. Mirrors upstream's `GrammarFSMHasher`.
//
// Rules are hashed bottom-up over the reference graph: a rule's hash folds in the hashes of the
// rules it references, so leaves go first, then their referrers. Simple cycles (each member
// referencing exactly one other member) get rotation-canonical hashes. Rules still unhashed
// after that (they reference a rule that could not be hashed) receive a *partial* hash when the
// only unhashed reference leaves their start state; the start state's own mask is then not
// reusable, since it includes the tokens of the unhashed rule.

struct GrammarFSMHashes: Sendable {
    /// Per rule; `nil` when the automaton could not be hashed.
    var ruleHashes: [UInt64?]
    /// Whether the hash leaves out one unhashed rule referenced at the start state.
    var isPartial: [Bool]
    /// Per rule: original state id → canonical (BFS order) state id.
    var canonicalStateIDs: [[Int32: Int32]]

    /// Whether masks of `state` in `ruleID` may be shared across grammars.
    @inline(__always)
    func isCacheable(ruleID: Int32, state: Int32, start: Int32) -> Bool {
        ruleHashes[Int(ruleID)] != nil && !(isPartial[Int(ruleID)] && state == start)
    }
}

/// `HashCombineMixed`: every value passes through the splitmix64 finalizer before the boost
/// combine, so consecutive small integers (byte ranges `[0-3]`/`[1-t]`, bounds `{0,64}`/
/// `{1,129}`) cannot cancel out.
enum FSMHash {
    @inline(__always)
    static func combine(_ seed: inout UInt64, _ value: UInt64) {
        seed ^= value &+ 0x9e37_79b9_7f4a_7c15 &+ (seed << 6) &+ (seed >> 2)
    }

    @inline(__always)
    static func mix(_ value: UInt64) -> UInt64 {
        var v = value
        v = (v ^ (v >> 30)) &* 0xbf58_476d_1ce4_e5b9
        v = (v ^ (v >> 27)) &* 0x94d0_49bb_1331_11eb
        return v ^ (v >> 31)
    }

    @inline(__always) static func word(_ value: Int32) -> UInt64 { UInt64(bitPattern: Int64(value)) }
    @inline(__always) static func word(_ value: Int) -> UInt64 { UInt64(bitPattern: Int64(value)) }

    @inline(__always)
    static func mixed(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var seed: UInt64 = 0
        combine(&seed, mix(a)); combine(&seed, mix(b))
        return seed
    }

    @inline(__always)
    static func mixed(_ a: UInt64, _ b: UInt64, _ c: UInt64) -> UInt64 {
        var seed: UInt64 = 0
        combine(&seed, mix(a)); combine(&seed, mix(b)); combine(&seed, mix(c))
        return seed
    }

    @inline(__always)
    static func mixed(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64) -> UInt64 {
        var seed: UInt64 = 0
        combine(&seed, mix(a)); combine(&seed, mix(b)); combine(&seed, mix(c)); combine(&seed, mix(d))
        return seed
    }

    @inline(__always)
    static func mixed(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64, _ e: UInt64) -> UInt64 {
        var seed: UInt64 = 0
        combine(&seed, mix(a)); combine(&seed, mix(b)); combine(&seed, mix(c)); combine(&seed, mix(d)); combine(&seed, mix(e))
        return seed
    }
}

struct GrammarFSMHasher {
    private static let notEndStateFlag = FSMHash.word(-0x100)
    private static let endStateFlag = FSMHash.word(-0x200)
    private static let selfRecursionFlag = FSMHash.word(-0x300)
    private static let simpleCycleFlag = FSMHash.word(-0x400)
    private static let unknownFlag = FSMHash.word(-0x500)
    private static let lazyFlag = FSMHash.word(-0x600)

    private let grammar: GrammarStorage
    private let completeFSM: CompactFSM
    private var hashes: GrammarFSMHashes
    private var visited: [Bool]
    /// Rules each rule references (shrinks as referees are hashed).
    private var refereesByReferrer: [[Int32]]
    /// Rules referencing each rule.
    private let referrersByReferee: [[Int32]]
    /// Sorted copies of the rows, only when some row of the complete automaton is unsorted (the
    /// compiler always builds sorted rows; copying them all cost an allocation per state).
    private var sortedEdges: [[FSMEdge]]?
    private var hasInwardEdges: [Bool]
    /// Rules whose references are all hashed (except a self-reference); processed in FIFO order.
    private var readyQueue: [Int32] = []
    private var readyHead = 0

    static func apply(_ grammar: GrammarStorage) -> GrammarFSMHashes {
        var hasher = GrammarFSMHasher(grammar)
        hasher.run()
        return hasher.hashes
    }

    private init(_ grammar: GrammarStorage) {
        self.grammar = grammar
        completeFSM = grammar.completeFSM.unsafelyUnwrapped
        let ruleCount = grammar.ruleCount
        hashes = GrammarFSMHashes(ruleHashes: Array(repeating: nil, count: ruleCount), isPartial: Array(repeating: false, count: ruleCount),
                                  canonicalStateIDs: Array(repeating: [:], count: ruleCount))
        visited = Array(repeating: false, count: ruleCount)
        // The reference graph comes from the automaton edges hashing walks: the grammar's
        // expressions miss the rules a regex body references for its large repetitions.
        let completeFSM = completeFSM
        var referees = [[Int32]](repeating: [], count: ruleCount)
        var referrers = [[Int32]](repeating: [], count: ruleCount)
        var stateVisited = [Bool](repeating: false, count: completeFSM.stateCount)
        var stack: [Int32] = []
        for index in 0 ..< ruleCount {
            guard let start = grammar.perRuleFSMs[index]?.fsm.start else { continue }
            stateVisited[Int(start)] = true
            stack.append(start)
            while let state = stack.popLast() {
                for edge in completeFSM.edges(of: state) {
                    if edge.isRuleRef { referees[index].append(edge.ruleID) }
                    else if edge.isRepeatRef { referees[index].append(completeFSM.repeatInfo(at: edge.auxIndex).ruleID) }
                    if !stateVisited[Int(edge.target)] {
                        stateVisited[Int(edge.target)] = true
                        stack.append(edge.target)
                    }
                }
            }
            referees[index].sort()
            referees[index].removeDuplicatesSorted()
            for referee in referees[index] { referrers[Int(referee)].append(Int32(index)) }
        }
        referrersByReferee = referrers
        refereesByReferrer = referees
        let stateCount = completeFSM.stateCount
        var inward = [Bool](repeating: false, count: stateCount)
        for edge in completeFSM.edges { inward[Int(edge.target)] = true }
        hasInwardEdges = inward
        var rowsSorted = true
        for state in 0 ..< Int32(stateCount) where rowsSorted {
            let row = completeFSM.edges(of: state)
            rowsSorted = zip(row, row.dropFirst()).allSatisfy { !($1 < $0) }
        }
        sortedEdges = rowsSorted ? nil : (0 ..< Int32(stateCount)).map { completeFSM.edges(of: $0).sorted() }
    }

    private mutating func run() {
        let ruleCount = grammar.ruleCount
        for index in 0 ..< ruleCount where grammar.perRuleFSMs[index] == nil { visited[index] = true }
        for index in 0 ..< ruleCount where isReadyToHash(Int32(index)) { readyQueue.append(Int32(index)) }
        while true {
            guard readyHead < readyQueue.count else {
                // Nothing is ready: break a simple cycle of the reference graph and continue.
                if !findSimpleCycle() { break }
                continue
            }
            let ruleID = readyQueue[readyHead]
            readyHead += 1
            // A rule may be queued several times before it is processed.
            guard isReadyToHash(ruleID) else { continue }
            visited[Int(ruleID)] = true
            hashes.ruleHashes[Int(ruleID)] = hashFSM(ruleID, allowUnknownAtStart: false)
            removeHashedFSM(ruleID)
        }

        // The remaining rules reference something that could not be hashed. One whose start
        // state has no inward edge can still be hashed, leaving out the rule referenced there.
        var partial: [(Int32, UInt64)] = []
        for index in 0 ..< ruleCount where hashes.ruleHashes[index] == nil {
            guard let fsm = grammar.perRuleFSMs[index]?.fsm, !hasInwardEdges[Int(fsm.start)] else { continue }
            if let hash = hashFSM(Int32(index), allowUnknownAtStart: true) { partial.append((Int32(index), hash)) }
        }
        for (ruleID, hash) in partial {
            hashes.ruleHashes[Int(ruleID)] = hash
            hashes.isPartial[Int(ruleID)] = true
        }
    }

    @inline(__always)
    private func isReadyToHash(_ ruleID: Int32) -> Bool {
        if visited[Int(ruleID)] { return false }
        let referees = refereesByReferrer[Int(ruleID)]
        return referees.isEmpty || (referees.count == 1 && referees[0] == ruleID)
    }

    /// Drops the hashed rule from its referrers' pending references and queues the referrers
    /// that became ready.
    private mutating func removeHashedFSM(_ ruleID: Int32) {
        for referrer in referrersByReferee[Int(ruleID)] {
            if let index = refereesByReferrer[Int(referrer)].firstIndex(of: ruleID) {
                refereesByReferrer[Int(referrer)].remove(at: index)
            }
            if isReadyToHash(referrer) { readyQueue.append(referrer) }
        }
    }

    // MARK: Cycles

    /// Finds a cycle whose members each have exactly one pending reference and hashes it.
    private mutating func findSimpleCycle() -> Bool {
        let ruleCount = grammar.ruleCount
        var notSimpleCycle = visited
        var inStack = [Bool](repeating: false, count: ruleCount)
        for index in 0 ..< ruleCount where !notSimpleCycle[index] {
            var dfsStack = [Int32(index)]
            var walked = [Int32(index)]
            var simpleCycle: [Int32] = []
            var current = Int32(index)
            inStack[index] = true
            while refereesByReferrer[Int(current)].count == 1, !notSimpleCycle[Int(current)] {
                let next = refereesByReferrer[Int(current)][0]
                // A rule whose only pending reference is itself would have been ready.
                if next == current { break }
                notSimpleCycle[Int(current)] = true
                current = next
                if inStack[Int(current)] {
                    simpleCycle.append(current)
                    while let top = dfsStack.last, top != current { simpleCycle.append(dfsStack.removeLast()) }
                    break
                }
                dfsStack.append(current)
                inStack[Int(current)] = true
                walked.append(current)
            }
            if !simpleCycle.isEmpty {
                hashSimpleCycle(simpleCycle)
                return true
            }
            for state in walked { inStack[Int(state)] = false }
        }
        return false
    }

    /// Every member is first hashed with the others standing in as a flag, then each member's
    /// hash folds the members' hashes in cycle order starting from itself.
    private mutating func hashSimpleCycle(_ cycle: [Int32]) {
        for ruleID in cycle {
            visited[Int(ruleID)] = true
            hashes.ruleHashes[Int(ruleID)] = Self.simpleCycleFlag
        }
        var local: [UInt64] = []
        local.reserveCapacity(cycle.count)
        for ruleID in cycle {
            guard let hash = hashFSM(ruleID, allowUnknownAtStart: false) else {
                // Should not happen for a simple cycle; leave the members unhashed rather than
                // keep the placeholder, which would collide across unrelated grammars.
                for member in cycle { hashes.ruleHashes[Int(member)] = nil }
                for member in cycle { removeHashedFSM(member) }
                return
            }
            local.append(hash)
        }
        let count = cycle.count
        var rotated = local
        for i in 0 ..< count {
            var hash: UInt64 = 0
            for j in 0 ..< count { hash = FSMHash.mixed(hash, local[(i + j) % count]) }
            rotated[i] = hash
        }
        for i in 0 ..< count {
            hashes.ruleHashes[Int(cycle[i])] = rotated[i]
            removeHashedFSM(cycle[i])
        }
    }

    // MARK: One automaton

    /// Hashes a rule's automaton in BFS order from its start state. Every referenced rule must
    /// be hashed already, except that with `allowUnknownAtStart` one unhashed rule referenced
    /// from the start state is hashed as a flag. Returns `nil` otherwise.
    private mutating func hashFSM(_ ruleID: Int32, allowUnknownAtStart: Bool) -> UInt64? {
        let fsm = grammar.perRuleFSMs[Int(ruleID)].unsafelyUnwrapped.fsm
        var canonical: [Int32: Int32] = [fsm.start: 0]
        var queue = [fsm.start]
        var head = 0
        var hash: UInt64 = 0
        var hashAndTarget: [(hash: UInt64, target: Int32)] = []

        while head < queue.count {
            let oldState = queue[head]
            head += 1
            let isStart = oldState == fsm.start
            let newState = FSMHash.word(canonical[oldState].unsafelyUnwrapped)
            let endFlag = fsm.isEndState(oldState) ? Self.endStateFlag : Self.notEndStateFlag
            hash = FSMHash.mixed(hash, newState, endFlag, endFlag, newState)

            // Rule-like edges first (rule references and counted repetitions), ordered by the
            // referenced hash so the result does not depend on edge order.
            hashAndTarget.removeAll(keepingCapacity: true)
            var unhashedCount = 0
            for edge in sortedRow(oldState) {
                let referenced: Int32
                var bounds: (Int32, Int32)? = nil
                if edge.isRuleRef {
                    referenced = edge.ruleID
                } else if edge.isRepeatRef {
                    let info = completeFSM.repeatInfo(at: edge.auxIndex)
                    referenced = info.ruleID
                    bounds = (info.lower, info.upper)
                } else {
                    continue
                }
                var referencedHash: UInt64
                if referenced == ruleID {
                    // With `allowUnknownAtStart` the unhashed rule at the start is reached from
                    // every other state through a self-reference, so nothing can be hashed.
                    if allowUnknownAtStart { return nil }
                    referencedHash = Self.selfRecursionFlag
                } else if let known = hashes.ruleHashes[Int(referenced)] {
                    referencedHash = known
                } else {
                    guard allowUnknownAtStart, isStart else { return nil }
                    unhashedCount += 1
                    if unhashedCount > 1 { return nil }
                    referencedHash = Self.unknownFlag
                }
                if let (lower, upper) = bounds { referencedHash = FSMHash.mixed(referencedHash, FSMHash.word(lower), FSMHash.word(upper)) }
                hashAndTarget.append((referencedHash, edge.target))
            }
            hashAndTarget.sort { $0.hash != $1.hash ? $0.hash < $1.hash : $0.target < $1.target }
            var previous: (hash: UInt64, target: Int32)? = nil
            for entry in hashAndTarget {
                if let previous, previous == entry { continue }
                previous = entry
                let targetNew = canonicalID(entry.target, &canonical, &queue)
                hash = FSMHash.mixed(hash, newState, entry.hash, targetNew)
            }

            for edge in sortedRow(oldState) {
                let targetNew = canonicalID(edge.target, &canonical, &queue)
                if edge.isRuleRef || edge.isRepeatRef { continue }
                if edge.isToken || edge.isExcludeToken {
                    // The aux index of a token edge is arena-specific; hash the token ids.
                    let info = completeFSM.tokenInfo(at: edge.auxIndex)
                    hash = FSMHash.mixed(hash, newState, FSMHash.word(edge.min), FSMHash.word(info.tokenIDs.count), targetNew)
                    for tokenID in info.tokenIDs { hash = FSMHash.mixed(hash, FSMHash.word(tokenID)) }
                    continue
                }
                hash = FSMHash.mixed(hash, newState, FSMHash.word(edge.min), FSMHash.word(edge.max), targetNew)
            }
        }
        hashes.canonicalStateIDs[Int(ruleID)] = canonical
        // A lazy rule has other token masks than the same automaton without it.
        if grammar.rule(ruleID).isLazy { hash = FSMHash.mixed(hash, Self.lazyFlag) }
        return hash
    }

    @inline(__always)
    private func sortedRow(_ state: Int32) -> ArraySlice<FSMEdge> {
        if let sortedEdges { return sortedEdges[Int(state)][...] }
        return completeFSM.edges(of: state)
    }

    @inline(__always)
    private func canonicalID(_ state: Int32, _ canonical: inout [Int32: Int32], _ queue: inout [Int32]) -> UInt64 {
        if let known = canonical[state] { return FSMHash.word(known) }
        let assigned = Int32(canonical.count)
        canonical[state] = assigned
        queue.append(state)
        return FSMHash.word(assigned)
    }

    // MARK: Lookahead sequences

    /// Hashes a lookahead assertion sequence, or `nil` when it contains something whose
    /// language the hashes do not identify (nested sequences, dispatches, partially hashed
    /// rules).
    static func hashSequence(_ grammar: GrammarStorage, _ hashes: GrammarFSMHashes, _ sequenceID: Int32) -> UInt64? {
        if sequenceID == -1 { return nil }
        var hash: UInt64 = 0
        let sequence = grammar.expr(sequenceID)
        for exprID in sequence {
            let expr = grammar.expr(exprID)
            // The size keeps the elements of one expression apart from the next.
            hash = FSMHash.mixed(hash, FSMHash.word(expr.kind.rawValue), FSMHash.word(expr.count))
            switch expr.kind {
            case .byteString, .characterClass, .characterClassStar, .emptyString, .regex, .substring, .token, .excludeToken:
                for element in expr { hash = FSMHash.mixed(hash, FSMHash.word(element)) }
            case .ruleRef:
                guard let referenced = hashes.ruleHashes[Int(expr[0])], !hashes.isPartial[Int(expr[0])] else { return nil }
                hash = FSMHash.mixed(hash, referenced)
            case .repeat:
                guard let referenced = hashes.ruleHashes[Int(expr[0])], !hashes.isPartial[Int(expr[0])] else { return nil }
                hash = FSMHash.mixed(hash, referenced)
                hash = FSMHash.mixed(hash, FSMHash.word(expr[1]))
                hash = FSMHash.mixed(hash, FSMHash.word(expr[2]))
            case .sequence, .choices, .tagDispatch, .tokenTagDispatch:
                return nil
            }
        }
        return hash
    }
}
