// The Earley parser over per-rule automata. Every rule body is an FSM; a parser state is a
// position in one rule's automaton plus the input position where that rule occurrence began.
// Three operations drive it: scan (consume a byte on a byte edge), predict (enter the rules
// referenced from the current FSM state) and complete (pop back to the parent states recorded
// when the rule was predicted). Histories are stacks of rows, one per accepted byte, so rolling
// back is a truncation.

/// One item of the Earley chart.
struct ParserState: Hashable, Sendable {
    /// A `ruleStartPos` of this value marks the root of the parsing stack.
    static let noPreviousInputPosition: Int32 = -1

    /// The rule being matched; `-1` for a position in a raw sequence expression (used by the
    /// compiler when exploring expressions without an automaton).
    var ruleID: Int32 = -1
    /// Body expression id of the rule, or the sequence expression id when `ruleID == -1`.
    var sequenceID: Int32 = -1
    /// The automaton state (or the element index of the sequence when `ruleID == -1`).
    var elementID: Int32 = -1
    /// Input position at which this occurrence of the rule started.
    var ruleStartPos: Int32 = -1
    /// Last token index this derivation may consume (token budget), `-1` if unlimited.
    var budgetDeadline: Int32 = -1
    /// Progress inside the current element: byte index in a byte string, or remaining
    /// continuation bytes of the UTF-8 character being read by a character class.
    var subElementID: Int32 = 0
    /// Number of completed iterations of a counted repetition.
    var repeatCount: Int32 = 0
    /// Partial code point accumulated while reading a multi-byte character.
    var partialCodepoint: Int32 = 0
    /// Innermost active rule that specifies a sampling temperature.
    var activeTemperatureRuleID: Int32 = -1
    /// Absolute character index at which the active character budget expires, `-1` if none.
    var charBudgetDeadline: Int32 = -1

    init() {}

    init(
        ruleID: Int32, sequenceID: Int32, elementID: Int32, ruleStartPos: Int32,
        budgetDeadline: Int32 = -1, subElementID: Int32 = 0, repeatCount: Int32 = 0, partialCodepoint: Int32 = 0,
        activeTemperatureRuleID: Int32 = -1, charBudgetDeadline: Int32 = -1
    ) {
        self.ruleID = ruleID
        self.sequenceID = sequenceID
        self.elementID = elementID
        self.ruleStartPos = ruleStartPos
        self.budgetDeadline = budgetDeadline
        self.subElementID = subElementID
        self.repeatCount = repeatCount
        self.partialCodepoint = partialCodepoint
        self.activeTemperatureRuleID = activeTemperatureRuleID
        self.charBudgetDeadline = charBudgetDeadline
    }

    /// The same state moved to `elementID`, with element-local progress reset.
    @inline(__always)
    func moved(to elementID: Int32, repeatCount: Int32 = 0) -> ParserState {
        ParserState(
            ruleID: ruleID, sequenceID: sequenceID, elementID: elementID, ruleStartPos: ruleStartPos,
            budgetDeadline: budgetDeadline, subElementID: 0, repeatCount: repeatCount, partialCodepoint: 0,
            activeTemperatureRuleID: activeTemperatureRuleID, charBudgetDeadline: charBudgetDeadline
        )
    }

    var description: String {
        var result = "ParserState(rule_id=\(ruleID), sequence_id=\(sequenceID), element_id=\(elementID), rule_start_pos=\(ruleStartPos), sub_element_id=\(subElementID)"
        if repeatCount != 0 { result += ", repeat_count=\(repeatCount)" }
        if partialCodepoint != 0 { result += ", partial_codepoint=\(partialCodepoint)" }
        if budgetDeadline != -1 { result += ", budget_deadline=\(budgetDeadline)" }
        if activeTemperatureRuleID != -1 { result += ", active_temperature_rule_id=\(activeTemperatureRuleID)" }
        if charBudgetDeadline != -1 { result += ", char_budget_deadline=\(charBudgetDeadline)" }
        return result + ")"
    }
}

extension ParserState: Comparable {
    /// Lexicographic order over all fields; used only for deterministic serialization.
    static func < (lhs: ParserState, rhs: ParserState) -> Bool {
        if lhs.ruleID != rhs.ruleID { return lhs.ruleID < rhs.ruleID }
        if lhs.sequenceID != rhs.sequenceID { return lhs.sequenceID < rhs.sequenceID }
        if lhs.elementID != rhs.elementID { return lhs.elementID < rhs.elementID }
        if lhs.ruleStartPos != rhs.ruleStartPos { return lhs.ruleStartPos < rhs.ruleStartPos }
        if lhs.budgetDeadline != rhs.budgetDeadline { return lhs.budgetDeadline < rhs.budgetDeadline }
        if lhs.subElementID != rhs.subElementID { return lhs.subElementID < rhs.subElementID }
        if lhs.repeatCount != rhs.repeatCount { return lhs.repeatCount < rhs.repeatCount }
        if lhs.partialCodepoint != rhs.partialCodepoint { return lhs.partialCodepoint < rhs.partialCodepoint }
        if lhs.activeTemperatureRuleID != rhs.activeTemperatureRuleID { return lhs.activeTemperatureRuleID < rhs.activeTemperatureRuleID }
        return lhs.charBudgetDeadline < rhs.charBudgetDeadline
    }
}

/// Key of the token-mask cache: the mask of a state does not depend on where the rule
/// occurrence started, the repeat count or a partial code point.
struct ParserStateCacheKey: Hashable, Sendable {
    var ruleID: Int32
    var sequenceID: Int32
    var elementID: Int32
    var subElementID: Int32

