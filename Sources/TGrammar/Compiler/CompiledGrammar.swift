// The product of compiling a grammar against a tokenizer: the optimized grammar plus, for every
// scanable automaton state, an `AdaptiveTokenMask` that partitions the vocabulary into tokens
// decided by that state alone (accepted / rejected) and tokens whose fate depends on the parent
// states (uncertain). The matcher only replays the uncertain ones.

import Dispatch
import Synchronization

/// Per-state partition of the sorted vocabulary. Indices refer to `TokenizerInfo.sortedTokens`,
/// not to token ids.
struct AdaptiveTokenMask: Sendable, Hashable {
    enum StoreType: Int32, Sendable {
        /// Only accepted indices are stored (rejected = rest − uncertain).
        case accepted = 0
        /// Only rejected indices are stored (accepted = rest − uncertain).
        case rejected = 1
        /// Accepted tokens stored as a bitmask over token ids (both sets large).
        case acceptedBitset = 2
    }

    static let bitsetThreshold = 1000

    var storeType: StoreType
    var acceptedIndices: [Int32] = []
    var rejectedIndices: [Int32] = []
    var acceptedBitset: TokenBitmask
    var uncertainIndices: IndexRuns

    /// Fast path for the body state of a counted repetition of one character class.
    /// `repeatInteriorBitsets[i]` holds every token decided by the repetition budget alone that
    /// consumes at most `repeatInteriorCharCounts[i]` repetitions (counts strictly increasing).
    /// Bitsets are checkpoints, taken only once enough tokens accumulated since the previous one:
    /// budget tokens whose count is not a checkpoint are also listed in `repeatInteriorTokens`
    /// as `(repetitions consumed, token id)`, sorted by count, so a budget between checkpoints is
    /// one bitset union plus fewer than `repeatCheckpointTokens` writes (one bitset per count
    /// held 1.7 MB for a single bounded string over a 151k vocabulary).
    /// `repeatExitTokens` lists `(repetitions consumed, token id)` for tokens that leave the
    /// repetition on their last byte. These tokens are removed from the mask's own classes.
    var repeatInteriorCharCounts: [Int32] = []
    var repeatInteriorBitsets: [TokenBitmask] = []
    var repeatInteriorTokens: [(repetitions: Int32, tokenID: Int32)] = []
    var repeatExitTokens: [(repetitions: Int32, tokenID: Int32)] = []

    /// Listed budget tokens a checkpoint bitset replaces; a bitset costs vocabSize/8 bytes.
    static func repeatCheckpointTokens(vocabSize: Int) -> Int { max(64, vocabSize / 256) }

    /// Whether the counted-repetition fast path applies to this mask.
    var hasRepeatInterior: Bool { !repeatInteriorBitsets.isEmpty || !repeatInteriorTokens.isEmpty || !repeatExitTokens.isEmpty }

    init(vocabSize: Int, sortedTokenIDs: [Int32], accepted: [Int32], rejected: [Int32], uncertain: [Int32]) {
        let acceptedCount = accepted.count, rejectedCount = rejected.count
        storeType = acceptedCount >= Self.bitsetThreshold && rejectedCount >= Self.bitsetThreshold
            ? .acceptedBitset
            : acceptedCount < rejectedCount ? .accepted : .rejected
        acceptedBitset = TokenBitmask(vocabSize: storeType == .acceptedBitset ? vocabSize : 0)
        switch storeType {
        case .acceptedBitset:
            for index in accepted { acceptedBitset[sortedTokenIDs[Int(index)]] = true }
        case .accepted:
            acceptedIndices = accepted.compacted()
        case .rejected:
            rejectedIndices = rejected.compacted()
        }
        uncertainIndices = IndexRuns(uncertain)
    }

    /// For states whose rejected set was not enumerated.
    init(vocabSize: Int, sortedTokenIDs: [Int32], accepted: [Int32], uncertain: [Int32]) {
        storeType = accepted.count >= Self.bitsetThreshold ? .acceptedBitset : .accepted
        acceptedBitset = TokenBitmask(vocabSize: storeType == .acceptedBitset ? vocabSize : 0)
        if storeType == .acceptedBitset {
            for index in accepted { acceptedBitset[sortedTokenIDs[Int(index)]] = true }
        } else {
            acceptedIndices = accepted.compacted()
        }
        uncertainIndices = IndexRuns(uncertain)
    }

    /// From scratch buffers, read in place (`rejected` is nil when it was not enumerated).
    init(vocabSize: Int, sortedTokenIDs: [Int32], accepted: UnsafeBufferPointer<Int32>, rejected: UnsafeBufferPointer<Int32>?,
         uncertain: UnsafeBufferPointer<Int32>) {
        let acceptedCount = accepted.count, rejectedCount = rejected?.count ?? .max
        storeType = acceptedCount >= Self.bitsetThreshold && rejectedCount >= Self.bitsetThreshold
            ? .acceptedBitset
            : acceptedCount < rejectedCount ? .accepted : .rejected
        acceptedBitset = TokenBitmask(vocabSize: storeType == .acceptedBitset ? vocabSize : 0)
        switch storeType {
        case .acceptedBitset:
            for index in accepted { acceptedBitset[sortedTokenIDs[Int(index)]] = true }
        case .accepted:
            acceptedIndices = Array(accepted)
        case .rejected:
            rejectedIndices = Array(rejected.unsafelyUnwrapped)
        }
        uncertainIndices = IndexRuns(uncertain)
    }

