// Intermediate representation of a grammar. Expressions live in one flat `Int32` arena laid out as
// `[kind, count, payload...]` records addressed by expression id; rules reference their body and
// lookahead by expression id. The layout is compact, trivially copyable, and lets every analysis
// pass walk a grammar without chasing pointers.

/// Kind of a node in the expression arena. Raw values are stable and part of the serialized form.
public enum GrammarExprKind: Int32, Sendable {
    /// `[byte0, byte1, ...]` — a literal byte string.
    case byteString = 0
    /// `[isNegated, lower0, upper0, lower1, upper1, ...]` — inclusive code point ranges.
    case characterClass = 1
    /// Same payload as ``characterClass``; matches zero or more characters.
    case characterClassStar = 2
    /// `[]` — the empty string.
    case emptyString = 3
    /// `[ruleID]`.
    case ruleRef = 4
    /// `[exprID0, exprID1, ...]` matched in order.
    case sequence = 5
    /// `[exprID0, exprID1, ...]` alternatives.
    case choices = 6
    /// `[tagExprID0, ruleID0, ..., loopAfterDispatch, excludesChoicesExprID]`.
    case tagDispatch = 7
    /// `[ruleID, minCount, maxCount]` with `maxCount == -1` meaning unbounded.
    case `repeat` = 8
    /// `[tokenID0, tokenID1, ...]` — exactly one token from the set.
    case token = 9
    /// `[tokenID0, tokenID1, ...]` — exactly one token outside the set.
    case excludeToken = 10
    /// `[triggerCount, (tokenID, ruleID)×N, loopAfterDispatch, excludeCount, tokenID×M]`.
    case tokenTagDispatch = 11
    /// `[isJSONString, byte0, byte1, ...]` — a regular expression pattern.
    case regex = 12
    /// `[chunk0Length, bytes..., chunk1Length, bytes..., ...]`.
    case substring = 13
}

/// A production rule.
public struct GrammarRule: Sendable, Hashable {
    public var name: String
    /// Expression id of the body; `-1` while a rule is only declared.
    public var bodyExprID: Int32
    /// Expression id of the lookahead assertion (a sequence), or `-1`.
    public var lookaheadAssertionID: Int32 = -1
    public var isExactLookahead = false
    /// Token budget per occurrence; `-1` means unlimited.
    public var maxTokens: Int32 = -1
    /// Code point budget per occurrence; `-1` means unlimited.
    public var maxChars: Int32 = -1
    /// Non-empty when the matcher must record the span matched by this rule.
    public var captureName = ""
    /// Committed-shortest matching: the rule completes at its first possible end.
    public var isLazy = false
    /// Sampling temperature active while the rule is open.
    public var temperature: Float?

    public init(name: String, bodyExprID: Int32, lookaheadAssertionID: Int32 = -1) {
        self.name = name
        self.bodyExprID = bodyExprID
        self.lookaheadAssertionID = lookaheadAssertionID
    }
}

/// Capture-materialization metadata for rules terminated by a suffix or stop marker.
public struct SuffixStopInfo: Sendable, Hashable {
    public var ruleID: Int32 = -1
    public var hiddenSuffixBytes: Int32 = 0
    public var hiddenStopBytes: Int32 = 0
    public var bodyRuleID: Int32 = -1
    public var markerRuleID: Int32 = -1
    public var stopCaptureName = ""

    public init() {}

    public var isEmpty: Bool {
        hiddenSuffixBytes == 0 && hiddenStopBytes == 0 && bodyRuleID == -1 && markerRuleID == -1
            && stopCaptureName.isEmpty
    }
}

/// Decoded form of a ``GrammarExprKind/tagDispatch`` expression.
public struct TagDispatch: Sendable, Hashable {
    public var tagRulePairs: [(tag: [UInt8], ruleID: Int32)]
    public var loopAfterDispatch: Bool
    public var excludes: [[UInt8]]

    public init(tagRulePairs: [(tag: [UInt8], ruleID: Int32)] = [], loopAfterDispatch: Bool = true, excludes: [[UInt8]] = []) {
        self.tagRulePairs = tagRulePairs
        self.loopAfterDispatch = loopAfterDispatch
        self.excludes = excludes
    }

    public static func == (lhs: TagDispatch, rhs: TagDispatch) -> Bool {
        lhs.loopAfterDispatch == rhs.loopAfterDispatch && lhs.excludes == rhs.excludes
            && lhs.tagRulePairs.count == rhs.tagRulePairs.count
            && zip(lhs.tagRulePairs, rhs.tagRulePairs).allSatisfy { $0.tag == $1.tag && $0.ruleID == $1.ruleID }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(loopAfterDispatch)
        hasher.combine(excludes)
        for pair in tagRulePairs {
            hasher.combine(pair.tag)
            hasher.combine(pair.ruleID)
        }
    }
}