    init(_ state: ParserState) {
        ruleID = state.ruleID
        sequenceID = state.sequenceID
        elementID = state.elementID
        subElementID = state.subElementID
    }
}

/// A concrete occurrence of a captured rule.
struct CaptureOccurrence: Hashable, Sendable {
    var ruleID: Int32
    var startPos: Int32
}

/// A completion of a captured rule, recorded in the history row of the position where it
/// completed; the matched span is `[startPos, row)`.
struct CaptureEvent: Hashable, Sendable {
    var ruleID: Int32
    /// Start of the span; ``ParserState/noPreviousInputPosition`` means position 0.
    var startPos: Int32
    /// Unadjusted start of this occurrence (differs from `startPos` for the zero-width event
    /// inserted after a dynamic-dispatch marker).
    var occurrenceStartPos: Int32
    /// Trailing bytes hidden only from this rule's own capture.
    var hiddenSuffixBytes: Int32 = 0
    /// Trailing bytes hidden from every containing capture.
    var hiddenStopBytes: Int32 = 0
    /// Captured occurrences whose parent chains contain this stop completion.
    var stopCaptureTargets: [CaptureOccurrence] = []
}

/// Membership test for states enqueued in one processing round: an open-addressing index over
/// the round's states. Every slot carries the round's generation, so starting a round only
/// bumps the generation instead of clearing the table; a linear scan of the states was the
/// largest cost of `enqueue` on deep JSON stacks.
struct ParserStateVisitedSet {
    private var states = RoundBuffer<ParserState>(capacity: 64)
    /// `generation << 32 | index into states`; a slot of another generation is empty.
    private var slots = RoundBuffer<UInt64>(capacity: 128)
    private var generation: UInt64 = 0

    @inline(__always)
    private static func hash(_ state: ParserState) -> UInt64 {
        var h = UInt64(UInt32(bitPattern: state.elementID)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(UInt32(bitPattern: state.ruleStartPos)) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= UInt64(UInt32(bitPattern: state.ruleID)) &* 0x1656_67B1_9E37_79F9
        h ^= UInt64(UInt32(bitPattern: state.sequenceID &+ state.subElementID &* 31 &+ state.repeatCount &* 1009))
        return h ^ (h >> 29)
    }

    /// Inserts `state`; returns whether it was absent.
    @inline(__always)
    mutating func insert(_ state: ParserState) -> Bool {
        let mask = slots.count &- 1
        var index = Int(truncatingIfNeeded: Self.hash(state)) & mask
        while true {
            let slot = slots[index]
            if slot >> 32 != generation { break }
            if states[Int(truncatingIfNeeded: UInt32(truncatingIfNeeded: slot))] == state { return false }
            index = (index &+ 1) & mask
        }
        slots[index] = generation << 32 | UInt64(states.count)
        states.append(state)
        if states.count &* 2 > slots.count { grow() }
        return true
    }

    @inline(never)
    private mutating func grow() {
        slots.fill(count: slots.count * 2, with: 0)
        let mask = slots.count &- 1
        for position in 0 ..< states.count {
            var index = Int(truncatingIfNeeded: Self.hash(states[position])) & mask
            while slots[index] >> 32 == generation { index = (index &+ 1) & mask }
            slots[index] = generation << 32 | UInt64(position)
        }
    }

    /// Empties the set at the start of a parser round (see ``RoundBuffer/beginRound(shared:)``).
    @inline(__always)
    mutating func beginRound(shared: Bool) {
        states.beginRound(shared: shared)
        generation &+= 1
        if shared || slots.isEmpty || generation > UInt64(UInt32.max) {
            // Fresh storage (or a wrapped generation) holds no valid stamps yet.
            let size = max(slots.count, 128)
            slots.beginRound(shared: shared)
            slots.fill(count: size, with: 0)
            generation = 1
        }
    }
}

/// A completable parent entry: the referenced rule and the state waiting for it.
struct CompletableEntry: Hashable, Sendable {
    var ruleID: Int32
    var state: ParserState
}

struct EarleyParser: Sendable {
    let grammar: Grammar
    /// ARC-free tables of the optimized grammar; every hot-path lookup goes through here.
    private let tables: ParserTables

    /// `isCompleted[i]`: whether the root rule is complete after `i` accepted positions.
    private(set) var isCompletedHistory = TruncatingStack<Bool>()
    /// Per input position, the parent states waiting for a rule to complete.
    private(set) var completableStates = Rows<CompletableEntry>()
    /// Per input position, the states that can scan the next byte.
    private(set) var scanableStateHistory = Rows<ParserState>()
    /// Per input position, the capture events recorded there (only with capture tracking).
    private(set) var captureEventHistory = Rows<CaptureEvent>()

    private var pendingScanable = RoundBuffer<ParserState>()
    private var queue = RoundBuffer<ParserState>()
    private var queueHead = 0
    private var visited = ParserStateVisitedSet()
    private var acceptStopTokenThisRound = false
    private var completedLazyOccurrences: [(ruleID: Int32, startPos: Int32)] = []

    /// Index of the LLM token currently being accepted (set by the matcher); `-1` before any.
    var currentTokenIndex: Int32 = -1
    /// Whether states past their budget deadline are skipped when scanning.
    var skipExpiredStates = false
    /// Whether a lookahead reached an exclude-token element, which its byte scan cannot take:
    /// the lookahead check then leaves the token to the parent instead of rejecting it.
    var lookaheadReachedExcludeToken = false
    var hasBudgetRules: Bool { tables.hasBudgetRules }
    var hasCharBudgetRules: Bool { tables.hasCharBudgetRules }
    var hasTokenEdges: Bool { tables.hasTokenEdges }
    /// A superset of the bytes the grammar can consume anywhere.
    var byteAlphabet: ByteSet { tables.byteAlphabet }
    /// Number of code points accepted at every history row (only with character budgets).
    private var charCountHistory: [Int32] = []
    private var charBudgetEntryHistory: [Bool] = []
    private var charBudgetEnteredThisRound = false