    /// Drops spare capacity left by in-place edits, before the mask is stored for good.
    mutating func compact() {
        acceptedIndices = acceptedIndices.compacted()
        rejectedIndices = rejectedIndices.compacted()
        repeatInteriorCharCounts = repeatInteriorCharCounts.compacted()
        repeatInteriorBitsets = repeatInteriorBitsets.compacted()
        repeatInteriorTokens = repeatInteriorTokens.compacted()
        repeatExitTokens = repeatExitTokens.compacted()
    }

    static func == (lhs: AdaptiveTokenMask, rhs: AdaptiveTokenMask) -> Bool {
        lhs.storeType == rhs.storeType && lhs.acceptedIndices == rhs.acceptedIndices && lhs.rejectedIndices == rhs.rejectedIndices
            && lhs.acceptedBitset == rhs.acceptedBitset && lhs.uncertainIndices == rhs.uncertainIndices
            && lhs.repeatInteriorCharCounts == rhs.repeatInteriorCharCounts && lhs.repeatInteriorBitsets == rhs.repeatInteriorBitsets
            && Self.equal(lhs.repeatInteriorTokens, rhs.repeatInteriorTokens) && Self.equal(lhs.repeatExitTokens, rhs.repeatExitTokens)
    }

    static func equal(_ lhs: [(repetitions: Int32, tokenID: Int32)], _ rhs: [(repetitions: Int32, tokenID: Int32)]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.repetitions == $1.repetitions && $0.tokenID == $1.tokenID }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(storeType)
        hasher.combine(acceptedIndices)
        hasher.combine(rejectedIndices)
        hasher.combine(uncertainIndices)
    }

    /// Human-readable summary (for tests and debugging).
    func description(_ tokenizerInfo: TokenizerInfo) -> String {
        let sortedCount = tokenizerInfo.sortedTokens.count
        let uncertain = Set(uncertainIndices)
        var accepted: [Int32] = []
        var rejected: [Int32] = []
        switch storeType {
        case .acceptedBitset:
            for index in 0 ..< Int32(sortedCount) where !uncertain.contains(index) {
                if acceptedBitset[tokenizerInfo.sortedTokenIDs[Int(index)]] { accepted.append(index) } else { rejected.append(index) }
            }
        case .accepted:
            accepted = acceptedIndices
            var cursor = 0
            for index in 0 ..< Int32(sortedCount) {
                while cursor < accepted.count, accepted[cursor] < index { cursor += 1 }
                if cursor < accepted.count, accepted[cursor] == index { continue }
                if uncertain.contains(index) { continue }
                rejected.append(index)
            }
        case .rejected:
            rejected = rejectedIndices
            var cursor = 0
            for index in 0 ..< Int32(sortedCount) {
                while cursor < rejected.count, rejected[cursor] < index { cursor += 1 }
                if cursor < rejected.count, rejected[cursor] == index { continue }
                if uncertain.contains(index) { continue }
                accepted.append(index)
            }
        }
        let storeName = switch storeType {
        case .acceptedBitset: "AcceptedBitset"
        case .accepted: "Accepted"
        case .rejected: "Rejected"
        }
        func ids(_ indices: [Int32]) -> String {
            let tokenIDs = indices.map { tokenizerInfo.sortedTokenIDs[Int($0)] }.sorted()
            return tokenizerInfo.describeTokens(tokenIDs, limit: 100)
        }
        return "AdaptiveTokenMask(num_tokens=\(sortedCount), accepted_num=\(accepted.count), rejected_num=\(rejected.count), uncertain_num=\(uncertainIndices.count), storage_type=\(storeName),\n"
            + "accepted=\(ids(accepted)),\nrejected=\(ids(rejected)),\nuncertain=\(ids(uncertainIndices.array))\n)"
    }
}

/// The token masks of a compiled grammar in one buffer, indexed by slot. Decoding reads mask
/// fields in place through ``mask(at:)``: copying an ``AdaptiveTokenMask`` retains and releases
/// its seven arrays, which on every token cost as much as clearing the bitmask.
///
/// With dynamic compilation the slots of every scanable state exist from the start, but a mask
/// is computed the first time a matcher reads it, then kept for every later matcher.
final class MaskTable: @unchecked Sendable {
    private let slots: [ParserStateCacheKey: Int32]
    private let storage: UnsafeMutableBufferPointer<AdaptiveTokenMask>
    /// Compiled masks belong to automaton states (`subElementID` 0), whose element ids are
    /// unique across rules: slot by element id, so decoding skips hashing the key. -1: no mask
    /// with that element id; -2: several, look up `slots`.
    private let slotByElement: UnsafeMutableBufferPointer<Int32>
    /// Per slot: the rule and sequence of its key, checked on a dense hit.
    private let slotOwners: UnsafeMutableBufferPointer<(ruleID: Int32, sequenceID: Int32)>
    /// Dynamic compilation: computes the masks not yet in `storage`; `nil` when every mask was
    /// compiled up front.
    private let source: LazyMaskSource?
    /// Dynamic compilation: per slot, whether its mask is in `storage`. A slot is written once,
    /// under `publication`, before its flag is stored with release ordering.
    private let ready: UnsafeMutablePointer<Atomic<UInt8>>?
    /// Serializes publication; shares the buffers of equal masks as they arrive.
    private let publication = Mutex(MaskStorageInterner())

