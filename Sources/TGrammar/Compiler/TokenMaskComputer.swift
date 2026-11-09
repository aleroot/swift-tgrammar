import Synchronization
// Computes the adaptive token mask of one automaton state by replaying the sorted vocabulary
// through an Earley parser seeded with that state. Consecutive tokens share prefixes, so the
// parser is only rolled back to the common prefix between neighbours; a rejected prefix rejects
// its whole trie subtree at once.

struct TokenMaskComputer {
    private var parser: EarleyParser
    private let grammar: GrammarStorage
    private let tokenizerInfo: TokenizerInfo
    private var initialRuleID: Int32
    private var initialState: ParserState
    /// For tag-dispatch rules: tokens whose tail (from the second byte) contains no trigger or
    /// exclude, so they are accepted outright once the first byte returns to the start state.
    private let tagDispatchSecondSlicing: TagDispatchSlicing
    /// Cross-grammar mask reuse; `nil` when the compiler's cache is disabled.
    private let ruleLevelCache: RuleLevelCache?
    private let fsmHashes: GrammarFSMHashes?
    /// Within one grammar (no compiler cache): the only keys other states look up. Masks under
    /// other keys are neither looked up nor stored.
    private let sharedKeys: Set<RuleLevelCacheKey>?

    /// Per matched prefix length: whether the rule can end there, and whether it can end at or
    /// before it. Truncated on every rollback, so they are round buffers rather than arrays.
    private var canReachEndStack = RoundBuffer<Bool>()
    // Vocabulary-walk outputs (sorted vocabulary indices), kept across the jobs a computer runs.
    // Masks are built from them in place: copying them into arrays doubled the scratch memory of
    // a vocabulary-sized list (the accepted list of a free-text state is ~600 KB on a 151k
    // vocabulary).
    private var acceptedOut = RoundBuffer<Int32>(capacity: 1024)
    private var rejectedOut = RoundBuffer<Int32>(capacity: 1024)
    private var uncertainOut = RoundBuffer<Int32>(capacity: 256)
    private var acceptedByLookaheadOut = RoundBuffer<Int32>(capacity: 64)
    private var rejectedByLookaheadOut = RoundBuffer<Int32>(capacity: 64)
    private var canReachEndPrefixOrStack = RoundBuffer<Bool>()

    init(grammar: Grammar, initialState: ParserState, tagDispatchSecondSlicing: TagDispatchSlicing, tokenizerInfo: TokenizerInfo,
         ruleLevelCache: RuleLevelCache? = nil, fsmHashes: GrammarFSMHashes? = nil, sharedKeys: Set<RuleLevelCacheKey>? = nil) {
        parser = EarleyParser(grammar: grammar, initialState: initialState)
        self.grammar = grammar.storage
        self.tokenizerInfo = tokenizerInfo
        initialRuleID = initialState.ruleID
        self.initialState = initialState
        self.tagDispatchSecondSlicing = tagDispatchSecondSlicing
        self.ruleLevelCache = ruleLevelCache
        self.fsmHashes = fsmHashes
        self.sharedKeys = sharedKeys
    }

    /// Reuses this computer, its parser and buffers, for another state of the same grammar.
    mutating func reset(initialState: ParserState) {
        parser.reset(initialState: initialState)
        initialRuleID = initialState.ruleID
        self.initialState = initialState
    }

    // MARK: Entry point