    /// Whether any rule has a capture name (fixed at construction; disables all capture work
    /// when false).
    var isCaptureTrackingEnabled: Bool { tables.isCaptureTrackingEnabled }
    /// Whether completions record capture events; only on during definitive advances.
    var isCaptureRecording = false

    // MARK: Construction

    init(grammar: Grammar, initialState: ParserState? = nil) {
        guard let tables = grammar.parserTables else {
            preconditionFailure("The grammar is not optimized. Please optimize the grammar before using the Earley parser.")
        }
        self.grammar = grammar
        self.tables = tables
        pushStateAndExpand(initialState ?? rootInitialState())
    }

    // MARK: Queries

    var isCompleted: Bool { isCompletedHistory.last }

    /// Number of history rows (accepted positions + 1).
    var historyCount: Int { scanableStateHistory.count }

    var latestScanableStates: ArraySlice<ParserState> { scanableStateHistory.last }

    var currentCharIndex: Int32 { charCountHistory.last ?? 0 }

    var hasEnteredCharBudget: Bool { hasCharBudgetRules && charBudgetEntryHistory[charBudgetEntryHistory.count &- 1] }

    func isRuleNullable(_ ruleID: Int32) -> Bool { tables.ruleFlags(of: ruleID).contains(.isNullable) }

    @inline(__always)
    func isExpiredState(_ state: ParserState) -> Bool {
        state.budgetDeadline >= 0 && currentTokenIndex > state.budgetDeadline
    }

    @inline(__always)
    func isCharExpiredState(_ state: ParserState) -> Bool {
        state.charBudgetDeadline >= 0 && currentCharIndex >= state.charBudgetDeadline
    }

    /// Capture events of the latest position.
    var lastCaptureRow: [CaptureEvent] {
        isCaptureTrackingEnabled ? Array(captureEventHistory.last) : []
    }

    var statesDescription: String {
        var result = "There are \(scanableStateHistory.count) steps in history. Last step: [\n"
        for state in scanableStateHistory.last { result += state.description + ", \n" }
        return result + "]"
    }

    // MARK: Deadlines

    @inline(__always)
    private func deadline(forRule ruleID: Int32, parent parentDeadline: Int32) -> Int32 {
        let own = tables.maxTokens(of: ruleID)
        if own < 0 { return parentDeadline }
        let deadline = Int32(clamping: Int64(currentTokenIndex) + Int64(own))
        return parentDeadline >= 0 ? min(deadline, parentDeadline) : deadline
    }

    @inline(__always)
    private func charDeadline(forRule ruleID: Int32, parent parentDeadline: Int32) -> Int32 {
        let own = tables.maxChars(of: ruleID)
        if own < 0 { return parentDeadline }
        let current = currentCharIndex
        let deadline = own > Int32.max - current ? Int32.max : current + own
        return parentDeadline >= 0 ? min(deadline, parentDeadline) : deadline
    }

    @inline(__always)
    private func activeTemperatureRule(entering ruleID: Int32, inherited: Int32) -> Int32 {
        tables.ruleFlags(of: ruleID).contains(.hasTemperature) ? ruleID : inherited
    }

    // MARK: Queue

    @inline(__always)
    private mutating func enqueue(_ state: ParserState) {
        if visited.insert(state) { queue.append(state) }
    }

    /// Enqueues a state that needs neither prediction nor completion.
    @inline(__always)
    private mutating func enqueueWithoutProcessing(_ state: ParserState) {
        if visited.insert(state) { pendingScanable.append(state) }
    }

    private mutating func beginRound() {
        assert(queueHead == queue.count, "The processing queue should be empty before a round.")
        // Runs once per scanned byte: the round buffers only reset their counts. They are copied
        // together with the parser, so the queue's uniqueness stands for all three.
        let shared = queue.isShared()
        queue.beginRound(shared: shared)
        queueHead = 0
        visited.beginRound(shared: shared)
        pendingScanable.beginRound(shared: shared)
        acceptStopTokenThisRound = false
        if !completedLazyOccurrences.isEmpty { completedLazyOccurrences.removeAll(keepingCapacity: true) }
    }

    /// Runs predict/complete over the queue and pushes the resulting row.
    private mutating func drainQueueAndCommitRow() {
        while queueHead < queue.count {
            let state = queue[queueHead]
            queueHead &+= 1
            let (scanable, completable) = predict(state)
            if completable { complete(state) }
            if scanable { pendingScanable.append(state) }
        }
        queue.removeAll()
        queueHead = 0
        if !completedLazyOccurrences.isEmpty { removeCommittedLazyStates() }
        isCompletedHistory.append(acceptStopTokenThisRound)
        scanableStateHistory.pushRow(pendingScanable.elements)
    }

    /// Committed-shortest matching: drop the remaining states of lazy occurrences completed in
    /// this row so they cannot be extended further.
    private mutating func removeCommittedLazyStates() {
        let committed = completedLazyOccurrences
        pendingScanable.removeAll { state in
            committed.contains { $0.ruleID == state.ruleID && $0.startPos == state.ruleStartPos }
        }
    }

    // MARK: Public driving