    /// Number of slots (every mask, computed or not).
    var capacity: Int { storage.count }

    /// Number of computed masks.
    var count: Int {
        guard let ready else { return storage.count }
        return (0 ..< storage.count).count { ready[$0].load(ordering: .acquiring) != 0 }
    }

    /// Whether masks are computed on demand.
    var isDynamic: Bool { source != nil }

    /// The computed masks keyed by state, rebuilt on each access (serialization, tests, debugging).
    var dictionary: [ParserStateCacheKey: AdaptiveTokenMask] {
        var result = [ParserStateCacheKey: AdaptiveTokenMask](minimumCapacity: slots.count)
        for (key, slot) in slots where isReady(slot) { result[key] = storage[Int(slot)] }
        return result
    }

    /// Calls `body` with every computed mask, in place.
    func forEachMask(_ body: (borrowing AdaptiveTokenMask) -> Void) {
        for index in storage.indices where isReady(Int32(index)) { body(storage[index]) }
    }

    init(_ masks: [ParserStateCacheKey: AdaptiveTokenMask]) {
        storage = .allocate(capacity: masks.count)
        for (index, entry) in masks.enumerated() {
            (storage.baseAddress.unsafelyUnwrapped + index).initialize(to: entry.value)
        }
        (slots, slotByElement, slotOwners) = Self.index(masks.keys)
        source = nil
        ready = nil
    }

    /// A table whose masks `source` computes on demand, one slot per state of `source.states`.
    init(lazy source: LazyMaskSource) {
        let keys = source.states.map(ParserStateCacheKey.init)
        storage = .allocate(capacity: keys.count)
        (slots, slotByElement, slotOwners) = Self.index(keys)
        self.source = source
        let ready = UnsafeMutablePointer<Atomic<UInt8>>.allocate(capacity: keys.count)
        for index in 0 ..< keys.count { (ready + index).initialize(to: Atomic<UInt8>(0)) }
        self.ready = ready
    }

    /// Slot lookup tables for `keys`, slot `i` being the `i`-th key.
    private static func index(_ keys: some Collection<ParserStateCacheKey>)
        -> ([ParserStateCacheKey: Int32], UnsafeMutableBufferPointer<Int32>, UnsafeMutableBufferPointer<(ruleID: Int32, sequenceID: Int32)>) {
        let owners = UnsafeMutableBufferPointer<(ruleID: Int32, sequenceID: Int32)>.allocate(capacity: keys.count)
        var slots = [ParserStateCacheKey: Int32](minimumCapacity: keys.count)
        var maxElement: Int32 = -1
        for (index, key) in keys.enumerated() {
            owners.initializeElement(at: index, to: (key.ruleID, key.sequenceID))
            slots[key] = Int32(index)
            if key.subElementID == 0 { maxElement = max(maxElement, key.elementID) }
        }
        let slotByElement = UnsafeMutableBufferPointer<Int32>.allocate(capacity: Int(maxElement) + 1)
        slotByElement.initialize(repeating: -1)
        for (key, slot) in slots where key.subElementID == 0 && key.elementID >= 0 {
            let element = Int(key.elementID)
            slotByElement[element] = slotByElement[element] == -1 ? slot : -2
        }
        return (slots, slotByElement, owners)
    }

    deinit {
        if let ready {
            for index in storage.indices where ready[index].load(ordering: .acquiring) != 0 {
                (storage.baseAddress.unsafelyUnwrapped + index).deinitialize(count: 1)
            }
            ready.deinitialize(count: storage.count)
            ready.deallocate()
        } else {
            storage.deinitialize()
        }
        storage.deallocate()
        slotOwners.deallocate()
        slotByElement.deallocate()
    }

    @inline(__always)
    func slot(for state: ParserState) -> Int32? {
        if state.subElementID == 0, state.elementID >= 0, Int(state.elementID) < slotByElement.count {
            let slot = slotByElement[Int(state.elementID)]
            if slot == -1 { return nil }
            if slot >= 0 {
                let owner = slotOwners[Int(slot)]
                if owner.ruleID == state.ruleID, owner.sequenceID == state.sequenceID { return slot }
            }
        }
        return slots[ParserStateCacheKey(state)]
    }

    /// The mask of `slot`, computed first under dynamic compilation. Valid while this table is
    /// alive.
    @inline(__always)
    func mask(at slot: Int32) -> UnsafePointer<AdaptiveTokenMask> {
        if let ready, ready[Int(slot)].load(ordering: .acquiring) == 0 { materialize(slot) }
        return UnsafePointer(storage.baseAddress.unsafelyUnwrapped + Int(slot))
    }

    @inline(__always)
    private func isReady(_ slot: Int32) -> Bool {
        guard let ready else { return true }
        return ready[Int(slot)].load(ordering: .acquiring) != 0
    }

    /// Computes every mask not computed yet (before serialization).
    func materializeAll() {
        guard ready != nil else { return }
        for slot in 0 ..< Int32(storage.count) { _ = mask(at: slot) }
    }

