// ARC-free view of an optimized grammar for the parser's hot loops. The complete automaton, the
// expression arena and the per-rule attributes are copied once into raw buffers owned by this
// object; the parser keeps one strong reference and reads through plain pointers, so advancing a
// byte performs no reference counting (which would otherwise be contended across cores when
// masks are computed in parallel).

final class ParserTables: @unchecked Sendable {
    struct StateFlags: OptionSet {
        let rawValue: UInt8
        static let scanable = StateFlags(rawValue: 1 << 0)
        static let nonTerminal = StateFlags(rawValue: 1 << 1)
        static let end = StateFlags(rawValue: 1 << 2)
        static let hasEdges = StateFlags(rawValue: 1 << 3)
        static let hasExcludeToken = StateFlags(rawValue: 1 << 4)
    }

    struct RuleFlags: OptionSet {
        let rawValue: UInt8
        static let isLazy = RuleFlags(rawValue: 1 << 0)
        static let hasTemperature = RuleFlags(rawValue: 1 << 1)
        static let needsCaptureEvent = RuleFlags(rawValue: 1 << 2)
        static let isNullable = RuleFlags(rawValue: 1 << 3)
        static let isTagDispatch = RuleFlags(rawValue: 1 << 4)
    }

    // Complete automaton (CSR).
    private let edgeOffsets: UnsafeMutableBufferPointer<Int32>
    private let edges: UnsafeMutableBufferPointer<FSMEdge>
    private let aux: UnsafeMutableBufferPointer<Int32>
    /// Per complete-FSM state: scanable / non-terminal / end / has-edges, relative to the one
    /// rule whose fragment the state belongs to.
    private let stateFlags: UnsafeMutableBufferPointer<UInt8>

    // Expression arena.
    private let exprData: UnsafeMutableBufferPointer<Int32>
    private let exprOffsets: UnsafeMutableBufferPointer<Int32>

    // Per rule.
    private let ruleStart: UnsafeMutableBufferPointer<Int32>
    private let ruleBodyExprID: UnsafeMutableBufferPointer<Int32>
    private let ruleMaxTokens: UnsafeMutableBufferPointer<Int32>
    private let ruleMaxChars: UnsafeMutableBufferPointer<Int32>
    private let ruleFlagBits: UnsafeMutableBufferPointer<UInt8>

    let ruleCount: Int
    let stateCount: Int
    let rootRuleID: Int32
    let hasBudgetRules: Bool
    let hasCharBudgetRules: Bool
    /// Whether the automaton has token or exclude-token edges (upstream's `has_token_edges`).
    let hasTokenEdges: Bool
    /// A superset of the bytes any scan can consume (automaton byte edges and byte-level
    /// expressions); a byte outside it is rejected in every state.
    let byteAlphabet: ByteSet
    let isCaptureTrackingEnabled: Bool
    let hasHiddenCaptureRules: Bool

    var memorySize: Int {
        (edgeOffsets.count + aux.count + exprData.count + exprOffsets.count + ruleStart.count
            + ruleBodyExprID.count + ruleMaxTokens.count + ruleMaxChars.count) * 4
            + edges.count * MemoryLayout<FSMEdge>.stride + stateFlags.count + ruleFlagBits.count
    }