    private func rootInitialState() -> ParserState {
        let rootRuleID = tables.rootRuleID
        return ParserState(
            ruleID: rootRuleID,
            sequenceID: tables.bodyExprID(of: rootRuleID),
            elementID: tables.start(of: rootRuleID),
            ruleStartPos: ParserState.noPreviousInputPosition,
            budgetDeadline: deadline(forRule: rootRuleID, parent: -1),
            activeTemperatureRuleID: activeTemperatureRule(entering: rootRuleID, inherited: -1),
            charBudgetDeadline: charDeadline(forRule: rootRuleID, parent: -1)
        )
    }

    /// Pushes a fresh row seeded with `state`, expanded by prediction and completion.
    mutating func pushStateAndExpand(_ state: ParserState) {
        beginRound()
        enqueue(state)
        completableStates.pushEmptyRow()
        if isCaptureTrackingEnabled { captureEventHistory.pushEmptyRow() }
        drainQueueAndCommitRow()
        if hasCharBudgetRules {
            charCountHistory.append(currentCharIndex)
            charBudgetEntryHistory.append(charBudgetEnteredThisRound)
        }
    }

    /// Pushes a temporary row holding `states` (used for token-mask checks).
    mutating func pushStatesToCheck(_ states: some Sequence<ParserState>, completed: Bool) {
        completableStates.pushEmptyRow()
        isCompletedHistory.append(completed)
        scanableStateHistory.pushRow(states)
        if isCaptureTrackingEnabled { captureEventHistory.pushEmptyRow() }
        if hasCharBudgetRules {
            charCountHistory.append(currentCharIndex)
            charBudgetEntryHistory.append(charBudgetEntryHistory[charBudgetEntryHistory.count &- 1])
        }
    }

    mutating func pushOneStateToCheck(_ state: ParserState) {
        pushStatesToCheck(CollectionOfOne(state), completed: isCompleted)
    }

    /// Pushes a character-count row for a parser row created by the matcher.
    mutating func pushCharCountRow(charCount: Int32, charBudgetEntered: Bool) {
        guard hasCharBudgetRules else { return }
        charCountHistory.append(charCount)
        charBudgetEntryHistory.append(charBudgetEntered)
    }

    /// Pushes a capture-event row for a position created outside `advance`.
    mutating func pushCaptureRow(_ events: [CaptureEvent]) {
        if isCaptureTrackingEnabled { captureEventHistory.pushRow(events) }
    }

    /// Discards the newest `count` positions.
    mutating func popLastStates(_ count: Int = 1) {
        precondition(count < completableStates.count, "The number of states to be popped is larger than the size of states.")
        completableStates.popRows(count)
        isCompletedHistory.removeLast(count)
        scanableStateHistory.popRows(count)
        if isCaptureTrackingEnabled { captureEventHistory.popRows(count) }
        if hasCharBudgetRules {
            charCountHistory.removeLast(count)
            charBudgetEntryHistory.removeLast(count)
        }
    }

    // MARK: Row surgery (matcher support)

    /// A snapshot of the latest position, restorable with ``restoreLatestRow(_:)``.
    struct RowSnapshot {
        var scanable: [ParserState]
        var completable: [CompletableEntry]
        var captures: [CaptureEvent]
        var completed: Bool
    }

    var latestCompletableRow: ArraySlice<CompletableEntry> { completableStates.last }

    func snapshotLatestRow() -> RowSnapshot {
        RowSnapshot(scanable: Array(scanableStateHistory.last), completable: Array(completableStates.last), captures: lastCaptureRow, completed: isCompleted)
    }

    mutating func restoreLatestRow(_ snapshot: RowSnapshot) {
        scanableStateHistory.popRows(1)
        scanableStateHistory.pushRow(snapshot.scanable)
        completableStates.popRows(1)
        completableStates.pushRow(snapshot.completable)
        isCompletedHistory.last = snapshot.completed
        if isCaptureTrackingEnabled {
            captureEventHistory.popRows(1)
            captureEventHistory.pushRow(snapshot.captures)
        }
    }

    /// Pushes a complete position assembled by the matcher (used when merging the atomic-token
    /// and byte-level advance results).
    mutating func pushRow(scanable: [ParserState], completable: [CompletableEntry], captures: [CaptureEvent], completed: Bool, charCount: Int32, charBudgetEntered: Bool) {
        scanableStateHistory.pushRow(scanable)
        completableStates.pushRow(completable)
        isCompletedHistory.append(completed)
        pushCaptureRow(captures)
        pushCharCountRow(charCount: charCount, charBudgetEntered: charBudgetEntered)
    }

    /// Rebuilds the latest row at a budget boundary: keeps the states `isAlive` accepts,
    /// completes `forceCompleted` occurrences without their marker, and re-runs prediction and
    /// completion. When expired states survive next to live ones (or the root completes), the
    /// expired ones are dropped. Returns whether a derivation remains viable; on `false` the
    /// scanable row is untouched (the completable and capture rows may have grown).
    mutating func enforceBudget(isAlive: (ParserState) -> Bool, forceCompleted: [ParserState]) -> Bool {
        assert(queueHead == queue.count)
        let shared = queue.isShared()
        queue.beginRound(shared: shared)
        queueHead = 0
        visited.beginRound(shared: shared)
        pendingScanable.beginRound(shared: shared)
        completedLazyOccurrences.removeAll(keepingCapacity: true)
        acceptStopTokenThisRound = isCompleted

        let latest = Array(scanableStateHistory.last)
        for state in latest where isAlive(state) { enqueueWithoutProcessing(state) }
        for state in forceCompleted { complete(state, markerPresent: false) }
        while queueHead < queue.count {
            let state = queue[queueHead]
            queueHead &+= 1
            let (scanable, completable) = predict(state)
            if completable { complete(state) }
            if scanable { pendingScanable.append(state) }
        }
        queue.removeAll()
        queueHead = 0
        if !completedLazyOccurrences.isEmpty { removeCommittedLazyStates() }

        var anyExpired = false
        var anyAlive = false
        for state in pendingScanable.elements {
            if isAlive(state) { anyAlive = true } else { anyExpired = true }
        }
        if anyExpired, anyAlive || acceptStopTokenThisRound {
            pendingScanable.removeAll { !isAlive($0) }
        }
        guard acceptStopTokenThisRound || !pendingScanable.isEmpty else { return false }
        scanableStateHistory.popRows(1)
        scanableStateHistory.pushRow(pendingScanable.elements)
        isCompletedHistory.last = acceptStopTokenThisRound
        return true
    }