    /// Computes the mask outside the lock, so other slots are not held up; concurrent requests
    /// for the same slot may compute it twice, and the first to publish wins (as upstream).
    @inline(never)
    private func materialize(_ slot: Int32) {
        guard let source, let ready else { return }
        var mask = source.mask(at: Int(slot))
        publication.withLock { interner in
            guard ready[Int(slot)].load(ordering: .relaxed) == 0 else { return }
            interner.intern(&mask)
            (storage.baseAddress.unsafelyUnwrapped + Int(slot)).initialize(to: mask)
            ready[Int(slot)].store(1, ordering: .releasing)
        }
    }
}

/// What dynamic compilation needs to compute a mask on demand: the prepared grammar and the
/// data eager compilation computes once for all masks.
/// How lazily computed masks are shared: through the compiler's rule-level cache, or among the
/// rules of one grammar with identical automata (`sharedKeys`: the only keys looked up).
struct MaskSharing: Sendable {
    var cache: RuleLevelCache? = nil
    var hashes: GrammarFSMHashes? = nil
    var sharedKeys: Set<RuleLevelCacheKey>? = nil
}

final class LazyMaskSource: Sendable {
    /// The scanable states, in slot order.
    let states: [ParserState]
    private let grammar: Grammar
    private let tokenizerInfo: TokenizerInfo
    private let secondSlicing: TagDispatchSlicing
    private let maxThreads: Int
    private let planSharing: @Sendable () -> MaskSharing
    /// Planned with the first mask.
    private let sharing = Mutex<MaskSharing?>(nil)
    /// Counted-repetition analysis, computed with the first mask (`.some(nil)`: none).
    private let repetitionBodies = Mutex<[CompiledGrammar.RepetitionFollowBytes?]??>(nil)
    /// Idle mask computers (their parser and vocabulary-walk buffers), reused across requests.
    private let computers = Mutex<[TokenMaskComputer]>([])

    init(states: [ParserState], grammar: Grammar, tokenizerInfo: TokenizerInfo, secondSlicing: TagDispatchSlicing, maxThreads: Int,
         planSharing: @escaping @Sendable () -> MaskSharing) {
        self.states = states
        self.grammar = grammar
        self.tokenizerInfo = tokenizerInfo
        self.secondSlicing = secondSlicing
        self.maxThreads = maxThreads
        self.planSharing = planSharing
    }

    /// The mask of slot `slot`, as eager compilation computes it.
    func mask(at slot: Int) -> AdaptiveTokenMask {
        let state = states[slot]
        var computer: TokenMaskComputer
        if let idle = computers.withLock({ $0.popLast() }) {
            computer = idle
            computer.reset(initialState: state)
        } else {
            let plan = sharing.withLock { plan in
                if let plan { return plan }
                let planned = planSharing()
                plan = planned
                return planned
            }
            computer = TokenMaskComputer(grammar: grammar, initialState: state, tagDispatchSecondSlicing: secondSlicing, tokenizerInfo: tokenizerInfo,
                                         ruleLevelCache: plan.cache, fsmHashes: plan.hashes, sharedKeys: plan.sharedKeys)
        }
        var mask = computer.adaptiveTokenMask(isRootRule: state.ruleID == grammar.storage.rootRuleID)
        computers.withLock { if $0.count < 2 { $0.append(computer) } }
        mask.compact()
        let key = ParserStateCacheKey(state)
        let bodies = repetitionBodies.withLock { known in
            if let known { return known }
            let computed = CompiledGrammar.repetitionBodiesIfAny(grammar.storage)
            known = .some(computed)
            return computed
        }
        if let repetitionBodies = bodies, CompiledGrammar.needsRepeatInterior(key, grammar.storage, repetitionBodies) {
            CompiledGrammar.populateRepeatInterior(key, &mask, grammar.storage, tokenizerInfo, repetitionBodies, maxThreads: maxThreads)
            mask.compact()
        }
        return mask
    }
}

/// A grammar compiled against a tokenizer, ready to drive a ``GrammarMatcher``.
///
/// Compilation is the expensive step (it walks the vocabulary for every automaton state); the
/// result is immutable and can be shared by any number of matchers and threads.
public final class CompiledGrammar: Sendable {
    /// The optimized grammar (rule automata built).
    public let grammar: Grammar
    public let tokenizerInfo: TokenizerInfo
    /// Every mask keyed by state (computing the missing ones under dynamic compilation), rebuilt
    /// from ``maskTable`` on each access: keep one copy only.
    var masks: [ParserStateCacheKey: AdaptiveTokenMask] {
        maskTable.materializeAll()
        return maskTable.dictionary
    }
    /// The masks laid out for decoding.
    let maskTable: MaskTable

    init(grammar: Grammar, tokenizerInfo: TokenizerInfo, masks: consuming [ParserStateCacheKey: AdaptiveTokenMask]) {
        self.grammar = grammar
        self.tokenizerInfo = tokenizerInfo
        var interner = MaskStorageInterner()
        for index in masks.indices {
            masks.values[index].compact()
            interner.intern(&masks.values[index])
        }
        maskTable = MaskTable(masks)
    }

    /// A dynamically compiled grammar: masks are computed when a matcher first needs them.
    init(grammar: Grammar, tokenizerInfo: TokenizerInfo, lazyMasks: LazyMaskSource) {
        self.grammar = grammar
        self.tokenizerInfo = tokenizerInfo
        maskTable = MaskTable(lazy: lazyMasks)
    }