    /// Computes the mask. For the root rule there are no uncertain tokens (no parent context).
    mutating func adaptiveTokenMask(isRootRule: Bool) -> AdaptiveTokenMask {
        acceptedOut.beginRound()
        rejectedOut.beginRound()
        uncertainOut.beginRound()
        acceptedByLookaheadOut.beginRound()
        rejectedByLookaheadOut.beginRound()
        defer { releaseLargeBuffers() }
        canReachEndStack.beginRound()
        canReachEndStack.append(false)
        canReachEndPrefixOrStack.beginRound()
        canReachEndPrefixOrStack.append(false)

        // Reuse a mask computed for the same automaton state of another grammar. A mask keyed
        // by the automaton alone is adapted to this rule's lookahead; one keyed by automaton and
        // lookahead together is exact.
        let rule = grammar.rule(initialRuleID)
        let lookaheadID = rule.lookaheadAssertionID
        var automatonKey: RuleLevelCacheKey? = nil
        var lookaheadKey: RuleLevelCacheKey? = nil
        if let cache = ruleLevelCache, let hashes = fsmHashes, !parser.hasCharBudgetRules,
           let key = Self.automatonKey(grammar, hashes, initialState), sharedKeys?.contains(key) ?? true {
            automatonKey = key
            if let lookaheadHash = GrammarFSMHasher.hashSequence(grammar, hashes, lookaheadID) {
                var combined: UInt64 = 0
                FSMHash.combine(&combined, key.fsmHash)
                FSMHash.combine(&combined, lookaheadHash)
                FSMHash.combine(&combined, rule.isExactLookahead ? 1 : 0)
                var exactKey = key
                exactKey.fsmHash = combined
                lookaheadKey = exactKey
                if let hit = cache.mask(for: exactKey) { return hit }
            }
            if var hit = cache.mask(for: key) {
                adaptWithLookahead(&hit, isRootRule: isRootRule)
                return hit
            }
        }

        let firstBytes = firstCharacterMask()
        let tokenEdgeAccepted = tokenEdgeAcceptedIndices()
        var rejectedFilled = false
        if !firstBytes.isEmpty {
            let sorted = tokenizerInfo.sortedTokens
            rejectedFilled = sorted.withUnsafeStorage { bytes, offsets in
                tokenMaskWithFirstCharacterCheck(firstBytes, isRootRule: isRootRule, tokenEdgeAccepted: tokenEdgeAccepted, bytes: bytes, offsets: offsets)
            }
        }

        // Token edges are rechecked at runtime when a character budget is present, because
        // accepting one can enter a budgeted rule within the same token.
        if !tokenEdgeAccepted.isEmpty {
            if parser.hasCharBudgetRules {
                Self.edit(&uncertainOut) { SortedIntSet.formUnion(&$0, tokenEdgeAccepted) }
            } else {
                Self.edit(&acceptedOut) { SortedIntSet.formUnion(&$0, tokenEdgeAccepted) }
                Self.edit(&uncertainOut) { SortedIntSet.subtract(&$0, tokenEdgeAccepted) }
            }
            Self.edit(&rejectedOut) { SortedIntSet.subtract(&$0, tokenEdgeAccepted) }
        }
        let mask = AdaptiveTokenMask(vocabSize: tokenizerInfo.vocabSize, sortedTokenIDs: tokenizerInfo.sortedTokenIDs, accepted: acceptedOut.elements,
                                     rejected: rejectedFilled ? rejectedOut.elements : nil, uncertain: uncertainOut.elements)
        share(mask, rejectedFilled: rejectedFilled, lookaheadID: lookaheadID, isRootRule: isRootRule, automatonKey: automatonKey, lookaheadKey: lookaheadKey)
        return mask
    }

    /// Applies an array edit to a walk output (for the rare edits after the walk).
    private static func edit(_ buffer: inout RoundBuffer<Int32>, _ body: (inout [Int32]) -> Void) {
        var list = Array(buffer.elements)
        body(&list)
        buffer.removeAll()
        buffer.reserveCapacity(list.count)
        for element in list { buffer.append(element) }
    }

    /// Lets go of walk outputs that grew past a few thousand entries, so each of the compiler's
    /// workers holds a vocabulary-sized list only while computing such a mask (reallocating one
    /// costs far less than the vocabulary walk that fills it).
    private mutating func releaseLargeBuffers() {
        let limit = 4096
        acceptedOut.removeAll()
        acceptedOut.releaseCapacity(above: limit)
        rejectedOut.removeAll()
        rejectedOut.releaseCapacity(above: limit)
        uncertainOut.removeAll()
        uncertainOut.releaseCapacity(above: limit)
        acceptedByLookaheadOut.removeAll()
        acceptedByLookaheadOut.releaseCapacity(above: limit)
        rejectedByLookaheadOut.removeAll()
        rejectedByLookaheadOut.releaseCapacity(above: limit)
    }

    // MARK: Cross-grammar sharing