    /// Clears the history and starts again from `initialState` (the root rule by default).
    mutating func reset(initialState: ParserState? = nil) {
        completableStates.removeAll()
        scanableStateHistory.removeAll()
        isCompletedHistory.removeAll()
        if isCaptureTrackingEnabled { captureEventHistory.removeAll() }
        charCountHistory.removeAll(keepingCapacity: true)
        charBudgetEntryHistory.removeAll(keepingCapacity: true)
        charBudgetEnteredThisRound = false
        isCaptureRecording = false
        pushStateAndExpand(initialState ?? rootInitialState())
    }

    /// Consumes one byte. On rejection the parser is unchanged.
    @discardableResult
    mutating func advance(_ byte: UInt8) -> Bool {
        beginRound()
        if hasCharBudgetRules {
            charBudgetEnteredThisRound = charBudgetEntryHistory[charBudgetEntryHistory.count &- 1]
            charCountHistory.append(currentCharIndex + (Self.startsCodepoint(byte) ? 1 : 0))
        }
        // Index the history rather than slicing it: a live slice would make the row pushed
        // below copy the whole history buffer.
        if skipExpiredStates {
            for index in scanableStateHistory.lastRowIndices {
                let state = scanableStateHistory.element(at: index)
                if !isExpiredState(state) { scan(state, byte) }
            }
        } else {
            for index in scanableStateHistory.lastRowIndices { scan(scanableStateHistory.element(at: index), byte) }
        }
        if queue.isEmpty, pendingScanable.isEmpty {
            if hasCharBudgetRules { charCountHistory.removeLast() }
            return false
        }
        completableStates.pushEmptyRow()
        if isCaptureTrackingEnabled { captureEventHistory.pushEmptyRow() }
        drainQueueAndCommitRow()
        if hasCharBudgetRules { charBudgetEntryHistory.append(charBudgetEnteredThisRound) }
        return true
    }

    /// Consumes one whole token through token / exclude-token edges.
    @discardableResult
    mutating func advanceAtomicToken(_ tokenID: Int32, charCount: Int32 = 0) -> Bool {
        beginRound()
        if hasCharBudgetRules {
            charBudgetEnteredThisRound = charBudgetEntryHistory[charBudgetEntryHistory.count &- 1]
            charCountHistory.append(currentCharIndex + charCount)
        }
        for index in scanableStateHistory.lastRowIndices {
            let state = scanableStateHistory.element(at: index)
            if skipExpiredStates, isExpiredState(state) { continue }
            scanAtomicToken(state, tokenID)
        }
        if queue.isEmpty, pendingScanable.isEmpty {
            if hasCharBudgetRules { charCountHistory.removeLast() }
            return false
        }
        completableStates.pushEmptyRow()
        if isCaptureTrackingEnabled { captureEventHistory.pushEmptyRow() }
        drainQueueAndCommitRow()
        if hasCharBudgetRules { charBudgetEntryHistory.append(charBudgetEnteredThisRound) }
        return true
    }

    /// The latest of the last `rows` history rows (1 is the oldest, after the token's first byte)
    /// with a token-level free-text state that takes `tokenID` whole; 0 when there is none. A
    /// token whose first bytes finish a literal is taken by the region from that row. A negative
    /// `tokenID` only asks whether such a state exists.
    func findMidTokenExcludeEdgeRow(rows: Int, tokenID: Int32) -> Int {
        guard tables.hasTokenEdges, rows > 0 else { return 0 }
        let size = scanableStateHistory.count
        for row in stride(from: rows, through: 1, by: -1) {
            for index in scanableStateHistory.indices(ofRow: size &- 1 &- (rows &- row)) {
                let state = scanableStateHistory.element(at: index)
                guard state.ruleID != -1, tables.flags(of: state.elementID).contains(.hasExcludeToken) else { continue }
                if tokenID < 0 { return row }
                for edge in tables.edges(of: state.elementID) where edge.isExcludeToken {
                    if !tables.tokenSet(at: edge.auxIndex, contains: tokenID) { return row }
                }
            }
        }
        return 0
    }

    @inline(__always)
    private static func startsCodepoint(_ byte: UInt8) -> Bool { byte & 0xC0 != 0x80 }

    // MARK: Predict