    init(_ storage: GrammarStorage) {
        precondition(storage.isOptimized, "The grammar is not optimized. Please optimize the grammar before using the Earley parser.")
        let complete = storage.completeFSM ?? CompactFSM()
        edgeOffsets = Self.copy(complete.offsets)
        edges = Self.copy(complete.edges)
        aux = Self.copy(complete.auxData)
        exprData = Self.copy(storage.exprData)
        exprOffsets = Self.copy(storage.exprOffsets)
        ruleCount = storage.ruleCount
        stateCount = complete.stateCount
        rootRuleID = storage.rootRuleID
        hasTokenEdges = complete.edges.contains { $0.isToken || $0.isExcludeToken }
        var alphabet = ByteSet()
        for edge in complete.edges where edge.min >= 0 && edge.min <= edge.max { alphabet.insert(range: edge.min ... edge.max) }
        for id in 0 ..< Int32(storage.exprCount) {
            let expr = storage.expr(id)
            switch expr.kind {
            case .byteString:
                for value in expr.data { alphabet.insert(UInt8(truncatingIfNeeded: value)) }
            case .characterClass, .characterClassStar:
                // Code point ranges: ASCII bytes exactly, any non-ASCII code point as every
                // multi-byte lead and continuation byte; a negated class as every byte.
                guard expr.data.first == 0 else { alphabet.insert(range: 0 ... 255); break }
                var index = expr.data.startIndex + 1
                while index + 1 < expr.data.endIndex {
                    let low = expr.data[index], high = expr.data[index + 1]
                    if low <= 0x7F, low <= high { alphabet.insert(range: low ... min(high, 0x7F)) }
                    if high >= 0x80 { alphabet.insert(range: 0x80 ... 0xFF) }
                    index += 2
                }
            default: break
            }
        }
        byteAlphabet = alphabet

        ruleStart = .allocate(capacity: ruleCount)
        ruleBodyExprID = .allocate(capacity: ruleCount)
        ruleMaxTokens = .allocate(capacity: ruleCount)
        ruleMaxChars = .allocate(capacity: ruleCount)
        ruleFlagBits = .allocate(capacity: ruleCount)
        stateFlags = .allocate(capacity: stateCount)
        stateFlags.initialize(repeating: 0)

        var hasBudget = false, hasCharBudget = false, captureTracking = false, hiddenCapture = false
        var walker = ReachableStateWalker(complete)
        for (index, rule) in storage.rules.enumerated() {
            let ruleID = Int32(index)
            let fsm = storage.perRuleFSMs[index].unsafelyUnwrapped.fsm
            ruleStart[index] = fsm.start
            ruleBodyExprID[index] = rule.bodyExprID
            ruleMaxTokens[index] = rule.maxTokens
            ruleMaxChars[index] = rule.maxChars
            let info = storage.suffixStopInfo(for: ruleID)
            let hasHidden = info.map { $0.hiddenSuffixBytes > 0 || $0.hiddenStopBytes > 0 } ?? false
            var flags: RuleFlags = []
            if rule.isLazy { flags.insert(.isLazy) }
            if rule.temperature != nil { flags.insert(.hasTemperature) }
            if storage.allowsEmpty(ruleID) { flags.insert(.isNullable) }
            if storage.kind(of: rule.bodyExprID) == .tagDispatch { flags.insert(.isTagDispatch) }
            hasBudget = hasBudget || rule.maxTokens >= 0
            hasCharBudget = hasCharBudget || rule.maxChars >= 0
            captureTracking = captureTracking || !rule.captureName.isEmpty || (info.map { !$0.stopCaptureName.isEmpty } ?? false)
            hiddenCapture = hiddenCapture || hasHidden
            ruleFlagBits[index] = flags.rawValue

            // Flags of every state of this rule's fragment (reachable from its start).
            walker.walk(from: fsm.start)
            for state in walker.states {
                var stateFlag: StateFlags = []
                if fsm.isEndState(state) { stateFlag.insert(.end) }
                let row = complete.edges(of: state)
                if !row.isEmpty { stateFlag.insert(.hasEdges) }
                for edge in row {
                    if edge.isCharRange || edge.isToken || edge.isExcludeToken {
                        stateFlag.insert(.scanable)
                        if edge.isExcludeToken { stateFlag.insert(.hasExcludeToken) }
                    } else if edge.isRuleRef || edge.isEpsilon || edge.isRepeatRef {
                        stateFlag.insert(.nonTerminal)
                    }
                }
                stateFlags[Int(state)] = stateFlag.rawValue
            }
        }
        // Capture events are only needed by rules that are captured or hide bytes; resolve
        // after the tracking flag is known so the test is a single bit at runtime.
        for (index, rule) in storage.rules.enumerated() where captureTracking {
            let info = storage.suffixStopInfo(for: Int32(index))
            let hasHidden = hiddenCapture && (info.map { $0.hiddenSuffixBytes > 0 || $0.hiddenStopBytes > 0 } ?? false)
            if !rule.captureName.isEmpty || hasHidden {
                ruleFlagBits[index] |= RuleFlags.needsCaptureEvent.rawValue
            }
        }
        hasBudgetRules = hasBudget
        hasCharBudgetRules = hasCharBudget
        isCaptureTrackingEnabled = captureTracking
        hasHiddenCaptureRules = hiddenCapture
    }