/// Decoded form of a ``GrammarExprKind/tokenTagDispatch`` expression.
public struct TokenTagDispatch: Sendable, Hashable {
    public var triggerRulePairs: [(tokenID: Int32, ruleID: Int32)]
    public var loopAfterDispatch: Bool
    public var excludes: [Int32]

    public init(triggerRulePairs: [(tokenID: Int32, ruleID: Int32)] = [], loopAfterDispatch: Bool = true, excludes: [Int32] = []) {
        self.triggerRulePairs = triggerRulePairs
        self.loopAfterDispatch = loopAfterDispatch
        self.excludes = excludes
    }

    public static func == (lhs: TokenTagDispatch, rhs: TokenTagDispatch) -> Bool {
        lhs.loopAfterDispatch == rhs.loopAfterDispatch && lhs.excludes == rhs.excludes
            && lhs.triggerRulePairs.count == rhs.triggerRulePairs.count
            && zip(lhs.triggerRulePairs, rhs.triggerRulePairs).allSatisfy { $0.tokenID == $1.tokenID && $0.ruleID == $1.ruleID }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(loopAfterDispatch)
        hasher.combine(excludes)
        for pair in triggerRulePairs {
            hasher.combine(pair.tokenID)
            hasher.combine(pair.ruleID)
        }
    }
}

/// A zero-copy view of one expression record in the arena.
public struct GrammarExpr: Sendable {
    public let kind: GrammarExprKind
    /// The payload; shares storage with the arena.
    public let data: ArraySlice<Int32>

    @inline(__always)
    public var count: Int { data.count }

    @inline(__always)
    public subscript(index: Int) -> Int32 { data[data.startIndex &+ index] }

    public var isEmpty: Bool { data.isEmpty }
}

extension GrammarExpr: Sequence {
    public func makeIterator() -> IndexingIterator<ArraySlice<Int32>> { data.makeIterator() }
}

/// Value storage of a grammar. Copy-on-write; passes build new storages through a builder.
struct GrammarStorage: Sendable {
    /// Number of header words in front of each expression record (`kind`, `count`).
    static let headerWords = 2

    var rules: [GrammarRule] = []
    /// Sorted by `ruleID`; rules without suffix/stop metadata are omitted.
    var suffixStopInfos: [SuffixStopInfo] = []
    var exprData: [Int32] = []
    /// Start of each record in ``exprData``; the expression id indexes this table.
    var exprOffsets: [Int32] = []
    var rootRuleID: Int32 = -1

    // MARK: Compile-time products (set by `GrammarOptimizer`)

    /// One automaton holding every rule's FSM; ``perRuleFSMs`` are views into it.
    var completeFSM: CompactFSM? = nil
    /// Per rule, the view of its automaton inside ``completeFSM`` (indexed by rule id).
    var perRuleFSMs: [CompactFSMWithStartEndWithSize?] = []
    /// Sorted ids of the rules that can match the empty string.
    var allowEmptyRuleIDs: [Int32] = []
    /// Whether the optimizer pipeline has run.
    var isOptimized = false

    var ruleCount: Int { rules.count }
    var exprCount: Int { exprOffsets.count }

    /// Whether ``completeFSM`` has a token or exclude-token edge, the only edges that can take a
    /// token whole (upstream's serialized `has_token_edges`).
    var hasTokenEdges: Bool { completeFSM?.edges.contains { $0.isToken || $0.isExcludeToken } ?? false }

    @inline(__always)
    func expr(_ id: Int32) -> GrammarExpr {
        let start = Int(exprOffsets[Int(id)])
        let kind = GrammarExprKind(rawValue: exprData[start]).unsafelyUnwrapped
        let count = Int(exprData[start &+ 1])
        let payloadStart = start &+ Self.headerWords
        return GrammarExpr(kind: kind, data: exprData[payloadStart ..< payloadStart &+ count])
    }

    @inline(__always)
    func kind(of id: Int32) -> GrammarExprKind {
        GrammarExprKind(rawValue: exprData[Int(exprOffsets[Int(id)])]).unsafelyUnwrapped
    }

    @inline(__always)
    func rule(_ id: Int32) -> GrammarRule { rules[Int(id)] }

    var rootRule: GrammarRule { rules[Int(rootRuleID)] }

    /// Whether `ruleID` can match the empty string (valid once optimized).
    @inline(__always)
    func allowsEmpty(_ ruleID: Int32) -> Bool { allowEmptyRuleIDs.binarySearchContains(ruleID) }