    /// Returns whether the state is scanable and whether it is completable.
    private mutating func predict(_ state: ParserState) -> (scanable: Bool, completable: Bool) {
        if state.ruleID != -1 {
            let stateFlags = tables.flags(of: state.elementID)
            if stateFlags.contains(.nonTerminal) { expandNextRuleRefElementOnFSM(state) }
            return (stateFlags.contains(.scanable), stateFlags.contains(.end))
        }
        let sequence = tables.exprPayload(state.sequenceID)
        if Int(state.elementID) == sequence.count { return (false, true) }
        let elementID = sequence[Int(state.elementID)]
        switch tables.exprKind(elementID) {
        case .ruleRef:
            expandNextRuleRefElement(state, sequenceCount: sequence.count, element: tables.exprPayload(elementID), isRepeat: false)
            return (false, false)
        case .characterClassStar:
            if state.subElementID == 0 { enqueue(state.moved(to: state.elementID + 1)) }
            return (true, false)
        case .repeat:
            let element = tables.exprPayload(elementID)
            assert(state.repeatCount <= element[2])
            expandNextRuleRefElement(state, sequenceCount: sequence.count, element: element, isRepeat: true)
            if state.repeatCount >= element[1] { enqueue(state.moved(to: state.elementID + 1)) }
            return (false, false)
        case .byteString, .characterClass:
            return (true, false)
        case .token:
            return (false, false)
        case .excludeToken:
            // Only lookaheads are scanned by bytes here; a free-text region ends that scan.
            lookaheadReachedExcludeToken = true
            return (false, false)
        default:
            preconditionFailure("The element type is not supported! The type is: \(tables.exprKind(elementID))")
        }
    }

    @inline(__always)
    private func ruleNeedsCaptureEvent(_ ruleID: Int32) -> Bool {
        ruleID >= 0 && tables.ruleFlags(of: ruleID).contains(.needsCaptureEvent)
    }

    /// Whether `state` (with `ruleID`) is already recorded as waiting for `refRuleID` in the
    /// latest completable row.
    private func latestRowContains(_ refRuleID: Int32, _ state: ParserState) -> Bool {
        for index in completableStates.lastRowIndices {
            let entry = completableStates.element(at: index)
            if entry.ruleID == refRuleID, entry.state == state { return true }
        }
        return false
    }

    /// Right recursion: instead of recording `state` as a parent, record its own parents so
    /// the completion of the referenced rule completes the ancestors directly.
    private mutating func liftParentsForRightRecursion(of state: ParserState, to refRuleID: Int32) {
        // The parents' row precedes the latest one, so appending leaves its indices valid.
        for index in completableStates.indices(ofRow: Int(state.ruleStartPos)) {
            let entry = completableStates.element(at: index)
            if entry.ruleID == state.ruleID, !latestRowContains(refRuleID, entry.state) {
                completableStates.appendToLastRow(CompletableEntry(ruleID: refRuleID, state: entry.state))
            }
        }
    }

    @inline(__always)
    private mutating func enterRule(_ refRuleID: Int32, from state: ParserState, rightRecursionToRoot: Bool) {
        if tables.maxChars(of: refRuleID) >= 0 { charBudgetEnteredThisRound = true }
        enqueue(ParserState(
            ruleID: refRuleID,
            sequenceID: tables.bodyExprID(of: refRuleID),
            elementID: tables.start(of: refRuleID),
            ruleStartPos: rightRecursionToRoot ? ParserState.noPreviousInputPosition : Int32(completableStates.count &- 1),
            budgetDeadline: deadline(forRule: refRuleID, parent: state.budgetDeadline),
            activeTemperatureRuleID: activeTemperatureRule(entering: refRuleID, inherited: state.activeTemperatureRuleID),
            charBudgetDeadline: charDeadline(forRule: refRuleID, parent: state.charBudgetDeadline)
        ))
    }

    private mutating func expandNextRuleRefElement(_ state: ParserState, sequenceCount: Int, element: UnsafeBufferPointer<Int32>, isRepeat: Bool) {
        let refRuleID = element[0]
        var rightRecursionToRoot = false
        // The right-recursion optimization elides the completion of the parent rule, so it is
        // disabled when either rule produces capture events.
        if Int(state.elementID) != sequenceCount - 1 || isRepeat
            || Int(state.ruleStartPos) == completableStates.count - 1
            || ruleNeedsCaptureEvent(state.ruleID) || ruleNeedsCaptureEvent(refRuleID) {
            completableStates.appendToLastRow(CompletableEntry(ruleID: refRuleID, state: state))
        } else if state.ruleStartPos == ParserState.noPreviousInputPosition {
            rightRecursionToRoot = true
        } else {
            liftParentsForRightRecursion(of: state, to: refRuleID)
        }
        if isRuleNullable(refRuleID) { enqueue(state.moved(to: state.elementID + 1)) }
        enterRule(refRuleID, from: state, rightRecursionToRoot: rightRecursionToRoot)
    }

    private mutating func expandNextRuleRefElementOnFSM(_ state: ParserState) {
        for edge in tables.edges(of: state.elementID) {
            if edge.isEpsilon {
                enqueue(state.moved(to: edge.target))
                continue
            }
            let target = edge.target
            let refRuleID: Int32
            var isRepeat = false
            if edge.isRuleRef {
                refRuleID = edge.ruleID
            } else if edge.isRepeatRef {
                isRepeat = true
                let info = tables.repeatInfo(at: edge.auxIndex)
                refRuleID = info.ruleID
                if state.repeatCount >= info.lower { enqueue(state.moved(to: target)) }
                if state.repeatCount >= info.upper { continue }
            } else {
                continue
            }

            var rightRecursionToRoot = false
            let targetFlags = tables.flags(of: target)
            if !isRepeat, !targetFlags.contains(.hasEdges), targetFlags.contains(.end),
               Int(state.ruleStartPos) != completableStates.count - 1,
               !ruleNeedsCaptureEvent(state.ruleID), !ruleNeedsCaptureEvent(refRuleID) {
                if state.ruleStartPos == ParserState.noPreviousInputPosition {
                    rightRecursionToRoot = true
                } else {
                    liftParentsForRightRecursion(of: state, to: refRuleID)
                }
            } else if isRepeat {
                // Repeat: keep the source state and the count so completion can iterate.
                completableStates.appendToLastRow(CompletableEntry(
                    ruleID: refRuleID, state: state.moved(to: state.elementID, repeatCount: state.repeatCount)
                ))
            } else {
                // Rule reference: record the post-transition state.
                completableStates.appendToLastRow(CompletableEntry(ruleID: refRuleID, state: state.moved(to: target)))
            }

            if !isRepeat, isRuleNullable(refRuleID) { enqueue(state.moved(to: target)) }
            enterRule(refRuleID, from: state, rightRecursionToRoot: rightRecursionToRoot)
        }
    }

