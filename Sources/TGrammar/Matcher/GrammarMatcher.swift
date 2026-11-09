// The runtime of constrained decoding: tracks the generated tokens against a compiled grammar,
// produces the bitmask of allowed next tokens, and rolls back for speculative decoding. A
// matcher is a value: copying it forks the matching state.

/// Matches a token stream against a ``CompiledGrammar`` and computes next-token masks.
///
/// ```swift
/// var matcher = GrammarMatcher(compiledGrammar)
/// var mask = TokenBitmask(vocabSize: tokenizerInfo.vocabSize)
/// while !matcher.isTerminated {
///     matcher.fillNextTokenBitmask(&mask)
///     let token = sample(logits, masked: mask)
///     matcher.acceptToken(token)
/// }
/// ```
public struct GrammarMatcher: Sendable {
    public let compiledGrammar: CompiledGrammar
    /// Tokens that terminate generation once the grammar can complete.
    public let stopTokenIDs: [Int32]
    /// Whether ``isTerminated`` is true as soon as the grammar completes, without a stop token.
    public let terminatesWithoutStopToken: Bool
    /// Temperature reported by ``temperature`` when no grammar rule specifies one.
    public let defaultTemperature: Float?

    private(set) var parser: EarleyParser
    private var grammar: GrammarStorage { compiledGrammar.grammar.storage }
    private var tokenizerInfo: TokenizerInfo { compiledGrammar.tokenizerInfo }

    /// Number of parser positions each accepted token created (0 for the stop token).
    private var tokenLengthHistory: [Int] = []
    private var stopTokenAccepted = false

    // Token budgets (`max_tokens`).
    private var budgetEnforcePending = false
    private var budgetForceClosePending = false
    private var hasBudgetMarkerRules = false

    // Character budgets (`max_chars`).
    private var charBudgetRelaxed = false
    private var recordCharBudgetRelaxation = false

    private struct BudgetBodyMatchProgress {
        var beginByte: Int
        var endByte: Int
        var states: Set<Int32>
        var temporaryInputSnapshot: [UInt8]
    }

    /// Incremental body-automaton progress keyed by `(rule, occurrence start row)`.
    private var budgetBodyMatchCache: [CaptureOccurrence: BudgetBodyMatchProgress] = [:]

    /// Bytes accepted so far (kept only for captures and budgeted marker rules).
    private var acceptedBytes: [UInt8] = []
    /// `rowByteEnd[i]` is the number of accepted bytes after position `i`.
    private var rowByteEnd: [Int] = [0]
    /// Bytes tentatively consumed by the current token or string.
    private var temporaryInputBytes: [UInt8] = []
    private var temporaryInputStartRow = -1

    // Scratch for mask filling.
    private var scratchAccepted: TokenBitmask
    /// Whether `scratchAccepted` may hold bits; clearing it is a full pass over the vocabulary,
    /// skipped while it is known to be empty (free text accepts nothing up front).
    private var scratchAcceptedDirty = false
    private var scratchRejected: [Int32] = []
    /// The live states of a fill and the mask-table slots of those decided at runtime, kept
    /// between calls so a fill does not allocate.
    private var scratchStates: [ParserState] = []
    private var scratchStateSlots: [(state: ParserState, slot: Int32)] = []
    private var scratchRejectedDelta: [Int32] = []

    // MARK: Construction

    /// - Parameters:
    ///   - compiledGrammar: The grammar to match against.
    ///   - stopTokenIDs: Overrides the tokenizer's stop tokens; must be non-empty when given.
    ///   - terminateWithoutStopToken: Treat grammar completion as termination.
    ///   - defaultTemperature: Fallback for ``temperature``.
    public init(_ compiledGrammar: CompiledGrammar, stopTokenIDs: [Int32]? = nil, terminateWithoutStopToken: Bool = false, defaultTemperature: Float? = nil) {
        self.compiledGrammar = compiledGrammar
        let tokenizerInfo = compiledGrammar.tokenizerInfo
        if let stopTokenIDs {
            precondition(!stopTokenIDs.isEmpty, "The override stop tokens should not be empty")
            for id in stopTokenIDs {
                precondition(id >= 0 && Int(id) < tokenizerInfo.vocabSize, "The override stop token id \(id) is out of the vocabulary range [0, \(tokenizerInfo.vocabSize))")
            }
        }
        self.stopTokenIDs = stopTokenIDs ?? tokenizerInfo.stopTokenIDs
        terminatesWithoutStopToken = terminateWithoutStopToken
        if let defaultTemperature {
            precondition(defaultTemperature.isFinite && defaultTemperature >= 0, "The default_temperature must be a finite non-negative number")
        }
        self.defaultTemperature = defaultTemperature
        parser = EarleyParser(grammar: compiledGrammar.grammar)
        scratchAccepted = TokenBitmask(vocabSize: tokenizerInfo.vocabSize)

        let storage = compiledGrammar.grammar.storage
        if parser.hasBudgetRules || parser.hasCharBudgetRules {
            for (index, rule) in storage.rules.enumerated() where rule.maxTokens >= 0 || rule.maxChars >= 0 {
                if let info = storage.suffixStopInfo(for: Int32(index)), info.bodyRuleID >= 0 {
                    hasBudgetMarkerRules = true
                    break
                }
            }
        }
    }

    // MARK: State

    /// Whether the grammar can end at the current position.
    public var isCompleted: Bool { parser.isCompleted }

    /// Whether generation is over: a stop token was accepted (or, with
    /// `terminateWithoutStopToken`, the grammar completed).
    public var isTerminated: Bool {
        terminatesWithoutStopToken ? parser.isCompleted : stopTokenAccepted
    }

    /// Whether a stop token has been accepted.
    public var isStopTokenAccepted: Bool { stopTokenAccepted }

    /// Returns the matcher to its initial state.
    public mutating func reset() {
        tokenLengthHistory.removeAll(keepingCapacity: true)
        stopTokenAccepted = false
        parser.currentTokenIndex = -1
        budgetEnforcePending = false
        budgetForceClosePending = false
        charBudgetRelaxed = false
        recordCharBudgetRelaxation = false
        budgetBodyMatchCache.removeAll()
        temporaryInputStartRow = -1
        temporaryInputBytes.removeAll()
        acceptedBytes.removeAll()
        rowByteEnd = [0]
        parser.reset()
    }

    /// An independent copy of the current matching state.
    public func fork() -> GrammarMatcher { self }

    /// Computes next-token masks along speculative branches without changing this matcher.
    /// Traversal is iterative, so deep draft trees never consume the native call stack.
    public func traverseDraftTree(_ tree: DraftTokenTree, timeLimit: Duration? = nil) -> DraftTraversalResult {
        enum Event {
            case enter(Int, parent: Int?)
            case exit(Int, parent: Int?, enforcePending: Bool, forceClosePending: Bool)
        }
        var working = self
        var batch = TokenMaskBatch(rows: tree.nodes.count, vocabSize: tokenizerInfo.vocabSize)
        var temperatures = Array<Float?>(repeating: nil, count: tree.nodes.count)
        var mask = TokenBitmask(vocabSize: tokenizerInfo.vocabSize)
        var events: [Event] = [.enter(0, parent: nil)]
        let start = ContinuousClock.now
        let deadline = timeLimit.flatMap { $0 > .zero ? start + $0 : nil }
        var finished = true
        while let event = events.popLast() {
            switch event {
            case .enter(let index, let parent):
                let node = tree.nodes[index]
                var accepted = !working.isTerminated
                if let parent {
                    let id = Int(node.tokenID)
                    let word = parent * batch.wordsPerRow + (id >> 5)
                    accepted = id >= 0 && id < batch.vocabSize && batch.words[word] & (1 << UInt32(id & 31)) != 0
                    if accepted, let deadline, ContinuousClock.now > deadline { finished = false; events.removeAll(); break }
                }
                let oldEnforce = working.budgetEnforcePending
                let oldForceClose = working.budgetForceClosePending
                if accepted, index != 0 { accepted = working.acceptToken(node.tokenID) }
                if accepted {
                    if !working.isTerminated {
                        working.fillNextTokenBitmask(&mask)
                        batch.setRow(index, mask)
                        temperatures[index] = working.temperature
                    }
                    events.append(.exit(index, parent: parent, enforcePending: oldEnforce, forceClosePending: oldForceClose))
                    if !working.isTerminated, let child = node.firstChild { events.append(.enter(child, parent: index)) }
                } else if let sibling = node.nextSibling {
                    events.append(.enter(sibling, parent: parent))
                }
            case .exit(let index, let parent, let enforce, let forceClose):
                if index != 0 { working.rollback(1) }
                working.budgetEnforcePending = enforce
                working.budgetForceClosePending = forceClose
                if let sibling = tree.nodes[index].nextSibling {
                    events.append(.enter(sibling, parent: parent))
                }
            }
        }
        return .init(masks: batch, temperatures: temperatures, didFinish: finished)
    }