    /// Stores the mask for other grammars. Without a lookahead (and outside the root rule) the
    /// mask depends on the automaton alone. Otherwise the tokens the lookahead decided become
    /// uncertain in the automaton-keyed copy, and the exact mask is stored under the combined key.
    private mutating func share(_ mask: AdaptiveTokenMask, rejectedFilled: Bool, lookaheadID: Int32, isRootRule: Bool, automatonKey: RuleLevelCacheKey?, lookaheadKey: RuleLevelCacheKey?) {
        guard let automatonKey, let cache = ruleLevelCache else { return }
        if lookaheadID == -1, !isRootRule {
            cache.insert(mask, for: automatonKey)
            return
        }
        // The exact mask is built, so the walk outputs are edited in place.
        let rejectedByLookahead = Array(rejectedByLookaheadOut.elements)
        let acceptedByLookahead = Array(acceptedByLookaheadOut.elements)
        Self.edit(&uncertainOut) {
            SortedIntSet.formUnion(&$0, rejectedByLookahead)
            SortedIntSet.formUnion(&$0, acceptedByLookahead)
        }
        Self.subtract(&acceptedOut, acceptedByLookahead)
        if rejectedFilled { Self.subtract(&rejectedOut, rejectedByLookahead) }
        let withoutLookahead = AdaptiveTokenMask(vocabSize: tokenizerInfo.vocabSize, sortedTokenIDs: tokenizerInfo.sortedTokenIDs, accepted: acceptedOut.elements,
                                                 rejected: rejectedFilled ? rejectedOut.elements : nil, uncertain: uncertainOut.elements)
        cache.insert(withoutLookahead, for: automatonKey)
        if let lookaheadKey { cache.insert(mask, for: lookaheadKey) }
    }

    /// Removes the sorted `indices` from a sorted walk output, in place.
    private static func subtract(_ buffer: inout RoundBuffer<Int32>, _ indices: [Int32]) {
        if indices.isEmpty { return }
        var cursor = 0
        buffer.removeAll { element in
            while cursor < indices.count, indices[cursor] < element { cursor += 1 }
            return cursor < indices.count && indices[cursor] == element
        }
    }