    /// Whether token masks are computed on demand (see ``GrammarCompiler/isDynamicCompilationEnabled``).
    /// The masks computed so far are shared by every matcher of this grammar.
    public var isDynamicallyCompiled: Bool { maskTable.isDynamic }

    /// Approximate size of the mask cache in bytes (used by the compiler's LRU cache).
    public var memorySize: Int {
        let storage = grammar.storage
        var total = (storage.exprData.count + storage.exprOffsets.count + storage.allowEmptyRuleIDs.count) * 4
        total += storage.rules.count * MemoryLayout<GrammarRule>.stride
        total += storage.suffixStopInfos.count * MemoryLayout<SuffixStopInfo>.stride
        for rule in storage.rules { total += rule.name.utf8.count + rule.captureName.utf8.count }
        if let fsm = storage.completeFSM {
            total += (fsm.offsets.count + fsm.auxData.count) * 4 + fsm.edges.count * MemoryLayout<FSMEdge>.stride
        }
        for fragment in storage.perRuleFSMs { total += MemoryLayout<CompactFSMWithStartEndWithSize?>.stride + (fragment?.fsm.ends.count ?? 0) * 4 }
        total += grammar.parserTables?.memorySize ?? 0
        return total + maskMemorySize
    }

    /// Heap held by the masks.
    var maskMemorySize: Int {
        var total = maskTable.count * (MemoryLayout<ParserStateCacheKey>.stride + MemoryLayout<Int32>.stride + MemoryLayout<AdaptiveTokenMask>.stride)
        // Masks share buffers (within-grammar sharing, interning): count each buffer once.
        var buffers = Set<UnsafeRawPointer>()
        func add<Element>(_ array: [Element]) {
            guard array.capacity > 0 else { return }
            let base = array.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress.unsafelyUnwrapped) }
            if buffers.insert(base).inserted { total += array.storageBytes }
        }
        maskTable.forEachMask { mask in
            add(mask.acceptedIndices)
            add(mask.rejectedIndices)
            add(mask.uncertainIndices.bounds)
            add(mask.acceptedBitset.words)
            add(mask.repeatInteriorBitsets)
            for bitset in mask.repeatInteriorBitsets { add(bitset.words) }
            add(mask.repeatInteriorCharCounts)
            add(mask.repeatInteriorTokens)
            add(mask.repeatExitTokens)
        }
        return total
    }
}

/// Makes content-equal mask parts share one buffer. States of different rules often reach the
/// same partition (every string value of a schema accepts the same tokens inside the string),
/// and a 150k-token bitset costs 19 KB. Short index lists are left alone: they are cheap, and
/// hashing them would only slow down the compilation of small grammars. Counted-repetition
/// bitsets are left alone too: each belongs to one repetition budget and they are never equal.
struct MaskStorageInterner {
    private var bitsets: [UInt64: [[UInt32]]] = [:]
    private var indices: [UInt64: [[Int32]]] = [:]
    static let minimumInternedIndices = 64

    mutating func intern(_ mask: inout AdaptiveTokenMask) {
        if mask.storeType == .acceptedBitset, mask.acceptedBitset.vocabSize > 0 {
            var words = mask.acceptedBitset.words
            if Self.intern(&words, in: &bitsets) { mask.acceptedBitset = TokenBitmask(vocabSize: mask.acceptedBitset.vocabSize, words: words) }
        }
        if mask.acceptedIndices.count >= Self.minimumInternedIndices { _ = Self.intern(&mask.acceptedIndices, in: &indices) }
        if mask.rejectedIndices.count >= Self.minimumInternedIndices { _ = Self.intern(&mask.rejectedIndices, in: &indices) }
        if mask.uncertainIndices.bounds.count >= Self.minimumInternedIndices { mask.uncertainIndices.withBounds { _ = Self.intern(&$0, in: &indices) } }
    }

    /// Replaces `values` with an equal array seen before; returns whether it did.
    private static func intern<Element: FixedWidthInteger>(_ values: inout [Element], in table: inout [UInt64: [[Element]]]) -> Bool {
        let digest = Self.digest(values)
        if let candidates = table[digest] {
            for candidate in candidates where candidate == values {
                values = candidate
                return true
            }
        }
        table[digest, default: []].append(values)
        return false
    }

    /// A fast content digest (8 bytes per multiply); collisions are resolved by comparison.
    private static func digest<Element: FixedWidthInteger>(_ values: [Element]) -> UInt64 {
        values.withUnsafeBytes { raw in
            var hash: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ UInt64(raw.count)
            let words = raw.count / 8
            for index in 0 ..< words {
                hash = (hash ^ raw.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self)) &* 0xFF51_AFD7_ED55_8CCD
                hash ^= hash >> 29
            }
            for index in words * 8 ..< raw.count { hash = (hash ^ UInt64(raw[index])) &* 0xC4CE_B9FE_1A85_EC53 }
            return hash
        }
    }
}

// MARK: - Counted-repetition fast path

extension CompiledGrammar {
    /// Bytes that can follow a counted repetition under all / any reference, and the largest
    /// upper bound of those references.
    struct RepetitionFollowBytes: Sendable {
        var underAll = ByteSet.all
        var underAny = ByteSet()
        var maxUpper: Int32 = 0
    }