    /// Overwrites the payload word `index` of expression `id` in place.
    mutating func setExprData(_ id: Int32, index: Int, value: Int32) {
        exprData[Int(exprOffsets[Int(id)]) &+ Self.headerWords &+ index] = value
    }

    /// Appends a record and returns its id.
    @discardableResult
    mutating func append(_ kind: GrammarExprKind, _ payload: some Collection<Int32>) -> Int32 {
        let id = Int32(exprOffsets.count)
        exprOffsets.append(Int32(exprData.count))
        exprData.append(kind.rawValue)
        exprData.append(Int32(payload.count))
        exprData.append(contentsOf: payload)
        return id
    }

    func suffixStopInfo(for ruleID: Int32) -> SuffixStopInfo? {
        var low = 0
        var high = suffixStopInfos.count
        while low < high {
            let mid = (low &+ high) >> 1
            let candidate = suffixStopInfos[mid].ruleID
            if candidate == ruleID { return suffixStopInfos[mid] }
            if candidate < ruleID { low = mid &+ 1 } else { high = mid }
        }
        return nil
    }

    mutating func setSuffixStopInfo(_ info: SuffixStopInfo, for ruleID: Int32) {
        var insertion = suffixStopInfos.count
        for (index, existing) in suffixStopInfos.enumerated() where existing.ruleID >= ruleID {
            if existing.ruleID == ruleID {
                if info.isEmpty { suffixStopInfos.remove(at: index) } else {
                    var stored = info
                    stored.ruleID = ruleID
                    suffixStopInfos[index] = stored
                }
                return
            }
            insertion = index
            break
        }
        if info.isEmpty { return }
        var stored = info
        stored.ruleID = ruleID
        suffixStopInfos.insert(stored, at: insertion)
    }

    // MARK: Decoders

    func byteString(_ expr: GrammarExpr) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(expr.count)
        for value in expr.data { bytes.append(UInt8(truncatingIfNeeded: value)) }
        return bytes
    }

    func regexPattern(_ expr: GrammarExpr) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(expr.count &- 1)
        for value in expr.data.dropFirst() { bytes.append(UInt8(truncatingIfNeeded: value)) }
        return bytes
    }

    func regexIsJSONString(_ expr: GrammarExpr) -> Bool { expr[0] != 0 }

    func substringChunks(_ expr: GrammarExpr) -> [[UInt8]] {
        var chunks: [[UInt8]] = []
        var index = 0
        while index < expr.count {
            let length = Int(expr[index])
            index += 1
            var chunk: [UInt8] = []
            chunk.reserveCapacity(length)
            for offset in 0 ..< length { chunk.append(UInt8(truncatingIfNeeded: expr[index &+ offset])) }
            chunks.append(chunk)
            index += length
        }
        return chunks
    }

    /// Number of trailing scalar parameters of a tag dispatch record.
    static let tagDispatchTrailingWords = 2

    func tagDispatch(_ expr: GrammarExpr) -> TagDispatch {
        let pairCount = (expr.count &- Self.tagDispatchTrailingWords) / 2
        var pairs: [(tag: [UInt8], ruleID: Int32)] = []
        pairs.reserveCapacity(pairCount)
        for pair in 0 ..< pairCount {
            pairs.append((byteString(self.expr(expr[pair &* 2])), expr[pair &* 2 &+ 1]))
        }
        let loop = expr[expr.count &- 2] != 0
        let excludesExpr = self.expr(expr[expr.count &- 1])
        let excludes = excludesExpr.map { byteString(self.expr($0)) }
        return TagDispatch(tagRulePairs: pairs, loopAfterDispatch: loop, excludes: excludes)
    }

    func tokenTagDispatch(_ expr: GrammarExpr) -> TokenTagDispatch {
        let triggerCount = Int(expr[0])
        var pairs: [(tokenID: Int32, ruleID: Int32)] = []
        pairs.reserveCapacity(triggerCount)
        for pair in 0 ..< triggerCount {
            pairs.append((expr[1 &+ pair &* 2], expr[2 &+ pair &* 2]))
        }
        var index = 1 &+ triggerCount &* 2
        let loop = expr[index] != 0
        index += 1
        let excludeCount = Int(expr[index])
        index += 1
        var excludes: [Int32] = []
        excludes.reserveCapacity(excludeCount)
        for offset in 0 ..< excludeCount { excludes.append(expr[index &+ offset]) }
        return TokenTagDispatch(triggerRulePairs: pairs, loopAfterDispatch: loop, excludes: excludes)
    }
}