    deinit {
        edgeOffsets.deallocate()
        edges.deallocate()
        aux.deallocate()
        stateFlags.deallocate()
        exprData.deallocate()
        exprOffsets.deallocate()
        ruleStart.deallocate()
        ruleBodyExprID.deallocate()
        ruleMaxTokens.deallocate()
        ruleMaxChars.deallocate()
        ruleFlagBits.deallocate()
    }

    private static func copy<T>(_ array: [T]) -> UnsafeMutableBufferPointer<T> {
        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: array.count)
        _ = buffer.initialize(from: array)
        return buffer
    }

    // MARK: Automaton

    @inline(__always)
    func edges(of state: Int32) -> UnsafeBufferPointer<FSMEdge> {
        let start = Int(edgeOffsets[Int(state)]), end = Int(edgeOffsets[Int(state) &+ 1])
        return UnsafeBufferPointer(rebasing: UnsafeBufferPointer(edges)[start ..< end])
    }

    @inline(__always)
    func flags(of state: Int32) -> StateFlags { StateFlags(rawValue: stateFlags[Int(state)]) }

    @inline(__always)
    func repeatInfo(at auxIndex: Int32) -> RepeatEdgeInfo {
        let base = Int(auxIndex)
        return RepeatEdgeInfo(ruleID: aux[base], lower: aux[base &+ 1], upper: aux[base &+ 2])
    }

    /// Whether the token set at `auxIndex` contains `tokenID`.
    @inline(__always)
    func tokenSet(at auxIndex: Int32, contains tokenID: Int32) -> Bool {
        let base = Int(auxIndex)
        let count = Int(aux[base])
        var index = base &+ 1
        let end = index &+ count
        while index < end {
            if aux[index] == tokenID { return true }
            index &+= 1
        }
        return false
    }

    // MARK: Rules

    @inline(__always) func start(of ruleID: Int32) -> Int32 { ruleStart[Int(ruleID)] }
    @inline(__always) func bodyExprID(of ruleID: Int32) -> Int32 { ruleBodyExprID[Int(ruleID)] }
    @inline(__always) func maxTokens(of ruleID: Int32) -> Int32 { ruleMaxTokens[Int(ruleID)] }
    @inline(__always) func maxChars(of ruleID: Int32) -> Int32 { ruleMaxChars[Int(ruleID)] }
    @inline(__always) func ruleFlags(of ruleID: Int32) -> RuleFlags { RuleFlags(rawValue: ruleFlagBits[Int(ruleID)]) }

    // MARK: Expressions

    @inline(__always)
    func exprKind(_ id: Int32) -> GrammarExprKind {
        GrammarExprKind(rawValue: exprData[Int(exprOffsets[Int(id)])]).unsafelyUnwrapped
    }

    /// The payload of expression `id`.
    @inline(__always)
    func exprPayload(_ id: Int32) -> UnsafeBufferPointer<Int32> {
        let start = Int(exprOffsets[Int(id)])
        let count = Int(exprData[start &+ 1])
        let payloadStart = start &+ GrammarStorage.headerWords
        return UnsafeBufferPointer(rebasing: UnsafeBufferPointer(exprData)[payloadStart ..< payloadStart &+ count])
    }
}