    /// Follows single-element wrappers down to the matched element.
    private static func unwrapSingleElement(_ grammar: GrammarStorage, _ initial: GrammarExpr) -> GrammarExpr {
        var expr = initial
        for _ in 0 ..< 4 {
            let wrapper = expr.kind == .choices || expr.kind == .sequence
            if !wrapper || expr.count != 1 { break }
            expr = grammar.expr(expr[0])
        }
        return expr
    }

    /// Next state after `byte` in an automaton whose byte ranges do not overlap, or `-1`.
    @inline(__always)
    private static func nextState(_ fsm: CompactFSM, from state: Int32, byte: UInt8) -> Int32 {
        let value = Int32(byte)
        for edge in fsm.edges(of: state) where edge.min <= value && value <= edge.max { return edge.target }
        return -1
    }

    /// Whether the rule matches exactly one code point of a character class (or one element of
    /// a regex, such as an escape-aware JSON string character) through a deterministic byte
    /// automaton with no rule-level semantics. Returns the first bytes.
    private static func plainCharacterClassFirstBytes(_ grammar: GrammarStorage, ruleID: Int32) -> ByteSet? {
        let rule = grammar.rule(ruleID)
        if ruleID == grammar.rootRuleID || rule.lookaheadAssertionID != -1 || rule.maxTokens >= 0 || rule.maxChars >= 0
            || !rule.captureName.isEmpty || rule.isLazy || rule.temperature != nil || grammar.suffixStopInfo(for: ruleID) != nil {
            return nil
        }
        let body = unwrapSingleElement(grammar, grammar.expr(rule.bodyExprID))
        guard body.kind == .characterClass || body.kind == .regex, let ruleFSM = grammar.perRuleFSMs[Int(ruleID)] else { return nil }
        let fsm = ruleFSM.fsm
        if fsm.isEndState(fsm.start) { return nil }
        var firstBytes = ByteSet()
        for state in fsm.reachableStates() {
            var seen = ByteSet()
            for edge in fsm.fsm.edges(of: state) {
                if !edge.isCharRange || edge.max > 0xFF || fsm.isEndState(state) { return nil }
                for value in edge.min ... edge.max {
                    let byte = UInt8(value)
                    if seen.contains(byte) { return nil }
                    seen.insert(byte)
                }
            }
            if state == fsm.start { firstBytes = seen }
        }
        return firstBytes
    }

    /// Rules whose start state gets the fast path: plain character-class rules every reference
    /// to which is a repeat edge followed only by bytes no code point of the class starts with.
    static func countedRepetitionBodies(_ grammar: GrammarStorage) -> [RepetitionFollowBytes?] {
        let ruleCount = grammar.ruleCount
        var firstBytes = [ByteSet?](repeating: nil, count: ruleCount)
        for ruleID in 0 ..< Int32(ruleCount) {
            // The matcher bypasses the fast path when character budgets are enforced.
            if grammar.rule(ruleID).maxChars >= 0 { return Array(repeating: nil, count: ruleCount) }
            firstBytes[Int(ruleID)] = plainCharacterClassFirstBytes(grammar, ruleID: ruleID)
        }

        var disqualified = [Bool](repeating: false, count: ruleCount)
        var referenced = [Bool](repeating: false, count: ruleCount)
        var follow = [RepetitionFollowBytes](repeating: RepetitionFollowBytes(), count: ruleCount)
        for ruleID in 0 ..< Int32(ruleCount) {
            if let info = grammar.suffixStopInfo(for: ruleID) {
                if info.bodyRuleID >= 0 { disqualified[Int(info.bodyRuleID)] = true }
                if info.markerRuleID >= 0 { disqualified[Int(info.markerRuleID)] = true }
            }
            guard let ruleFSM = grammar.perRuleFSMs[Int(ruleID)] else { continue }
            let fsm = ruleFSM.fsm
            for state in fsm.reachableStates() {
                for edge in fsm.fsm.edges(of: state) {
                    if edge.isRuleRef {
                        disqualified[Int(edge.ruleID)] = true
                        continue
                    }
                    guard edge.isRepeatRef else { continue }
                    let info = fsm.fsm.repeatInfo(at: edge.auxIndex)
                    let bodyRuleID = Int(info.ruleID)
                    guard let bodyFirstBytes = firstBytes[bodyRuleID] else { continue }
                    referenced[bodyRuleID] = true
                    if fsm.isEndState(edge.target) {
                        disqualified[bodyRuleID] = true
                        continue
                    }
                    var bytes = ByteSet()
                    for followEdge in fsm.fsm.edges(of: edge.target) {
                        if !followEdge.isCharRange || followEdge.max > 0xFF {
                            disqualified[bodyRuleID] = true
                            break
                        }
                        bytes.insert(range: followEdge.min ... followEdge.max)
                    }
                    var overlap = bytes
                    overlap.formIntersection(bodyFirstBytes)
                    if !overlap.isEmpty { disqualified[bodyRuleID] = true }
                    follow[bodyRuleID].underAll.formIntersection(bytes)
                    follow[bodyRuleID].underAny.formUnion(bytes)
                    follow[bodyRuleID].maxUpper = max(follow[bodyRuleID].maxUpper, info.upper)
                }
            }
        }

        var result = [RepetitionFollowBytes?](repeating: nil, count: ruleCount)
        for ruleID in 0 ..< ruleCount where firstBytes[ruleID] != nil && referenced[ruleID] && !disqualified[ruleID] {
            result[ruleID] = follow[ruleID]
        }
        return result
    }