    /// Resolves the uncertain tokens of an automaton-keyed mask against this rule's lookahead
    /// (or rejects them all for the root rule, which has no parent to continue into).
    private mutating func adaptWithLookahead(_ mask: inout AdaptiveTokenMask, isRootRule: Bool) {
        let rule = grammar.rule(initialRuleID)
        var newRejected: [Int32] = []
        var newAccepted: [Int32] = []
        var newUncertain: [Int32] = []
        if isRootRule {
            newRejected = mask.uncertainIndices.array
        } else {
            if rule.lookaheadAssertionID == -1 { return }
            let subtreeEnds = tokenizerInfo.trieSubtreeEnds
            tokenizerInfo.sortedTokens.withUnsafeStorage { bytes, offsets in
                @inline(__always) func token(_ index: Int) -> UnsafeBufferPointer<UInt8> {
                    UnsafeBufferPointer(rebasing: bytes[Int(offsets[index]) ..< Int(offsets[index &+ 1])])
                }
                var previousIndex = -1
                var previousMatchedSize = 0
                var lastRejectedRange: Int32 = 0
                for index in mask.uncertainIndices {
                    if index < lastRejectedRange {
                        newRejected.append(index)
                        continue
                    }
                    let current = token(Int(index))
                    // Every uncertain token was rejected part-way by the rule itself; only the
                    // common prefix with the previous token is kept in the parser.
                    var accepted = true
                    if previousIndex >= 0 {
                        let previous = token(previousIndex)
                        let common = min(current.count, previous.count)
                        var lcp = 0
                        while lcp < common, current[lcp] == previous[lcp] { lcp &+= 1 }
                        if lcp > previousMatchedSize {
                            accepted = false
                        } else if lcp < previousMatchedSize {
                            rollback(previousMatchedSize - lcp)
                        }
                        previousMatchedSize = min(previousMatchedSize, lcp)
                    }
                    previousIndex = Int(index)
                    if accepted {
                        var position = previousMatchedSize
                        while position < current.count {
                            if !parser.advance(current[position]) { break }
                            pushReachEnd()
                            previousMatchedSize = position + 1
                            position += 1
                        }
                    }
                    let canReachEnd = canReachEndPrefixOrStack.last
                    if canReachEnd, previousMatchedSize > 0 {
                        let (lookaheadAccepted, lookaheadCompleted) = tokenPassesLookahead(current)
                        if lookaheadAccepted {
                            if lookaheadCompleted || !rule.isExactLookahead { newUncertain.append(index) } else { newAccepted.append(index) }
                            continue
                        }
                    }
                    newRejected.append(index)
                    lastRejectedRange = subtreeEnds[Int(index)]
                }
                rollback(previousMatchedSize)
            }
        }

        // The storage type is kept; the rare cases where the adapted sets would have chosen
        // another one only cost memory, not correctness.
        let sortedIDs = tokenizerInfo.sortedTokenIDs
        mask.uncertainIndices = IndexRuns(newUncertain)
        switch mask.storeType {
        case .accepted:
            if mask.acceptedIndices.count + newAccepted.count < AdaptiveTokenMask.bitsetThreshold {
                SortedIntSet.formUnion(&mask.acceptedIndices, newAccepted)
                break
            }
            var bitset = TokenBitmask(vocabSize: tokenizerInfo.vocabSize)
            for index in mask.acceptedIndices { bitset[sortedIDs[Int(index)]] = true }
            for index in newAccepted { bitset[sortedIDs[Int(index)]] = true }
            mask.acceptedBitset = bitset
            mask.acceptedIndices.removeAll()
            mask.storeType = .acceptedBitset
        case .rejected:
            if mask.rejectedIndices.count + newRejected.count < AdaptiveTokenMask.bitsetThreshold {
                SortedIntSet.formUnion(&mask.rejectedIndices, newRejected)
                break
            }
            var bitset = TokenBitmask(vocabSize: tokenizerInfo.vocabSize)
            for tokenID in sortedIDs { bitset[tokenID] = true }
            for index in mask.uncertainIndices { bitset[sortedIDs[Int(index)]] = false }
            for index in mask.rejectedIndices { bitset[sortedIDs[Int(index)]] = false }
            for index in newRejected { bitset[sortedIDs[Int(index)]] = false }
            mask.acceptedBitset = bitset
            mask.rejectedIndices.removeAll()
            mask.storeType = .acceptedBitset
        case .acceptedBitset:
            for index in newAccepted { mask.acceptedBitset[sortedIDs[Int(index)]] = true }
        }
    }

    // MARK: First-byte analysis

    private var initialFSM: CompactFSMWithStartEnd { grammar.perRuleFSMs[Int(initialRuleID)].unsafelyUnwrapped.fsm }

    /// The key under which the mask of `state` is shared regardless of the rule's lookahead,
    /// or `nil` when the state's automaton has no canonical hash. Callers exclude grammars with
    /// character budgets, whose masks depend on more than the automaton.
    static func automatonKey(_ grammar: GrammarStorage, _ hashes: GrammarFSMHashes, _ state: ParserState) -> RuleLevelCacheKey? {
        let ruleID = state.ruleID
        guard let fsmHash = hashes.ruleHashes[Int(ruleID)] else { return nil }
        let sized = grammar.perRuleFSMs[Int(ruleID)].unsafelyUnwrapped
        guard hashes.isCacheable(ruleID: ruleID, state: state.elementID, start: sized.fsm.start),
              let canonicalState = hashes.canonicalStateIDs[Int(ruleID)][state.elementID] else { return nil }
        return RuleLevelCacheKey(fsmHash: fsmHash, canonicalState: canonicalState, stateCount: Int32(sized.nodeCount), edgeCount: Int32(sized.edgeCount))
    }

    private func firstCharacterMask() -> ByteSet {
        var mask = ByteSet()
        for edge in initialFSM.fsm.edges(of: initialState.elementID) where edge.isCharRange {
            mask.insert(range: edge.min ... edge.max)
        }
        return mask
    }