    // MARK: Complete

    private mutating func complete(_ state: ParserState, markerPresent: Bool = true) {
        if isCaptureRecording, ruleNeedsCaptureEvent(state.ruleID) { recordCaptureEvent(state, markerPresent: markerPresent) }
        if state.ruleID != -1, tables.ruleFlags(of: state.ruleID).contains(.isLazy) {
            completedLazyOccurrences.append((state.ruleID, state.ruleStartPos))
        }
        if state.ruleStartPos == ParserState.noPreviousInputPosition {
            acceptStopTokenThisRound = true
            return
        }
        for index in completableStates.indices(ofRow: Int(state.ruleStartPos)) {
            let entry = completableStates.element(at: index)
            if entry.ruleID != state.ruleID { continue }
            let parent = entry.state
            if parent.ruleID == -1 {
                let parentSequence = tables.exprPayload(parent.sequenceID)
                let elementID = parentSequence[Int(parent.elementID)]
                if tables.exprKind(elementID) == .ruleRef {
                    enqueue(parent.moved(to: parent.elementID + 1))
                    continue
                }
                let element = tables.exprPayload(elementID)
                let newCount = parent.repeatCount + 1
                if newCount >= element[1] { enqueue(parent.moved(to: parent.elementID + 1)) }
                if newCount < element[2] {
                    var repeated = parent
                    repeated.repeatCount = newCount
                    enqueue(repeated)
                }
                continue
            }
            // The parent sits in an automaton; if it waits on a repeat edge, count the iteration.
            var handledAsRepeat = false
            for edge in tables.edges(of: parent.elementID) where edge.isRepeatRef {
                let info = tables.repeatInfo(at: edge.auxIndex)
                if info.ruleID != entry.ruleID { continue }
                handledAsRepeat = true
                let newCount = parent.repeatCount + 1
                if newCount >= info.lower { enqueue(parent.moved(to: edge.target)) }
                if newCount < info.upper { enqueue(parent.moved(to: parent.elementID, repeatCount: newCount)) }
                break
            }
            if !handledAsRepeat { enqueue(parent) }
        }
    }

    // MARK: Scan

    @inline(__always)
    private mutating func scan(_ state: ParserState, _ byte: UInt8) {
        if state.ruleID == -1 {
            let sequence = tables.exprPayload(state.sequenceID)
            let elementID = sequence[Int(state.elementID)]
            let element = tables.exprPayload(elementID)
            switch tables.exprKind(elementID) {
            case .byteString: advanceByteString(state, byte, element)
            case .characterClass: advanceCharacterClass(state, byte, element, star: false)
            case .characterClassStar: advanceCharacterClass(state, byte, element, star: true)
            default: preconditionFailure("The element type is not supported! The type is: \(tables.exprKind(elementID))")
            }
        } else {
            advanceFSM(state, byte)
        }
    }

    private mutating func advanceByteString(_ state: ParserState, _ byte: UInt8, _ element: UnsafeBufferPointer<Int32>) {
        guard UInt8(truncatingIfNeeded: element[Int(state.subElementID)]) == byte else { return }
        var next = state
        next.subElementID += 1
        if Int(next.subElementID) == element.count {
            next.elementID += 1
            next.subElementID = 0
            enqueue(next)
        } else {
            pendingScanable.append(next)
        }
    }

    /// Whether `[low, high]` overlaps any range of the class.
    @inline(__always)
    private static func classCouldMatch(_ element: UnsafeBufferPointer<Int32>, low: Int32, high: Int32) -> Bool {
        var index = 1
        while index + 1 < element.count {
            if high >= element[index], low <= element[index + 1] { return true }
            index += 2
        }
        return false
    }

    @inline(__always)
    private static func classContains(_ element: UnsafeBufferPointer<Int32>, _ codepoint: Int32) -> Bool {
        var index = 1
        while index + 1 < element.count {
            if codepoint >= element[index], codepoint <= element[index + 1] { return true }
            index += 2
        }
        return false
    }

    /// Handles both `characterClass` (advances the element on a match) and
    /// `characterClassStar` (stays on the element).
    private mutating func advanceCharacterClass(_ state: ParserState, _ byte: UInt8, _ element: UnsafeBufferPointer<Int32>, star: Bool) {
        let isNegative = element[0] != 0

        if state.subElementID > 0 {
            // Continuation byte of a multi-byte character.
            guard byte & 0xC0 == 0x80 else { return }
            var next = state
            next.subElementID -= 1
            next.partialCodepoint = (next.partialCodepoint << 6) | Int32(byte & 0x3F)
            if next.subElementID == 0 {
                let matches = Self.classContains(element, next.partialCodepoint)
                if matches != isNegative {
                    if !star { next.elementID += 1 }
                    next.partialCodepoint = 0
                    enqueue(next)
                }
            } else {
                let remaining = next.subElementID
                let low = next.partialCodepoint << (6 * remaining)
                let high = low | ((1 << (6 * remaining)) - 1)
                if isNegative || Self.classCouldMatch(element, low: low, high: high) { pendingScanable.append(next) }
            }
            return
        }

        if byte >= 0x80 {
            guard let (length, partial) = Self.utf8FirstByte(byte) else { return }
            let low = partial << (6 * (length - 1))
            let high = low | ((1 << (6 * (length - 1))) - 1)
            if isNegative || Self.classCouldMatch(element, low: low, high: high) {
                var next = state
                next.subElementID = length - 1
                next.partialCodepoint = partial
                pendingScanable.append(next)
            }
            return
        }

        let matches = Self.classContains(element, Int32(byte))
        if matches != isNegative {
            if star {
                enqueue(state)
            } else {
                enqueue(state.moved(to: state.elementID + 1))
            }
        }
    }