    private enum RepetitionTokenClass {
        /// Legal exactly when the budget left covers the repetitions.
        case budget(Int32)
        /// Leaves the repetition on its last byte.
        case exit(Int32)
        case rejected
        case undecided
    }

    /// The tokens of one vocabulary range, classified against a counted repetition, in sorted order.
    private struct RepetitionClassification: Sendable {
        var budget: [(repetitions: Int32, index: Int32)] = []
        var exits: [(repetitions: Int32, index: Int32)] = []
        /// Rejected and exit indices.
        var decided: [Int32] = []
    }

    /// Classifies the sorted tokens in `range`. Sorted neighbours share prefixes, so the walk
    /// resumes after the common prefix with the previous token: `trail[i]` is the state and
    /// repetition count after `i` bytes of it, valid up to `trailDepth`.
    private static func classifyRepetitionTokens(_ fsm: CompactFSMWithStartEnd, _ follow: RepetitionFollowBytes,
                                                 _ sortedTokens: ByteStringTable, _ range: Range<Int>) -> RepetitionClassification {
        var result = RepetitionClassification()
        var trail: [(state: Int32, repetitions: Int32)] = [(fsm.start, 0)]
        var trailDepth = 0
        sortedTokens.withUnsafeStorage { bytes, offsets in
            var previous: UnsafeBufferPointer<UInt8>? = nil
            for index in range {
                let token = UnsafeBufferPointer(rebasing: bytes[Int(offsets[index]) ..< Int(offsets[index &+ 1])])
                var depth = 0
                if let previous {
                    let limit = min(trailDepth, token.count, previous.count)
                    while depth < limit, token[depth] == previous[depth] { depth &+= 1 }
                }
                previous = token
                trail.removeSubrange((depth + 1)...)
                var (state, repetitions) = trail[depth]
                var outcome: RepetitionTokenClass? = nil
                var position = depth
                while position < token.count {
                    let byte = token[position]
                    let next = nextState(fsm.fsm, from: state, byte: byte)
                    if next == -1 {
                        if state != fsm.start || repetitions == 0 || !follow.underAny.contains(byte) {
                            outcome = .rejected
                        } else if position + 1 == token.count, follow.underAll.contains(byte) {
                            outcome = .exit(repetitions)
                        } else {
                            outcome = .undecided
                        }
                        break
                    }
                    state = next
                    if fsm.isEndState(state) {
                        repetitions += 1
                        state = fsm.start
                        if repetitions > follow.maxUpper {
                            outcome = .rejected
                            break
                        }
                    }
                    trail.append((state, repetitions))
                    position += 1
                }
                trailDepth = trail.count - 1
                if outcome == nil {
                    if state != fsm.start { repetitions += 1 }
                    outcome = repetitions > follow.maxUpper ? .rejected : .budget(repetitions)
                }
                switch outcome.unsafelyUnwrapped {
                case let .budget(count): result.budget.append((count, Int32(index)))
                case let .exit(count):
                    result.exits.append((count, Int32(index)))
                    result.decided.append(Int32(index))
                case .rejected: result.decided.append(Int32(index))
                case .undecided: break
                }
            }
        }
        return result
    }