    /// Sorted vocabulary indices accepted by the token / exclude-token edges of the state.
    private func tokenEdgeAcceptedIndices() -> [Int32] {
        let fsm = initialFSM
        let sortedIndexByTokenID = tokenizerInfo.sortedIndexByTokenID
        func sortedIndex(_ tokenID: Int32) -> Int32 {
            tokenID >= 0 && Int(tokenID) < sortedIndexByTokenID.count ? sortedIndexByTokenID[Int(tokenID)] : -1
        }
        var tokenAccepted: [Int32] = []
        var tokenExcluded: [Int32] = []
        var hasExclude = false
        for edge in fsm.fsm.edges(of: initialState.elementID) {
            if edge.isToken {
                for tokenID in fsm.fsm.tokenInfo(at: edge.auxIndex).tokenIDs {
                    let index = sortedIndex(tokenID)
                    if index >= 0 { tokenAccepted.append(index) }
                }
            } else if edge.isExcludeToken {
                hasExclude = true
                for tokenID in fsm.fsm.tokenInfo(at: edge.auxIndex).tokenIDs {
                    let index = sortedIndex(tokenID)
                    if index >= 0 { tokenExcluded.append(index) }
                }
            }
        }
        if !tokenAccepted.isEmpty { SortedIntSet.normalize(&tokenAccepted) }
        if !hasExclude { return tokenAccepted }
        // Token(ids) overrides ExcludeToken(ids) when both are present.
        SortedIntSet.normalize(&tokenExcluded)
        SortedIntSet.subtract(&tokenExcluded, tokenAccepted)
        return SortedIntSet.complement(count: Int32(tokenizerInfo.sortedTokens.count), excluding: tokenExcluded)
    }

    /// Whether the self-loop fast path applies, and the bytes that stay on the initial state.
    private func speculativeCalculation() -> (applies: Bool, mask: ByteSet) {
        let rule = grammar.rule(initialRuleID)
        // Committed-shortest rules must go through the full per-token simulation.
        if rule.isLazy { return (false, ByteSet()) }
        let fsm = initialFSM
        let body = grammar.expr(rule.bodyExprID)
        if body.kind == .tagDispatch {
            var mask = ByteSet()
            for edge in fsm.fsm.edges(of: initialState.elementID) where edge.target == fsm.start && edge.isCharRange {
                mask.insert(range: edge.min ... edge.max)
            }
            return (true, mask)
        }
        var applies = false
        var mask = ByteSet()
        for edge in fsm.fsm.edges(of: initialState.elementID) where edge.isCharRange {
            // Case A: a self loop.
            if edge.target == initialState.elementID {
                applies = true
                mask.insert(range: edge.min ... edge.max)
                continue
            }
            // Case B: from the start state, an edge to a state that re-enters this rule.
            if fsm.start == initialState.elementID {
                for next in fsm.fsm.edges(of: edge.target) {
                    let reentersSelf = (next.isRuleRef && next.ruleID == initialRuleID)
                        || (next.isRepeatRef && fsm.fsm.repeatInfo(at: next.auxIndex).ruleID == initialRuleID)
                    if reentersSelf {
                        applies = true
                        mask.insert(range: edge.min ... edge.max)
                        break
                    }
                }
            }
        }
        return (applies, mask)
    }

    /// Ranges `[a, b)` of sorted indices whose first byte is in `firstBytes`, one per maximal
    /// run of bytes in the set, read from the tokenizer's first-byte bounds.
    private static func possibleTokenIntervals(_ bounds: [Int32], _ firstBytes: ByteSet) -> (intervals: [Range<Int32>], count: Int) {
        var intervals: [Range<Int32>] = []
        var total = 0
        firstBytes.forEachRun { lower, upper in
            let interval = bounds[lower] ..< bounds[upper]
            intervals.append(interval)
            total += interval.count
        }
        return (intervals, total)
    }

    // MARK: Vocabulary replay