    /// Debug description of the parser's latest states.
    public var debugDescription: String { parser.statesDescription }

    /// Completed captures in completion order. With deduplication, the longest completion
    /// of each rule occurrence is retained. Rolling back also rolls back capture events.
    public func captures(deduplicate: Bool = true) -> [GrammarCapture] {
        guard parser.isCaptureTrackingEnabled else { return [] }
        struct Event {
            var capture: CaptureEvent
            var startRow: Int
            var endRow: Int
            var keep = true
            var markerStart: Int? = nil
        }
        struct Occurrence: Hashable { let rule: Int32; let row: Int32 }
        var events: [Event] = []
        var last: [Occurrence: Int] = [:]
        for row in 0 ..< parser.captureEventHistory.count {
            for capture in parser.captureEventHistory[row] {
                let start = capture.startPos == ParserState.noPreviousInputPosition ? 0 : Int(capture.startPos)
                if deduplicate {
                    let key = Occurrence(rule: capture.ruleID, row: Int32(start))
                    if let previous = last[key] { events[previous].keep = false }
                    last[key] = events.count
                }
                events.append(Event(capture: capture, startRow: start, endRow: row))
            }
        }
        func acceptedPrefixes(_ fsm: CompactFSMWithStartEnd, start: Int, end: Int) -> [Bool] {
            var states: Set<Int32> = [fsm.start]
            fsm.fsm.expandEpsilonClosure(&states)
            var result = [states.contains(where: fsm.isEndState)]
            for offset in start ..< end {
                states = fsm.fsm.advance(from: states, value: Int32(acceptedBytes[offset]), fromIsClosure: true)
                result.append(states.contains(where: fsm.isEndState))
            }
            return result
        }
        func acceptedSuffixes(_ marker: CompactFSMWithStartEnd, start: Int, end: Int) -> [Bool] {
            struct Edge { let source: Int32; let min: Int32; let max: Int32 }
            let reachable = marker.reachableStates()
            var epsilon: [Int32: [Int32]] = [:]
            var edges: [Int32: [Edge]] = [:]
            for source in reachable {
                for edge in marker.fsm.edges(of: source) where reachable.contains(edge.target) {
                    if edge.isEpsilon { epsilon[edge.target, default: []].append(source) }
                    else if edge.isCharRange { edges[edge.target, default: []].append(.init(source: source, min: edge.min, max: edge.max)) }
                }
            }
            func closure(_ states: inout Set<Int32>) {
                var queue = Array(states)
                var index = 0
                while index < queue.count {
                    for previous in epsilon[queue[index]] ?? [] where states.insert(previous).inserted { queue.append(previous) }
                    index += 1
                }
            }
            var states = Set(marker.ends)
            closure(&states)
            var result = Array(repeating: false, count: end - start + 1)
            result[end - start] = states.contains(marker.start)
            for offset in stride(from: end - 1, through: start, by: -1) {
                var previous: Set<Int32> = []
                let byte = Int32(acceptedBytes[offset])
                for target in states {
                    for edge in edges[target] ?? [] where edge.min <= byte && byte <= edge.max { previous.insert(edge.source) }
                }
                closure(&previous)
                states = previous
                result[offset - start] = states.contains(marker.start)
            }
            return result
        }
        for index in events.indices where events[index].keep {
            let event = events[index]
            let hidden = max(event.capture.hiddenSuffixBytes, event.capture.hiddenStopBytes)
            guard hidden > 0, let info = grammar.suffixStopInfo(for: event.capture.ruleID) else { continue }
            let start = rowByteEnd[event.startRow], end = rowByteEnd[event.endRow]
            if info.bodyRuleID < 0 { events[index].markerStart = max(start, end - Int(hidden)); continue }
            guard let body = grammar.perRuleFSMs[Int(info.bodyRuleID)], let marker = grammar.perRuleFSMs[Int(info.markerRuleID)] else { continue }
            let prefixes = acceptedPrefixes(body.fsm, start: start, end: end)
            let suffixes = acceptedSuffixes(marker.fsm, start: start, end: end)
            if let offset = prefixes.indices.first(where: { prefixes[$0] && suffixes[$0] }) { events[index].markerStart = start + offset }
        }
        var hiddenSpans: [Occurrence: [Range<Int>]] = [:]
        for event in events where event.keep && event.capture.hiddenStopBytes > 0 {
            guard let marker = event.markerStart else { continue }
            let end = rowByteEnd[event.endRow]
            for target in event.capture.stopCaptureTargets {
                hiddenSpans[Occurrence(rule: target.ruleID, row: target.startPos), default: []].append(marker ..< end)
            }
        }
        var result: [GrammarCapture] = []
        for event in events where event.keep {
            let rule = grammar.rule(event.capture.ruleID)
            let start = rowByteEnd[event.startRow]
            var end = rowByteEnd[event.endRow]
            if let marker = event.markerStart, let info = grammar.suffixStopInfo(for: event.capture.ruleID), !info.stopCaptureName.isEmpty {
                result.append(.init(name: info.stopCaptureName, bytes: Array(acceptedBytes[marker ..< end])))
            }
            guard !rule.captureName.isEmpty else { continue }
            if event.capture.hiddenSuffixBytes > 0, let marker = event.markerStart { end = marker }
            let key = Occurrence(rule: event.capture.ruleID, row: event.capture.occurrenceStartPos)
            var cursor = start
            var bytes: [UInt8] = []
            for hidden in (hiddenSpans[key] ?? []).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                guard hidden.upperBound > start, hidden.lowerBound < end else { continue }
                let lower = max(hidden.lowerBound, start), upper = min(hidden.upperBound, end)
                if lower > cursor { bytes.append(contentsOf: acceptedBytes[cursor ..< lower]) }
                cursor = max(cursor, upper)
            }
            if cursor < end { bytes.append(contentsOf: acceptedBytes[cursor ..< end]) }
            result.append(.init(name: rule.captureName, bytes: bytes))
        }
        return result
    }

    /// The sampling temperature of the innermost active rule that specifies one, or
    /// ``defaultTemperature``.
    public var temperature: Float? {
        var result: Float? = nil
        for state in parser.latestScanableStates where state.activeTemperatureRuleID != -1 {
            let value = grammar.rule(state.activeTemperatureRuleID).temperature.unsafelyUnwrapped
            if result == nil || value > result.unsafelyUnwrapped { result = value }
        }
        return result ?? defaultTemperature
    }

    private var shouldTrackAcceptedBytes: Bool { parser.isCaptureTrackingEnabled || hasBudgetMarkerRules }

    @inline(__always)
    private static func startsCodepoint(_ byte: UInt8) -> Bool { byte & 0xC0 != 0x80 }

    // MARK: Accepting

    /// Feeds one generated token. Returns `false` (leaving the state unchanged) when the token is
    /// not allowed by the grammar.
    @discardableResult
    public mutating func acceptToken(_ tokenID: Int32) -> Bool {
        if stopTokenAccepted { return false }
        guard tokenID >= 0, Int(tokenID) < tokenizerInfo.vocabSize else { return false }
        let isStopToken = stopTokenIDs.contains(tokenID)
        if !isStopToken, tokenizerInfo.specialTokenIDs.contains(tokenID) { return false }

        parser.currentTokenIndex = Int32(tokenLengthHistory.count)
        charBudgetRelaxed = false
        recordCharBudgetRelaxation = false
        let enforceBudget = budgetEnforcePending
        let forceBudgetClose = budgetForceClosePending
        if forceBudgetClose {
            // Validate on a copy first: a rejected token must not commit the budget-close.
            var trial = self
            trial.parser.isCaptureRecording = false
            guard trial.applyBudgetEnforcement() else { return false }
            trial.budgetEnforcePending = false
            trial.budgetForceClosePending = false
            if !trial.acceptToken(tokenID) { return false }
        }

        parser.isCaptureRecording = parser.isCaptureTrackingEnabled
        defer { parser.isCaptureRecording = false }
        if forceBudgetClose {
            guard applyBudgetEnforcement() else { return false }
            budgetEnforcePending = false
            budgetForceClosePending = false
        }
        parser.skipExpiredStates = enforceBudget && !forceBudgetClose
        defer { parser.skipExpiredStates = false }

        var consumedPastDeadline = false
        if parser.hasBudgetRules, !enforceBudget {
            consumedPastDeadline = parser.latestScanableStates.contains { parser.isExpiredState($0) }
        }

        // A stop token can also be a grammar terminal (Harmony's `<|call|>`); consuming it as one
        // must complete the grammar, with or without termination by stop token.
        if isStopToken {
            if acceptStopToken() { return finishAccept(consumedPastDeadline: consumedPastDeadline) }
            if !canAcceptStopTokenAsTerminal(tokenID) { return false }
        }

        let token = tokenizerInfo.decodedVocab[Int(tokenID)]
        var tokenCharCount: Int32 = 0
        if parser.hasCharBudgetRules {
            for byte in token where Self.startsCodepoint(byte) { tokenCharCount += 1 }
        }

        let sizeBeforeToken = Int32(parser.historyCount)
        let rowBeforeToken = parser.hasCharBudgetRules ? parser.snapshotLatestRow() : nil
        func restoreRowBeforeToken(_ matcher: inout GrammarMatcher) {
            if let rowBeforeToken { matcher.parser.restoreLatestRow(rowBeforeToken) }
        }

        // Phase 1: atomic token edges, from the current state.
        var atomicRow: EarleyParser.RowSnapshot? = nil
        let atomicSuccess = parser.hasCharBudgetRules
            ? advanceAtomicTokenWithCharacterBudget(tokenID, charCount: tokenCharCount)
            : parser.advanceAtomicToken(tokenID)
        if atomicSuccess {
            atomicRow = parser.snapshotLatestRow()
            parser.popLastStates(1)
        }
        restoreRowBeforeToken(&self)

        // Phase 2: byte by byte, from the same original state.
        recordCharBudgetRelaxation = true
        let trackTemporaryInput = parser.hasCharBudgetRules && hasBudgetMarkerRules
        if trackTemporaryInput {
            temporaryInputStartRow = parser.historyCount - 1
            temporaryInputBytes.removeAll(keepingCapacity: true)
        }
        var position = 0
        var bytePathSuccess = true
        for byte in token {
            let accepted = parser.hasCharBudgetRules ? advanceWithCharacterBudget(byte) : parser.advance(byte)
            if !accepted {
                bytePathSuccess = false
                break
            }
            if trackTemporaryInput { temporaryInputBytes.append(byte) }
            position += 1
        }
        if trackTemporaryInput {
            temporaryInputStartRow = -1
            temporaryInputBytes.removeAll(keepingCapacity: true)
        }

        // A token whose first bytes finish a literal before a token-level free-text region (e.g.
        // "\n\n" then any tokens, fed "\n\n\n") is taken whole by the region from there.
        var midTokenRow = 0
        if !bytePathSuccess, !atomicSuccess, !parser.hasCharBudgetRules {
            midTokenRow = parser.findMidTokenExcludeEdgeRow(rows: position, tokenID: tokenID)
        }

        // Phase 3: combine.
        if !bytePathSuccess, !atomicSuccess, midTokenRow == 0 {
            parser.popLastStates(position)
            restoreRowBeforeToken(&self)
            recordCharBudgetRelaxation = false
            charBudgetRelaxed = false
            return false
        }

        if midTokenRow > 0 {
            parser.popLastStates(position - midTokenRow)
            let accepted = parser.advanceAtomicToken(tokenID)
            assert(accepted)
            tokenLengthHistory.append(midTokenRow + 1)
            if shouldTrackAcceptedBytes {
                appendPerByteRows(token.prefix(midTokenRow))
                appendAtomicRow(token.dropFirst(midTokenRow))
            }
        } else if atomicSuccess, !bytePathSuccess {
            parser.popLastStates(position)
            restoreRowBeforeToken(&self)
            charBudgetRelaxed = false
            let accepted = parser.hasCharBudgetRules
                ? advanceAtomicTokenWithCharacterBudget(tokenID, charCount: tokenCharCount)
                : parser.advanceAtomicToken(tokenID)
            assert(accepted)
            tokenLengthHistory.append(1)
            if shouldTrackAcceptedBytes { appendAtomicRow(token) }
        } else if bytePathSuccess, !atomicSuccess {
            tokenLengthHistory.append(token.count)
            if shouldTrackAcceptedBytes { appendPerByteRows(token) }
        } else {
            let atomic = atomicRow.unsafelyUnwrapped
            if token.isEmpty {
                // The byte path created no position; push the atomic result as is.
                parser.pushRow(scanable: atomic.scanable, completable: atomic.completable, captures: atomic.captures, completed: atomic.completed,
                               charCount: parser.currentCharIndex, charBudgetEntered: parser.hasEnteredCharBudget)
                tokenLengthHistory.append(1)
                if shouldTrackAcceptedBytes { appendAtomicRow(token) }
            } else {
                // Merge the atomic states into the byte path's final position.
                let byteRow = parser.snapshotLatestRow()
                let finalCharIndex = parser.currentCharIndex
                let finalCharBudgetEntered = parser.hasEnteredCharBudget
                parser.popLastStates(1)

                var merged = byteRow.scanable
                for state in atomic.scanable where !merged.contains(state) { merged.append(state) }
                var mergedCompletable = byteRow.completable
                for entry in atomic.completable where !mergedCompletable.contains(entry) { mergedCompletable.append(entry) }
                var mergedCaptures = byteRow.captures
                let afterTokenPosition = Int32(parser.historyCount)
                for var event in atomic.captures {
                    // Empty spans that started at the after-token position keep that meaning in
                    // the byte path's numbering.
                    if event.startPos == sizeBeforeToken { event.startPos = afterTokenPosition }
                    if event.occurrenceStartPos == sizeBeforeToken { event.occurrenceStartPos = afterTokenPosition }
                    for index in event.stopCaptureTargets.indices where event.stopCaptureTargets[index].startPos == sizeBeforeToken {
                        event.stopCaptureTargets[index].startPos = afterTokenPosition
                    }
                    if let existing = mergedCaptures.firstIndex(where: { $0.ruleID == event.ruleID && $0.startPos == event.startPos && $0.occurrenceStartPos == event.occurrenceStartPos }) {
                        mergedCaptures[existing].hiddenSuffixBytes = max(mergedCaptures[existing].hiddenSuffixBytes, event.hiddenSuffixBytes)
                        mergedCaptures[existing].hiddenStopBytes = max(mergedCaptures[existing].hiddenStopBytes, event.hiddenStopBytes)
                        for target in event.stopCaptureTargets where !mergedCaptures[existing].stopCaptureTargets.contains(target) {
                            mergedCaptures[existing].stopCaptureTargets.append(target)
                        }
                    } else {
                        mergedCaptures.append(event)
                    }
                }
                parser.pushRow(scanable: merged, completable: mergedCompletable, captures: mergedCaptures, completed: byteRow.completed || atomic.completed,
                               charCount: finalCharIndex, charBudgetEntered: finalCharBudgetEntered)
                tokenLengthHistory.append(token.count)
                if shouldTrackAcceptedBytes { appendPerByteRows(token) }
            }
        }

        if parser.hasCharBudgetRules {
            // Close exhausted occurrences at the token boundary.
            _ = applyCharacterBudgetEnforcementToFixedPoint()
        }
        recordCharBudgetRelaxation = false
        stopTokenAccepted = isStopToken
        return finishAccept(consumedPastDeadline: consumedPastDeadline)
    }

    /// Feeds raw text (e.g. a prompt prefix or a jump-forward string). Rejected input leaves the
    /// state unchanged.
    @discardableResult
    public mutating func acceptString(_ string: String) -> Bool {
        acceptBytes(Array(string.utf8))
    }

    /// Feeds raw bytes. Rejected input leaves the state unchanged.
    @discardableResult
    public mutating func acceptBytes(_ bytes: [UInt8]) -> Bool {
        if stopTokenAccepted { return false }
        parser.currentTokenIndex = Int32(tokenLengthHistory.count)
        charBudgetRelaxed = false
        recordCharBudgetRelaxation = true
        parser.isCaptureRecording = parser.isCaptureTrackingEnabled
        defer { parser.isCaptureRecording = false }

        let rowBeforeInput = parser.hasCharBudgetRules ? parser.snapshotLatestRow() : nil
        let trackTemporaryInput = parser.hasCharBudgetRules && hasBudgetMarkerRules
        if trackTemporaryInput {
            temporaryInputStartRow = parser.historyCount - 1
            temporaryInputBytes.removeAll(keepingCapacity: true)
        }
        var acceptedCount = 0
        for byte in bytes {
            let accepted = parser.hasCharBudgetRules ? advanceWithCharacterBudget(byte) : parser.advance(byte)
            if !accepted {
                parser.popLastStates(acceptedCount)
                if let rowBeforeInput { parser.restoreLatestRow(rowBeforeInput) }
                if trackTemporaryInput {
                    temporaryInputStartRow = -1
                    temporaryInputBytes.removeAll(keepingCapacity: true)
                }
                recordCharBudgetRelaxation = false
                charBudgetRelaxed = false
                return false
            }
            if trackTemporaryInput { temporaryInputBytes.append(byte) }
            acceptedCount += 1
        }
        tokenLengthHistory.append(bytes.count)
        if shouldTrackAcceptedBytes { appendPerByteRows(bytes) }
        if parser.hasCharBudgetRules, !bytes.isEmpty {
            _ = applyCharacterBudgetEnforcementToFixedPoint()
        }
        if trackTemporaryInput {
            temporaryInputStartRow = -1
            temporaryInputBytes.removeAll(keepingCapacity: true)
        }
        recordCharBudgetRelaxation = false
        charBudgetRelaxed = false
        return true
    }

    private mutating func acceptStopToken() -> Bool {
        if terminatesWithoutStopToken { return false }
        if !parser.isCompleted { return false }
        tokenLengthHistory.append(0)
        stopTokenAccepted = true
        return true
    }

    /// Whether consuming stop token `tokenID` as grammar text (its bytes, or whole through a token
    /// edge) completes the grammar. The parser state is left unchanged.
    private mutating func canAcceptStopTokenAsTerminal(_ tokenID: Int32) -> Bool {
        guard Int(tokenID) < tokenizerInfo.decodedVocab.count else { return false }
        let token = tokenizerInfo.decodedVocab[Int(tokenID)]
        // Without token-level edges a stop token is consumed only byte by byte, never with a
        // byte the grammar has nowhere (`<|im_end|>` in a date): skip the parser rounds.
        if !parser.hasTokenEdges, token.isEmpty || !token.allSatisfy(parser.byteAlphabet.contains) { return false }
        let atomicSuccess = parser.hasTokenEdges && parser.advanceAtomicToken(tokenID)
        if atomicSuccess {
            let accepted = parser.isCompleted
            parser.popLastStates(1)
            if accepted { return true }
        }
        var advanced = 0
        for byte in token {
            guard parser.advance(byte) else { break }
            advanced += 1
        }
        if !atomicSuccess, !parser.hasCharBudgetRules, advanced < token.count {
            let midTokenRow = parser.findMidTokenExcludeEdgeRow(rows: advanced, tokenID: tokenID)
            if midTokenRow > 0 {
                parser.popLastStates(advanced - midTokenRow)
                let advancedAtomic = parser.advanceAtomicToken(tokenID)
                let accepted = advancedAtomic && parser.isCompleted
                parser.popLastStates(midTokenRow + (advancedAtomic ? 1 : 0))
                return accepted
            }
        }
        let accepted = advanced > 0 && advanced == token.count && parser.isCompleted
        parser.popLastStates(advanced)
        return accepted
    }

    private mutating func finishAccept(consumedPastDeadline: Bool) -> Bool {
        budgetEnforcePending = false
        budgetForceClosePending = false
        charBudgetRelaxed = false
        return true
    }

    private mutating func appendPerByteRows(_ bytes: some Collection<UInt8>) {
        for byte in bytes {
            acceptedBytes.append(byte)
            rowByteEnd.append(acceptedBytes.count)
        }
    }

    private mutating func appendAtomicRow(_ bytes: some Collection<UInt8>) {
        acceptedBytes.append(contentsOf: bytes)
        rowByteEnd.append(acceptedBytes.count)
    }

    // MARK: Rollback

    /// Undoes the last `count` accepted tokens (or strings).
    public mutating func rollback(_ count: Int = 1) {
        precondition(count <= tokenLengthHistory.count, "Intended to rollback \(count) tokens, but only the last \(tokenLengthHistory.count) steps of history are saved")
        var remaining = count
        while remaining > 0 {
            let steps = tokenLengthHistory.removeLast()
            stopTokenAccepted = false
            if steps > 0 { parser.popLastStates(steps) }
            if shouldTrackAcceptedBytes, steps > 0 {
                rowByteEnd.removeLast(steps)
                acceptedBytes.removeLast(acceptedBytes.count - rowByteEnd[rowByteEnd.count - 1])
            }
            remaining -= 1
        }
        budgetEnforcePending = false
        budgetForceClosePending = false
        charBudgetRelaxed = false
        recordCharBudgetRelaxation = false
        temporaryInputStartRow = -1
        temporaryInputBytes.removeAll(keepingCapacity: true)
        budgetBodyMatchCache.removeAll()
    }

    // MARK: Jump forward

    /// The longest string the grammar forces next (every live state agrees on each byte), cut to
    /// whole UTF-8 characters: forced bytes that end inside a character, or that continue a
    /// character begun by an earlier token, are left out (any prefix of the forced bytes is itself
    /// forced). ``findJumpForwardBytes()`` returns every forced byte.
    public mutating func findJumpForwardString() -> String {
        let bytes = findJumpForwardBytes()
        return String(decoding: bytes[..<Self.validUTF8PrefixLength(bytes)], as: UTF8.self)
    }

    /// Length of the longest prefix made of complete, valid UTF-8 characters, as a strict decoder
    /// accepts them: no truncated or overlong sequences, surrogates, or code points above U+10FFFF.
    static func validUTF8PrefixLength(_ bytes: [UInt8]) -> Int {
        var position = 0
        while position < bytes.count {
            let first = bytes[position]
            let length: Int
            // The second byte's range excludes overlong forms, surrogates and code points above
            // U+10FFFF; later continuation bytes are always in 0x80...0xBF.
            var secondRange: ClosedRange<UInt8> = 0x80 ... 0xBF
            switch first {
            case 0x00 ..< 0x80: length = 1
            case 0xC2 ... 0xDF: length = 2
            case 0xE0 ... 0xEF:
                length = 3
                if first == 0xE0 { secondRange = 0xA0 ... 0xBF }
                if first == 0xED { secondRange = 0x80 ... 0x9F }
            case 0xF0 ... 0xF4:
                length = 4
                if first == 0xF0 { secondRange = 0x90 ... 0xBF }
                if first == 0xF4 { secondRange = 0x80 ... 0x8F }
            default: return position
            }
            guard position + length <= bytes.count else { return position }
            for offset in 1 ..< length {
                let range: ClosedRange<UInt8> = offset == 1 ? secondRange : 0x80 ... 0xBF
                if !range.contains(bytes[position + offset]) { return position }
            }
            position += length
        }
        return position
    }

    /// Every byte the grammar forces next; ``findJumpForwardString()`` cuts it to whole characters.
    public mutating func findJumpForwardBytes() -> [UInt8] {
        precondition(!stopTokenAccepted, "GrammarMatcher has terminated after accepting the stop token, but is trying to get the jump forward string")
        parser.currentTokenIndex = Int32(tokenLengthHistory.count)
        if budgetForceClosePending {
            var trial = self
            trial.parser.isCaptureRecording = false
            if trial.applyBudgetEnforcement() {
                trial.budgetEnforcePending = false
                trial.budgetForceClosePending = false
                return trial.findJumpForwardBytes()
            }
        }
        var result: [UInt8] = []
        var acceptedCount = 0
        while !parser.isCompleted {
            var nextByte: Int32 = -1
            var unique = true
            for state in parser.latestScanableStates {
                if budgetEnforcePending, parser.isExpiredState(state) { continue }
                let fsm = grammar.perRuleFSMs[Int(state.ruleID)].unsafelyUnwrapped.fsm
                for edge in fsm.fsm.edges(of: state.elementID) {
                    // Token-level alternatives are not forced byte continuations.
                    if edge.isToken || edge.isExcludeToken {
                        unique = false
                        break
                    }
                    guard edge.isCharRange else { continue }
                    if edge.min != edge.max {
                        unique = false
                        break
                    }
                    if nextByte == -1 {
                        nextByte = edge.min
                    } else if nextByte != edge.min {
                        unique = false
                        break
                    }
                }
                if !unique { break }
            }
            if !unique || nextByte == -1 { break }
            let byte = UInt8(nextByte)
            if Self.startsCodepoint(byte), parser.latestScanableStates.contains(where: { parser.isCharExpiredState($0) }) { break }
            result.append(byte)
            parser.advance(byte)
            acceptedCount += 1
        }
        parser.popLastStates(acceptedCount)
        return result
    }

    /// Token ids to append for jump-forward decoding; the matcher itself is left unchanged.
    ///
    /// Greedily matches the longest vocabulary tokens over the forced continuation
    /// (``findJumpForwardBytes()``) and withholds the last one when it is a strict prefix of a
    /// longer ordinary token, so already accepted token boundaries are kept. Stop and special
    /// tokens are never proposed. Accept each returned token with ``acceptToken(_:)`` and
    /// prefill them before sampling again. The tokenization may differ from the model
    /// tokenizer's own encoding.
    /// - Returns: The tokens, or an empty array when no jump is available or matching has ended.
    public func findJumpForwardTokens() -> [Int32] {
        if isTerminated || isCompleted { return [] }
        // All lookahead and token validation happens on a copy, so token history, captures and
        // pending budget enforcement of this matcher stay untouched.
        var trial = self
        let forced = trial.findJumpForwardBytes()
        let info = tokenizerInfo
        let ids = info.sortedTokenIDs
        let stops = stopTokenIDs
        var tokens: [Int32] = []
        var lastIsPrefix = false
        var offset = 0
        info.sortedTokens.withUnsafeStorage { bytes, offsets in
            @inline(__always) func byte(_ index: Int, _ depth: Int) -> UInt8 { bytes[Int(offsets[index]) + depth] }
            @inline(__always) func length(_ index: Int) -> Int { Int(offsets[index + 1] - offsets[index]) }
            while offset < forced.count {
                var begin = 0, end = offsets.count - 1
                var tokenID: Int32 = -1, tokenLength = 0, isPrefix = false
                // Narrow the sorted vocabulary one byte at a time, remembering the longest
                // complete token. Removing exact matches leaves only strictly longer extensions.
                var depth = 0
                while offset + depth < forced.count, begin < end {
                    let value = forced[offset + depth]
                    var low = begin, high = end
                    while low < high {
                        let mid = (low + high) / 2
                        if byte(mid, depth) < value { low = mid + 1 } else { high = mid }
                    }
                    begin = low
                    high = end
                    while low < high {
                        let mid = (low + high) / 2
                        if value < byte(mid, depth) { high = mid } else { low = mid + 1 }
                    }
                    end = low
                    var exactID: Int32 = -1
                    while begin < end, length(begin) == depth + 1 {
                        let id = ids[begin]
                        if !stops.contains(id), exactID == -1 || id < exactID { exactID = id }
                        begin += 1
                    }
                    if exactID != -1 {
                        tokenID = exactID
                        tokenLength = depth + 1
                        isPrefix = ids[begin ..< end].contains { !stops.contains($0) }
                    }
                    depth += 1
                }
                if tokenID == -1 || !trial.acceptToken(tokenID) { break }
                tokens.append(tokenID)
                lastIsPrefix = isPrefix
                offset += tokenLength
            }
        }
        // Withhold at most one newly proposed token; accepted tokens are never retokenized.
        if !tokens.isEmpty, lastIsPrefix { tokens.removeLast() }
        return tokens
    }

    // MARK: Token budgets

    /// Whether the bytes consumed by this expired suffix/stop occurrence form a complete match
    /// of its body, so the budget may end it without consuming the marker.
    private mutating func canForceCompleteWithoutMarker(_ state: ParserState, useCharBudget: Bool) -> Bool {
        let expired = useCharBudget ? parser.isCharExpiredState(state) : parser.isExpiredState(state)
        if !expired || state.ruleID < 0 { return false }
        let rule = grammar.rule(state.ruleID)
        if useCharBudget ? rule.maxChars < 0 : rule.maxTokens < 0 { return false }
        guard let info = grammar.suffixStopInfo(for: state.ruleID), info.bodyRuleID >= 0 else { return false }
        assert(shouldTrackAcceptedBytes)
        let startRow = state.ruleStartPos == ParserState.noPreviousInputPosition ? 0 : Int(state.ruleStartPos)
        let begin: Int
        if startRow < rowByteEnd.count {
            begin = rowByteEnd[startRow]
        } else {
            assert(temporaryInputStartRow >= 0 && startRow >= temporaryInputStartRow)
            begin = acceptedBytes.count + startRow - temporaryInputStartRow
        }
        let end = acceptedBytes.count + temporaryInputBytes.count

        let bodyFSM = grammar.perRuleFSMs[Int(info.bodyRuleID)].unsafelyUnwrapped.fsm
        let occurrence = CaptureOccurrence(ruleID: state.ruleID, startPos: state.ruleStartPos)
        var progress: BudgetBodyMatchProgress
        if let existing = budgetBodyMatchCache[occurrence],
           existing.beginByte == begin, existing.endByte <= end,
           !(existing.endByte > acceptedBytes.count && existing.temporaryInputSnapshot != temporaryInputBytes) {
            progress = existing
        } else {
            var states: Set<Int32> = [bodyFSM.start]
            bodyFSM.fsm.expandEpsilonClosure(&states)
            progress = BudgetBodyMatchProgress(beginByte: begin, endByte: begin, states: states, temporaryInputSnapshot: [])
        }
        var offset = progress.endByte
        while offset < end, !progress.states.isEmpty {
            let byte = offset < acceptedBytes.count ? acceptedBytes[offset] : temporaryInputBytes[offset - acceptedBytes.count]
            progress.states = bodyFSM.fsm.advance(from: progress.states, value: Int32(byte), kind: .charRange, fromIsClosure: true)
            offset += 1
        }
        progress.endByte = end
        progress.temporaryInputSnapshot = end > acceptedBytes.count ? temporaryInputBytes : []
        budgetBodyMatchCache[occurrence] = progress
        return progress.states.contains { bodyFSM.isEndState($0) }
    }

    /// Commits the current budget boundary: discards expired states and completes eligible
    /// suffix/stop occurrences without their marker.
    private mutating func applyBudgetEnforcement() -> Bool {
        var forced: [ParserState] = []
        var seen = Set<CaptureOccurrence>()
        for state in Array(parser.latestScanableStates) where parser.isExpiredState(state) {
            guard canForceCompleteWithoutMarker(state, useCharBudget: false) else { continue }
            if seen.insert(CaptureOccurrence(ruleID: state.ruleID, startPos: state.ruleStartPos)).inserted { forced.append(state) }
        }
        let snapshot = parser
        return parser.enforceBudget(isAlive: { !snapshot.isExpiredState($0) }, forceCompleted: forced)
    }

    // MARK: Character budgets

    private mutating func applyCharacterBudgetEnforcement() -> Bool {
        let before = parser.snapshotLatestRow()
        var forced: [ParserState] = []
        var seen = Set<CaptureOccurrence>()
        for state in before.scanable where parser.isCharExpiredState(state) {
            guard canForceCompleteWithoutMarker(state, useCharBudget: true) else { continue }
            if seen.insert(CaptureOccurrence(ruleID: state.ruleID, startPos: state.ruleStartPos)).inserted { forced.append(state) }
        }
        let snapshot = parser
        let viable = parser.enforceBudget(isAlive: { !snapshot.isCharExpiredState($0) }, forceCompleted: forced)
        if !viable {
            // Completion may have grown the completable and capture rows; put them back.
            var restored = before
            restored.scanable = Array(parser.latestScanableStates)
            restored.completed = parser.isCompleted
            parser.restoreLatestRow(restored)
        }
        return viable
    }

    private mutating func applyCharacterBudgetEnforcementToFixedPoint() -> Bool {
        var appliedAny = false
        for _ in 0 ... grammar.ruleCount {
            let hasExpired = parser.latestScanableStates.contains { parser.isCharExpiredState($0) }
            if !hasExpired { return appliedAny }
            if !applyCharacterBudgetEnforcement() { return appliedAny }
            appliedAny = true
        }
        return appliedAny
    }

    private mutating func advanceWithCharacterBudget(_ byte: UInt8) -> Bool {
        if !parser.hasCharBudgetRules || !Self.startsCodepoint(byte) { return parser.advance(byte) }
        let hasExpired = parser.latestScanableStates.contains { parser.isCharExpiredState($0) }
        if !hasExpired { return parser.advance(byte) }
        let previous = parser.snapshotLatestRow()
        let enforced = applyCharacterBudgetEnforcementToFixedPoint()
        if !enforced, recordCharBudgetRelaxation { charBudgetRelaxed = true }
        let accepted = parser.advance(byte)
        if !accepted, enforced { parser.restoreLatestRow(previous) }
        return accepted
    }

    private mutating func advanceAtomicTokenWithCharacterBudget(_ tokenID: Int32, charCount: Int32) -> Bool {
        var hasExpired = false
        var crossesBudget = false
        if parser.hasCharBudgetRules, charCount > 0 {
            let current = parser.currentCharIndex
            for state in parser.latestScanableStates {
                hasExpired = hasExpired || parser.isCharExpiredState(state)
                crossesBudget = crossesBudget || (state.charBudgetDeadline >= 0 && current + charCount > state.charBudgetDeadline)
            }
        }
        var previous: EarleyParser.RowSnapshot? = nil
        var enforced = false
        if hasExpired {
            previous = parser.snapshotLatestRow()
            enforced = applyCharacterBudgetEnforcementToFixedPoint()
            if !enforced, recordCharBudgetRelaxation { charBudgetRelaxed = true }
        }
        let accepted = parser.advanceAtomicToken(tokenID, charCount: charCount)
        if !accepted, enforced, let previous { parser.restoreLatestRow(previous) }
        if accepted, crossesBudget, recordCharBudgetRelaxation { charBudgetRelaxed = true }
        return accepted
    }

    // MARK: Next-token mask

    /// Computes the set of allowed next tokens into `bitmask`. Returns `false` when every token
    /// is allowed (the mask need not be applied).
    @discardableResult
    public mutating func fillNextTokenBitmask(_ bitmask: inout TokenBitmask) -> Bool {
        precondition(!stopTokenAccepted, "GrammarMatcher has terminated after accepting the stop token, but is trying to find the next token mask")
        precondition(bitmask.vocabSize == tokenizerInfo.vocabSize, "The bitmask has \(bitmask.vocabSize) bits; the vocabulary has \(tokenizerInfo.vocabSize)")
        parser.currentTokenIndex = Int32(tokenLengthHistory.count)
        if parser.hasBudgetRules {
            var anyExpired = false
            var anyAlive = false
            var canForceClose = false
            for state in Array(parser.latestScanableStates) {
                if parser.isExpiredState(state) {
                    anyExpired = true
                    canForceClose = canForceClose || (hasBudgetMarkerRules && canForceCompleteWithoutMarker(state, useCharBudget: false))
                } else {
                    anyAlive = true
                }
            }
            if canForceClose {
                // Compute the enforcing state on a copy; commit only once a token is accepted.
                var trial = self
                trial.parser.isCaptureRecording = false
                let applied = trial.applyBudgetEnforcement()
                if applied { trial.fillBitmaskForStates(&bitmask, skipExpired: false) }
                if applied, trial.parser.isCompleted || bitmask.allowsAny {
                    budgetEnforcePending = true
                    budgetForceClosePending = true
                    return !bitmask.allowsAll
                }
            }
            if anyExpired, anyAlive || parser.isCompleted {
                fillBitmaskForStates(&bitmask, skipExpired: true)
                if bitmask.allowsAny || parser.isCompleted {
                    budgetEnforcePending = true
                    budgetForceClosePending = false
                    return !bitmask.allowsAll
                }
            }
            // No enforcement here: relax the budget for one step.
            budgetEnforcePending = false
            budgetForceClosePending = false
        }
        return !fillBitmaskForStates(&bitmask, skipExpired: false)
    }

    /// Convenience: a fresh bitmask of the allowed next tokens.
    public mutating func nextTokenBitmask() -> TokenBitmask {
        var bitmask = TokenBitmask(vocabSize: tokenizerInfo.vocabSize)
        fillNextTokenBitmask(&bitmask)
        return bitmask
    }

    /// The counted-repetition edge of `bodyRuleID` that `state` sits on, if any.
    private func repeatEdgeInfo(of state: ParserState, bodyRuleID: Int32) -> RepeatEdgeInfo? {
        guard state.ruleID >= 0, let ruleFSM = grammar.perRuleFSMs[Int(state.ruleID)] else { return nil }
        for edge in ruleFSM.fsm.fsm.edges(of: state.elementID) where edge.isRepeatRef {
            let info = ruleFSM.fsm.fsm.repeatInfo(at: edge.auxIndex)
            if info.ruleID == bodyRuleID { return info }
        }
        return nil
    }

    /// Returns whether every token is allowed.
    @discardableResult
    private mutating func fillBitmaskForStates(_ bitmask: inout TokenBitmask, skipExpired: Bool) -> Bool {
        // Uncertain tokens are replayed the way a budget-enforcing accept scans them.
        parser.skipExpiredStates = skipExpired
        defer { parser.skipExpiredStates = false }
        let sortedIDs = tokenizerInfo.sortedTokenIDs
        let table = compiledGrammar.maskTable

        scratchStates.removeAll(keepingCapacity: true)
        for state in parser.latestScanableStates where !(skipExpired && parser.isExpiredState(state)) { scratchStates.append(state) }

        // Accepted = union over states; rejected = intersection over states ({-1} = universe).
        if scratchAcceptedDirty {
            scratchAccepted.clearAll()
            scratchAcceptedDirty = false
        }
        scratchRejected.removeAll(keepingCapacity: true)
        scratchRejected.append(-1)

        scratchStateSlots.removeAll(keepingCapacity: true)
        for state in scratchStates {
            guard let slot = table.slot(for: state) else {
                preconditionFailure("No token mask for \(state.description)")
            }
            let mask = table.mask(at: slot)
            if state.charBudgetDeadline >= 0 {
                let remaining = state.charBudgetDeadline - parser.currentCharIndex
                if remaining <= tokenizerInfo.maxTokenChars {
                    fillBitmaskForCharBudgetBoundary(mask.pointee, remainingChars: max(remaining, 0))
                    continue
                }
            }
            scratchStateSlots.append((state, slot))
            if mask.pointee.storeType != .rejected || mask.pointee.hasRepeatInterior {
                scratchAcceptedDirty = true
            }
            switch mask.pointee.storeType {
            case .acceptedBitset: scratchAccepted.formUnion(mask.pointee.acceptedBitset)
            case .accepted: for index in mask.pointee.acceptedIndices { scratchAccepted[sortedIDs[Int(index)]] = true }
            case .rejected: break
            }
            // Counted-repetition body: decide the budget-bound tokens from the parent's count.
            if mask.pointee.hasRepeatInterior {
                precondition(!parser.hasCharBudgetRules && state.ruleStartPos != ParserState.noPreviousInputPosition, "The counted-repetition fast path does not apply to this state")
                var remaining: Int32 = -1
                var onRepeat = false
                for entry in parser.completableStates[Int(state.ruleStartPos)] where entry.ruleID == state.ruleID {
                    guard let info = repeatEdgeInfo(of: entry.state, bodyRuleID: state.ruleID) else { continue }
                    onRepeat = true
                    if skipExpired, parser.isExpiredState(entry.state) { continue }
                    let budget = info.upper - entry.state.repeatCount
                    remaining = max(remaining, budget)
                    for exit in mask.pointee.repeatExitTokens where exit.repetitions <= budget && entry.state.repeatCount + exit.repetitions >= info.lower {
                        scratchAccepted[exit.tokenID] = true
                    }
                }
                precondition(onRepeat, "A counted-repetition body state has no repetition parent")
                let counts = mask.pointee.repeatInteriorCharCounts
                var upper = 0
                while upper < counts.count, counts[upper] <= remaining { upper += 1 }
                if upper > 0 { scratchAccepted.formUnion(mask.pointee.repeatInteriorBitsets[upper - 1]) }
                // Tokens between the last checkpoint and the budget (sorted by count).
                let covered = upper > 0 ? counts[upper - 1] : 0
                for listed in mask.pointee.repeatInteriorTokens {
                    if listed.repetitions > remaining { break }
                    if listed.repetitions > covered { scratchAccepted[listed.tokenID] = true }
                }
            }
        }

        for (state, slot) in scratchStateSlots {
            let mask = table.mask(at: slot)
            // Nothing to replay: the mask is decided as compiled.
            if mask.pointee.uncertainIndices.isEmpty {
                if mask.pointee.storeType == .rejected { SortedIntSet.formIntersection(&scratchRejected, mask.pointee.rejectedIndices) }
                continue
            }
            let sorted = tokenizerInfo.sortedTokens
            let subtreeEnds = tokenizerInfo.trieSubtreeEnds
            scratchRejectedDelta.removeAll(keepingCapacity: true)
            parser.pushOneStateToCheck(state)
            let trackTemporaryInput = parser.hasCharBudgetRules && hasBudgetMarkerRules
            var savedTemporaryStartRow = -1
            var savedTemporaryBytes: [UInt8] = []
            if trackTemporaryInput {
                savedTemporaryStartRow = temporaryInputStartRow
                savedTemporaryBytes = temporaryInputBytes
                temporaryInputStartRow = parser.historyCount - 1
                temporaryInputBytes.removeAll(keepingCapacity: true)
            }

            var previousIndex = -1
            var previousMatchedSize = 0
            var lastRejectedRange: Int32 = 0
            // Walk the uncertain runs; `next` is the following index, in run `run`.
            let uncertain = mask.pointee.uncertainIndices
            let runCount = uncertain.runCount
            var run = 0
            var next = uncertain.start(ofRun: 0), runEnd = uncertain.end(ofRun: 0)
            while true {
                if next == runEnd {
                    run += 1
                    if run == runCount { break }
                    next = uncertain.start(ofRun: run)
                    runEnd = uncertain.end(ofRun: run)
                }
                let index = next
                next += 1
                if scratchAccepted[sortedIDs[Int(index)]] { continue }
                if index < lastRejectedRange {
                    if mask.pointee.storeType == .rejected {
                        scratchRejectedDelta.append(index)
                    } else {
                        // Skip the rest of the rejected subtree.
                        while runEnd <= lastRejectedRange, run + 1 < runCount {
                            run += 1
                            next = uncertain.start(ofRun: run)
                            runEnd = uncertain.end(ofRun: run)
                        }
                        next = min(max(next, lastRejectedRange), runEnd)
                    }
                    continue
                }
                let token = sorted[Int(index)]
                var accepted = !token.isEmpty || !parser.hasCharBudgetRules
                if previousIndex >= 0 {
                    let lcp = sorted.commonPrefixLength(Int(index), previousIndex)
                    if lcp > previousMatchedSize {
                        lastRejectedRange = subtreeEnds[Int(index)]
                        accepted = false
                    } else if lcp < previousMatchedSize {
                        parser.popLastStates(previousMatchedSize - lcp)
                        if trackTemporaryInput { temporaryInputBytes.removeLast(temporaryInputBytes.count - lcp) }
                    }
                    previousMatchedSize = min(previousMatchedSize, lcp)
                }
                if accepted {
                    var position = token.startIndex + previousMatchedSize
                    while position < token.endIndex {
                        let byte = token[position]
                        let byteAccepted = parser.hasCharBudgetRules ? advanceWithCharacterBudget(byte) : parser.advance(byte)
                        if !byteAccepted {
                            lastRejectedRange = subtreeEnds[Int(index)]
                            accepted = false
                            break
                        }
                        if trackTemporaryInput { temporaryInputBytes.append(byte) }
                        previousMatchedSize = position - token.startIndex + 1
                        position += 1
                    }
                }

                // The first bytes may finish a literal before a token-level free-text region,
                // which takes the whole token from there. The longer tokens under this one may be
                // taken even when this one is excluded, so they are checked one by one instead of
                // being skipped with it.
                if !accepted, !parser.hasCharBudgetRules, parser.findMidTokenExcludeEdgeRow(rows: previousMatchedSize, tokenID: -1) > 0 {
                    accepted = parser.findMidTokenExcludeEdgeRow(rows: previousMatchedSize, tokenID: sortedIDs[Int(index)]) > 0
                    lastRejectedRange = index + 1
                }

                var retriedAtomically = false
                if !accepted, parser.hasCharBudgetRules, parser.hasTokenEdges {
                    // Retry through token edges in place, then rebuild the single-state row.
                    retriedAtomically = true
                    parser.popLastStates(previousMatchedSize + 1)
                    if trackTemporaryInput { temporaryInputBytes.removeAll(keepingCapacity: true) }
                    parser.pushOneStateToCheck(state)
                    let savedRecording = parser.isCaptureRecording
                    let savedRelaxation = recordCharBudgetRelaxation
                    parser.isCaptureRecording = false
                    recordCharBudgetRelaxation = false
                    accepted = advanceAtomicTokenWithCharacterBudget(sortedIDs[Int(index)], charCount: tokenizerInfo.sortedTokenCharCount(Int(index)))
                    parser.isCaptureRecording = savedRecording
                    recordCharBudgetRelaxation = savedRelaxation
                    parser.popLastStates(accepted ? 2 : 1)
                    parser.pushOneStateToCheck(state)
                    previousMatchedSize = 0
                    if accepted { lastRejectedRange = index + 1 }
                }

                if mask.pointee.storeType == .rejected {
                    if !accepted { scratchRejectedDelta.append(index) }
                } else if accepted {
                    scratchAccepted[sortedIDs[Int(index)]] = true
                    scratchAcceptedDirty = true
                }
                previousIndex = retriedAtomically ? -1 : Int(index)
            }

            parser.popLastStates(previousMatchedSize + 1)
            if trackTemporaryInput {
                temporaryInputStartRow = savedTemporaryStartRow
                temporaryInputBytes = savedTemporaryBytes
            }
            if mask.pointee.storeType == .rejected {
                SortedIntSet.formUnion(&scratchRejectedDelta, mask.pointee.rejectedIndices)
                SortedIntSet.formIntersection(&scratchRejected, scratchRejectedDelta)
            }
        }

        return setTokenBitmask(&bitmask, rejected: scratchRejected, canReachEnd: parser.isCompleted)
    }

    /// Near a character budget boundary every token is checked against the remaining budget.
    private mutating func fillBitmaskForCharBudgetBoundary(_ mask: AdaptiveTokenMask, remainingChars: Int32) {
        scratchAcceptedDirty = true

        let sorted = tokenizerInfo.sortedTokens
        let sortedIDs = tokenizerInfo.sortedTokenIDs
        var toCheck = mask.uncertainIndices.array
        switch mask.storeType {
        case .accepted:
            for index in mask.acceptedIndices {
                if tokenizerInfo.sortedTokenCharCount(Int(index)) <= remainingChars { scratchAccepted[sortedIDs[Int(index)]] = true } else { toCheck.append(index) }
            }
        case .acceptedBitset:
            for index in 0 ..< Int32(sorted.count) where mask.acceptedBitset[sortedIDs[Int(index)]] {
                if tokenizerInfo.sortedTokenCharCount(Int(index)) <= remainingChars { scratchAccepted[sortedIDs[Int(index)]] = true } else { toCheck.append(index) }
            }
        case .rejected:
            var blocked = mask.rejectedIndices
            SortedIntSet.formUnion(&blocked, mask.uncertainIndices.array)
            for index in 0 ..< Int32(sorted.count) {
                if tokenizerInfo.sortedTokenCharCount(Int(index)) <= remainingChars {
                    if !blocked.binarySearchContains(index) { scratchAccepted[sortedIDs[Int(index)]] = true }
                } else if !mask.rejectedIndices.binarySearchContains(index) {
                    toCheck.append(index)
                }
            }
        }
        SortedIntSet.normalize(&toCheck)

        let savedTemporaryStartRow = temporaryInputStartRow
        let savedTemporaryBytes = temporaryInputBytes
        let allLatest = Array(parser.latestScanableStates)
        let allCompleted = parser.isCompleted
        parser.pushStatesToCheck(allLatest, completed: allCompleted)
        let initialHistorySize = parser.historyCount
        temporaryInputStartRow = initialHistorySize - 1
        temporaryInputBytes.removeAll(keepingCapacity: true)
        var previousIndex = -1
        var previousMatchedSize = 0
        var byteRejected: [Int32] = []

        for index in toCheck {
            let token = sorted[Int(index)]
            var commonPrefix = 0
            if previousIndex >= 0 {
                commonPrefix = min(sorted.commonPrefixLength(previousIndex, Int(index)), previousMatchedSize)
            }
            parser.popLastStates(parser.historyCount - initialHistorySize - commonPrefix)
            temporaryInputBytes.removeLast(temporaryInputBytes.count - commonPrefix)
            var accepted = !token.isEmpty
            var matched = commonPrefix
            while matched < token.count {
                let byte = token[token.startIndex + matched]
                if !advanceWithCharacterBudget(byte) {
                    accepted = false
                    break
                }
                temporaryInputBytes.append(byte)
                matched += 1
            }
            if accepted { scratchAccepted[sortedIDs[Int(index)]] = true } else { byteRejected.append(index) }
            previousIndex = Int(index)
            previousMatchedSize = matched
        }
        parser.popLastStates(parser.historyCount - initialHistorySize + 1)

        for index in byteRejected {
            parser.pushStatesToCheck(allLatest, completed: allCompleted)
            temporaryInputStartRow = parser.historyCount - 1
            temporaryInputBytes.removeAll(keepingCapacity: true)
            if advanceAtomicTokenWithCharacterBudget(sortedIDs[Int(index)], charCount: tokenizerInfo.sortedTokenCharCount(Int(index))) {
                scratchAccepted[sortedIDs[Int(index)]] = true
                parser.popLastStates(1)
            }
            parser.popLastStates(1)
        }
        temporaryInputStartRow = savedTemporaryStartRow
        temporaryInputBytes = savedTemporaryBytes
    }

    /// `bitmask = accepted` when `rejected` is the universe, else `all − (rejected − accepted)`
    /// minus the special tokens; stop tokens follow `canReachEnd`. Returns whether every token
    /// is allowed, known here without scanning the mask in the common case.
    private mutating func setTokenBitmask(_ bitmask: inout TokenBitmask, rejected: [Int32], canReachEnd: Bool) -> Bool {
        if rejected.count == 1, rejected[0] == -1 {
            // The accepted set is the answer: hand its storage over instead of copying it. The
            // scratch mask now holds the caller's previous bits.
            swap(&bitmask, &scratchAccepted)
            scratchAcceptedDirty = true
            applyStopTokenPolicy(&bitmask, canReachEnd: canReachEnd)
            return bitmask.allowsAll
        }
        let sortedIDs = tokenizerInfo.sortedTokenIDs
        bitmask.setAll()
        var allowsAll = tokenizerInfo.specialTokenIDs.isEmpty
        for index in rejected {
            let id = sortedIDs[Int(index)]
            if !scratchAccepted[id] { bitmask[id] = false; allowsAll = false }
        }
        for id in tokenizerInfo.specialTokenIDs { bitmask[id] = false }
        if !applyStopTokenPolicy(&bitmask, canReachEnd: canReachEnd) { allowsAll = false }
        return allowsAll
    }

    /// Stop tokens may appear in the compiler's accepted set (overridden stop tokens), so their
    /// bits are decided here for either mask representation: a stop signal is allowed once the
    /// grammar can end (unless completion itself terminates), and a stop token's own text when
    /// consuming it completes the grammar. Returns whether every stop token is allowed.
    @discardableResult
    private mutating func applyStopTokenPolicy(_ bitmask: inout TokenBitmask, canReachEnd: Bool) -> Bool {
        let allowedAsSignal = !terminatesWithoutStopToken && canReachEnd
        var allAllowed = true
        for id in stopTokenIDs {
            let allowed = allowedAsSignal || canAcceptStopTokenAsTerminal(id)
            bitmask[id] = allowed
            allAllowed = allAllowed && allowed
        }
        return allAllowed
    }
}