    /// Classifies the whole vocabulary on up to `maxThreads` workers; the chunks are
    /// independent and concatenated in order, so the result does not depend on the split.
    private static func classifyRepetitionTokens(_ fsm: CompactFSMWithStartEnd, _ follow: RepetitionFollowBytes,
                                                 _ sortedTokens: ByteStringTable, maxThreads: Int) -> RepetitionClassification {
        let count = sortedTokens.count
        let chunks = maxThreads <= 1 ? 1 : min(maxThreads * 2, count / 8192)
        if chunks <= 1 { return classifyRepetitionTokens(fsm, follow, sortedTokens, 0 ..< count) }
        let parts = Mutex([RepetitionClassification?](repeating: nil, count: chunks))
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let part = classifyRepetitionTokens(fsm, follow, sortedTokens, count * chunk / chunks ..< count * (chunk + 1) / chunks)
            parts.withLock { $0[chunk] = part }
        }
        var result = RepetitionClassification()
        for part in parts.withLock({ $0 }) {
            let part = part.unsafelyUnwrapped
            result.budget += part.budget
            result.exits += part.exits
            result.decided += part.decided
        }
        return result
    }

    /// Computes the counted-repetition fast-path data for every mask.
    static func populateRepeatInteriorBitsets(_ grammar: GrammarStorage, _ tokenizerInfo: TokenizerInfo, _ masks: inout [ParserStateCacheKey: AdaptiveTokenMask],
                                              maxThreads: Int = ProcessorCount.active) {
        guard let bodies = repetitionBodiesIfAny(grammar) else { return }
        // Masks arrive fresh (computed, or deserialized without repetition data), so only those
        // that get repetition data are touched; each is moved out of the dictionary first so
        // that editing it copies nothing.
        for key in Array(masks.keys) where needsRepeatInterior(key, grammar, bodies) {
            var mask = masks.removeValue(forKey: key).unsafelyUnwrapped
            populateRepeatInterior(key, &mask, grammar, tokenizerInfo, bodies, maxThreads: maxThreads)
            masks[key] = mask
        }
    }

    /// The counted-repetition bodies, or `nil` when the grammar has no repeat edge (bodies are
    /// only reached through them).
    static func repetitionBodiesIfAny(_ grammar: GrammarStorage) -> [RepetitionFollowBytes?]? {
        guard let complete = grammar.completeFSM, complete.edges.contains(where: \.isRepeatRef) else { return nil }
        return countedRepetitionBodies(grammar)
    }

    /// Whether the mask of `key` gets counted-repetition data.
    static func needsRepeatInterior(_ key: ParserStateCacheKey, _ grammar: GrammarStorage, _ bodies: [RepetitionFollowBytes?]) -> Bool {
        guard key.ruleID >= 0, bodies[Int(key.ruleID)] != nil else { return false }
        return key.elementID == grammar.perRuleFSMs[Int(key.ruleID)].unsafelyUnwrapped.fsm.start
    }

    /// Computes the counted-repetition fast-path data of one mask (see ``needsRepeatInterior``).
    static func populateRepeatInterior(_ key: ParserStateCacheKey, _ mask: inout AdaptiveTokenMask, _ grammar: GrammarStorage,
                                       _ tokenizerInfo: TokenizerInfo, _ bodies: [RepetitionFollowBytes?], maxThreads: Int) {
        let follow = bodies[Int(key.ruleID)].unsafelyUnwrapped
        let fsm = grammar.perRuleFSMs[Int(key.ruleID)].unsafelyUnwrapped.fsm
        let sortedTokens = tokenizerInfo.sortedTokens
        let sortedIDs = tokenizerInfo.sortedTokenIDs
        mask.repeatInteriorCharCounts.removeAll()
        mask.repeatInteriorBitsets.removeAll()
        mask.repeatInteriorTokens.removeAll()
        mask.repeatExitTokens.removeAll()
        do {
            let classification = classifyRepetitionTokens(fsm, follow, sortedTokens, maxThreads: maxThreads)
            let budget = classification.budget
            for (count, index) in classification.exits { mask.repeatExitTokens.append((count, sortedIDs[Int(index)])) }
            if budget.isEmpty, mask.repeatExitTokens.isEmpty { return }

            // Group the budget tokens by count with a stable counting sort (a token consumes at
            // most one repetition per byte, so counts stay small).
            let maxCount = Int(budget.lazy.map(\.repetitions).max() ?? 0)
            var groupStarts = [Int](repeating: 0, count: maxCount + 2)
            for entry in budget { groupStarts[Int(entry.repetitions) + 1] += 1 }
            for count in 0 ... maxCount { groupStarts[count + 1] += groupStarts[count] }
            var grouped = [Int32](repeating: 0, count: budget.count)
            var cursors = groupStarts
            for entry in budget {
                grouped[cursors[Int(entry.repetitions)]] = entry.index
                cursors[Int(entry.repetitions)] += 1
            }

            // Before a count's tokens join, fewer than `threshold` are pending, so every gap
            // between checkpoints (and the tail) lists fewer than `threshold` tokens.
            let threshold = AdaptiveTokenMask.repeatCheckpointTokens(vocabSize: tokenizerInfo.vocabSize)
            var cumulative = TokenBitmask(vocabSize: tokenizerInfo.vocabSize)
            var pending = 0
            for count in 0 ... maxCount where groupStarts[count] < groupStarts[count + 1] {
                let group = grouped[groupStarts[count] ..< groupStarts[count + 1]]
                for index in group { cumulative[sortedIDs[Int(index)]] = true }
                if pending + group.count >= threshold {
                    mask.repeatInteriorCharCounts.append(Int32(count))
                    mask.repeatInteriorBitsets.append(cumulative)
                    pending = 0
                } else {
                    for index in group { mask.repeatInteriorTokens.append((Int32(count), sortedIDs[Int(index)])) }
                    pending += group.count
                }
            }
            // Both lists are in index order.
            var decided = classification.decided
            SortedIntSet.formUnion(&decided, budget.map(\.index))


            // Take the decided tokens out of every static class. A rejected-list mask would
            // accept them implicitly, so it becomes an accepted bitset first.
            switch mask.storeType {
            case .rejected:
                var notAccepted = mask.rejectedIndices
                SortedIntSet.formUnion(&notAccepted, mask.uncertainIndices.array)
                SortedIntSet.formUnion(&notAccepted, decided)
                var bitset = TokenBitmask(vocabSize: tokenizerInfo.vocabSize)
                var cursor = 0
                for index in 0 ..< Int32(sortedTokens.count) {
                    while cursor < notAccepted.count, notAccepted[cursor] < index { cursor += 1 }
                    if cursor == notAccepted.count || notAccepted[cursor] != index { bitset[sortedIDs[Int(index)]] = true }
                }
                mask.acceptedBitset = bitset
                mask.rejectedIndices.removeAll()
                mask.storeType = .acceptedBitset
            case .acceptedBitset:
                for index in decided { mask.acceptedBitset[sortedIDs[Int(index)]] = false }
            case .accepted:
                SortedIntSet.subtract(&mask.acceptedIndices, decided)
            }
            var uncertain = mask.uncertainIndices.array
            SortedIntSet.subtract(&uncertain, decided)
            mask.uncertainIndices = IndexRuns(uncertain)
        }
    }
}