    /// Fills `accepted` / `rejected` / `uncertain`. Returns whether the rejected list is complete
    /// (it stops being filled once it grows past the bitset threshold).
    private mutating func tokenMaskWithFirstCharacterCheck(
        _ firstBytes: ByteSet, isRootRule: Bool, tokenEdgeAccepted: [Int32],
        bytes: UnsafeBufferPointer<UInt8>, offsets: UnsafeBufferPointer<UInt32>
    ) -> Bool {
        let sorted = tokenizerInfo.sortedTokens
        let sortedCount = sorted.count
        let subtreeEnds = tokenizerInfo.trieSubtreeEnds
        let sortedIDs = tokenizerInfo.sortedTokenIDs
        let (intervals, possibleCount) = Self.possibleTokenIntervals(tokenizerInfo.firstByteBounds, firstBytes)
        // The walk appends once per vocabulary token; pointer-backed buffers avoid a checked
        // array write each time. Accepted tokens all lie in the intervals: one exact allocation
        // instead of a doubling chain (whose last step held 1.5x the list).
        acceptedOut.reserveCapacity(possibleCount)
        var fillRejected = (sortedCount - possibleCount) < AdaptiveTokenMask.bitsetThreshold

        /// Token `index` as a raw view into the packed vocabulary.
        @inline(__always) func token(_ index: Int) -> UnsafeBufferPointer<UInt8> {
            UnsafeBufferPointer(rebasing: bytes[Int(offsets[index]) ..< Int(offsets[index &+ 1])])
        }
        /// Length of the common prefix of tokens `lhs` and `rhs`.
        @inline(__always) func commonPrefixLength(_ lhs: Int, _ rhs: Int) -> Int {
            let lstart = Int(offsets[lhs]), rstart = Int(offsets[rhs])
            let common = min(Int(offsets[lhs &+ 1]) &- lstart, Int(offsets[rhs &+ 1]) &- rstart)
            var i = 0
            while i < common, bytes[lstart &+ i] == bytes[rstart &+ i] { i &+= 1 }
            return i
        }
        assert(!intervals.isEmpty)

        if intervals[0].lowerBound != 0, fillRejected {
            for index in 0 ..< intervals[0].lowerBound { rejectedOut.append(index) }
        }

        var (speculative, speculativeMask) = speculativeCalculation()
        if parser.hasCharBudgetRules { speculative = false }

        var previousMatchedSize = 0
        var lastRejectedRange: Int32 = 0
        let isExactLookahead = grammar.rule(initialRuleID).isExactLookahead
        let isTagDispatch = grammar.kind(of: grammar.rule(initialRuleID).bodyExprID) == .tagDispatch
        let definiteAccepted: TokenBitmask? = isTagDispatch ? tagDispatchSecondSlicing.bitset(for: initialRuleID) : nil

        var previousIndex: Int = -1
        var skipCursor = 0
        for (intervalIndex, interval) in intervals.enumerated() {
            var i = interval.lowerBound
            while i < interval.upperBound {
                defer { i += 1 }
                // Tokens already accepted by token edges skip the expensive simulation.
                while skipCursor < tokenEdgeAccepted.count, tokenEdgeAccepted[skipCursor] < i { skipCursor += 1 }
                if skipCursor < tokenEdgeAccepted.count, tokenEdgeAccepted[skipCursor] == i { continue }

                if i < lastRejectedRange {
                    if fillRejected {
                        rejectedOut.append(i)
                        if rejectedOut.count >= AdaptiveTokenMask.bitsetThreshold { fillRejected = false }
                    } else {
                        i = lastRejectedRange - 1
                    }
                    continue
                }
                let token = token(Int(i))

                if speculative {
                    if let definiteAccepted {
                        if token.isEmpty {
                            acceptedOut.append(i)
                            continue
                        }
                        if speculativeMask.contains(token[0]), definiteAccepted[i] {
                            acceptedOut.append(i)
                            continue
                        }
                    } else {
                        var allAccepted = true
                        for byte in token where byte >= 0x80 || !speculativeMask.contains(byte) {
                            allAccepted = false
                            break
                        }
                        if allAccepted {
                            acceptedOut.append(i)
                            continue
                        }
                    }
                }

                var isAccepted = true
                if previousIndex >= 0 {
                    let lcp = commonPrefixLength(Int(i), previousIndex)
                    if lcp > previousMatchedSize {
                        // The common prefix was already rejected on the previous token.
                        isAccepted = false
                    } else if lcp < previousMatchedSize {
                        rollback(previousMatchedSize - lcp)
                    }
                    previousMatchedSize = min(previousMatchedSize, lcp)
                }
                previousIndex = Int(i)

                if isAccepted {
                    var position = previousMatchedSize
                    while position < token.count {
                        if !parser.advance(token[position]) {
                            isAccepted = false
                            break
                        }
                        pushReachEnd()
                        previousMatchedSize = position + 1
                        position += 1
                    }
                }

                let canReachEnd = canReachEndPrefixOrStack.last

                // The first bytes may finish a literal before a token-level free-text region,
                // which takes the whole token from there. The longer tokens under this one may be
                // taken even when this one is excluded, so they are not skipped with it.
                var rejectedRangeEnd = subtreeEnds[Int(i)]
                if !isAccepted, !parser.hasCharBudgetRules, parser.findMidTokenExcludeEdgeRow(rows: previousMatchedSize, tokenID: -1) > 0 {
                    isAccepted = parser.findMidTokenExcludeEdgeRow(rows: previousMatchedSize, tokenID: sortedIDs[Int(i)]) > 0
                    rejectedRangeEnd = i + 1
                }

                if isAccepted {
                    if parser.hasEnteredCharBudget { uncertainOut.append(i) } else { acceptedOut.append(i) }
                } else if canReachEnd, previousMatchedSize > 0 {
                    let (lookaheadAccepted, lookaheadCompleted) = tokenPassesLookahead(token)
                    if !isRootRule, lookaheadAccepted {
                        if lookaheadCompleted || !isExactLookahead {
                            uncertainOut.append(i)
                        } else if parser.hasEnteredCharBudget {
                            uncertainOut.append(i)
                        } else {
                            acceptedOut.append(i)
                            acceptedByLookaheadOut.append(i)
                        }
                    } else {
                        for j in i ..< rejectedRangeEnd {
                            rejectedOut.append(j)
                            rejectedByLookaheadOut.append(j)
                        }
                        i = rejectedRangeEnd - 1
                    }
                } else {
                    rejectedOut.append(i)
                    lastRejectedRange = rejectedRangeEnd
                    if rejectedOut.count >= AdaptiveTokenMask.bitsetThreshold { fillRejected = false }
                }
            }
            if intervalIndex != intervals.count - 1, fillRejected {
                let next = intervals[intervalIndex + 1]
                for j in interval.upperBound ..< next.lowerBound { rejectedOut.append(j) }
                if rejectedOut.count >= AdaptiveTokenMask.bitsetThreshold { fillRejected = false }
            }
        }

        rollback(previousMatchedSize)

        if let last = intervals.last, Int(last.upperBound) != sortedCount, fillRejected {
            for j in last.upperBound ..< Int32(sortedCount) { rejectedOut.append(j) }
        }
        return fillRejected
    }