    /// Length and payload bits of a UTF-8 lead byte, or `nil` for an invalid lead byte.
    @inline(__always)
    private static func utf8FirstByte(_ byte: UInt8) -> (length: Int32, partial: Int32)? {
        switch byte {
        case 0xC0 ... 0xDF: (2, Int32(byte & 0x1F))
        case 0xE0 ... 0xEF: (3, Int32(byte & 0x0F))
        case 0xF0 ... 0xF7: (4, Int32(byte & 0x07))
        default: nil
        }
    }

    @inline(__always)
    private mutating func enqueueAfterTransition(_ state: ParserState, to target: Int32) {
        var next = state
        next.elementID = target
        let targetFlags = tables.flags(of: target)
        if !targetFlags.contains(.nonTerminal), !targetFlags.contains(.end), targetFlags.contains(.scanable) {
            enqueueWithoutProcessing(next)
        } else {
            enqueue(next)
        }
    }

    @inline(__always)
    private mutating func advanceFSM(_ state: ParserState, _ byte: UInt8) {
        let value = Int32(byte)
        for edge in tables.edges(of: state.elementID) {
            if edge.min < 0 { continue }
            if edge.min > value { break }
            if edge.max < value { continue }
            enqueueAfterTransition(state, to: edge.target)
        }
    }

    private mutating func scanAtomicToken(_ state: ParserState, _ tokenID: Int32) {
        if state.ruleID == -1 { return }
        for edge in tables.edges(of: state.elementID) {
            let matched: Bool
            if edge.isToken {
                matched = tables.tokenSet(at: edge.auxIndex, contains: tokenID)
            } else if edge.isExcludeToken {
                matched = !tables.tokenSet(at: edge.auxIndex, contains: tokenID)
            } else {
                continue
            }
            if matched { enqueueAfterTransition(state, to: edge.target) }
        }
    }

    // MARK: Captures

    @inline(__always)
    private func ruleHasCapture(_ ruleID: Int32) -> Bool {
        isCaptureTrackingEnabled && ruleID >= 0 && !grammar.storage.rule(ruleID).captureName.isEmpty
    }

    /// Whether this completion of a suffix/stop rule actually consumed its trailing marker:
    /// only the terminal post-dispatch state of a tag dispatch has no outgoing edges.
    private func completionConsumedMarker(_ state: ParserState) -> Bool {
        if !tables.ruleFlags(of: state.ruleID).contains(.isTagDispatch) { return true }
        return tables.edges(of: state.elementID).isEmpty
    }

    /// The captured occurrences whose concrete parent chains contain this stop completion.
    private func collectStopCaptureTargets(_ state: ParserState) -> [CaptureOccurrence] {
        var targets: [CaptureOccurrence] = []
        var pending = [CaptureOccurrence(ruleID: state.ruleID, startPos: state.ruleStartPos)]
        var visited = Set<CaptureOccurrence>()
        while let occurrence = pending.popLast() {
            guard visited.insert(occurrence).inserted else { continue }
            if ruleHasCapture(occurrence.ruleID) { targets.append(occurrence) }
            if occurrence.startPos == ParserState.noPreviousInputPosition { continue }
            for entry in completableStates[Int(occurrence.startPos)] where entry.ruleID == occurrence.ruleID && entry.state.ruleID >= 0 {
                pending.append(CaptureOccurrence(ruleID: entry.state.ruleID, startPos: entry.state.ruleStartPos))
            }
        }
        return targets
    }

    private mutating func recordCaptureEvent(_ state: ParserState, markerPresent: Bool) {
        let info = grammar.storage.suffixStopInfo(for: state.ruleID)
        let markerConsumed = markerPresent && info.map { ($0.hiddenSuffixBytes > 0 || $0.hiddenStopBytes > 0) && completionConsumedMarker(state) } ?? false
        let hiddenSuffix = markerConsumed ? info.unsafelyUnwrapped.hiddenSuffixBytes : 0
        let hiddenStop = markerConsumed ? info.unsafelyUnwrapped.hiddenStopBytes : 0
        var eventStart = state.ruleStartPos
        if markerConsumed, info.unsafelyUnwrapped.bodyRuleID == state.ruleID {
            // A self-referencing body helper marks the zero-width event inserted right after a
            // dynamic string trigger; its span is the fixed-length marker before it.
            eventStart -= max(hiddenSuffix, hiddenStop)
        }
        let targets = hiddenStop > 0 ? collectStopCaptureTargets(state) : []
        captureEventHistory.appendToLastRow(CaptureEvent(
            ruleID: state.ruleID, startPos: eventStart, occurrenceStartPos: state.ruleStartPos,
            hiddenSuffixBytes: hiddenSuffix, hiddenStopBytes: hiddenStop, stopCaptureTargets: targets
        ))
    }
}