    @inline(__always)
    private mutating func pushReachEnd() {
        let completed = parser.isCompleted
        canReachEndStack.append(completed)
        canReachEndPrefixOrStack.append(completed || canReachEndPrefixOrStack.last)
    }

    @inline(__always)
    private mutating func rollback(_ count: Int) {
        parser.popLastStates(count)
        canReachEndStack.removeLast(count)
        canReachEndPrefixOrStack.removeLast(count)
    }

    /// Whether a token rejected mid-way can still pass through the rule's lookahead assertion
    /// from one of the positions where the rule could end. Returns `(accepted, canReachEnd)`.
    private mutating func tokenPassesLookahead(_ token: UnsafeBufferPointer<UInt8>) -> (accepted: Bool, canReachEnd: Bool) {
        let lookaheadID = grammar.rule(initialRuleID).lookaheadAssertionID
        if lookaheadID == -1 { return (true, true) }
        parser.lookaheadReachedExcludeToken = false
        parser.pushStateAndExpand(ParserState(ruleID: -1, sequenceID: lookaheadID, elementID: 0, ruleStartPos: ParserState.noPreviousInputPosition, budgetDeadline: 0))
        if parser.isCompleted {
            parser.popLastStates(1)
            return (true, true)
        }
        let tokenLength = token.count
        var i = canReachEndStack.count - 1
        while i >= 0 {
            defer { i -= 1 }
            if !canReachEndStack[i] { continue }
            var lastAccepted = i - 1
            var position = i
            while position < tokenLength {
                if !parser.advance(token[position]) { break }
                lastAccepted = position
                if parser.isCompleted {
                    // The lookahead is fully matched; roll back the pushed initial state too.
                    parser.popLastStates(position - i + 2)
                    return (true, true)
                }
                position += 1
            }
            if lastAccepted == tokenLength - 1 {
                // The whole token fits inside the lookahead.
                parser.popLastStates(lastAccepted - i + 2)
                return (true, false)
            }
            // Rejected, unless a free-text region in the lookahead may still take the token
            // whole from the middle; then the parent decides at runtime.
            if parser.lookaheadReachedExcludeToken
                || (!parser.hasCharBudgetRules && parser.findMidTokenExcludeEdgeRow(rows: lastAccepted - i + 2, tokenID: -1) > 0) {
                parser.popLastStates(lastAccepted - i + 2)
                return (true, true)
            }
            parser.popLastStates(lastAccepted - i + 1)
        }
        parser.popLastStates(1)
        return (false, false)
    }
}

/// For each tag-dispatch rule, the sorted tokens whose bytes from the second one on contain no
/// trigger and no exclude string: once their first byte returns to the trie's start state they
/// are accepted outright. Eager compilation computes every rule's set up front; dynamic
/// compilation computes each with the rule's first mask.
final class TagDispatchSlicing: Sendable {
    private let grammar: GrammarStorage
    private let sortedTokens: ByteStringTable
    private let bitsets = Mutex<[Int32: TokenBitmask]>([:])

    init(_ grammar: GrammarStorage, _ sortedTokens: ByteStringTable) {
        self.grammar = grammar
        self.sortedTokens = sortedTokens
    }

    /// An empty table, for computing masks of grammars without tag dispatch.
    static func none(_ grammar: GrammarStorage) -> TagDispatchSlicing { TagDispatchSlicing(grammar, ByteStringTable()) }

    /// Computes the set of every tag-dispatch rule (rules with equal strings share one pass).
    func computeAll() {
        for ruleID in 0 ..< Int32(grammar.ruleCount) where isTagDispatch(ruleID) { _ = bitset(for: ruleID) }
    }

    /// The set of `ruleID`, or `nil` when it is not a tag-dispatch rule.
    func bitset(for ruleID: Int32) -> TokenBitmask? {
        guard isTagDispatch(ruleID) else { return nil }
        if let known = bitsets.withLock({ $0[ruleID] }) { return known }
        let strings = needles(of: ruleID)
        let shared = bitsets.withLock { known in
            known.first { self.needles(of: $0.key) == strings }?.value
        }
        let bitset = shared ?? Self.compute(strings, sortedTokens)
        bitsets.withLock { $0[ruleID] = bitset }
        return bitset
    }

    private func isTagDispatch(_ ruleID: Int32) -> Bool { grammar.kind(of: grammar.rule(ruleID).bodyExprID) == .tagDispatch }

    private func needles(of ruleID: Int32) -> [[UInt8]] {
        let dispatch = grammar.tagDispatch(grammar.expr(grammar.rule(ruleID).bodyExprID))
        return dispatch.tagRulePairs.map(\.tag) + dispatch.excludes
    }

    /// One pass over the vocabulary: only tail bytes that start some needle are compared.
    static func compute(_ needles: [[UInt8]], _ sorted: ByteStringTable) -> TokenBitmask {
        var bitset = TokenBitmask(vocabSize: sorted.count)
        let containsEmpty = needles.contains { $0.isEmpty }
        var byFirstByte = [[[UInt8]]](repeating: [], count: 256)
        var firstBytes = ByteSet()
        for needle in needles where !needle.isEmpty {
            byFirstByte[Int(needle[0])].append(needle)
            firstBytes.insert(needle[0])
        }
        sorted.withUnsafeStorage { bytes, offsets in
            for index in 0 ..< sorted.count {
                let start = Int(offsets[index]), end = Int(offsets[index + 1])
                if start == end { bitset[index] = true; continue }
                if containsEmpty { continue }
                var found = false
                var position = start + 1
                scan: while position < end {
                    let byte = bytes[position]
                    if firstBytes.contains(byte) {
                        for needle in byFirstByte[Int(byte)] where needle.count <= end - position {
                            var offset = 1
                            while offset < needle.count, bytes[position + offset] == needle[offset] { offset += 1 }
                            if offset == needle.count { found = true; break scan }
                        }
                    }
                    position += 1
                }
                if !found { bitset[index] = true }
            }
        }
        return bitset
    }
}
