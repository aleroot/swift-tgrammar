// Compiles grammars against one tokenizer. The expensive part — one vocabulary replay per
// scanable automaton state — is parallelized across cores; results are cached by source so
// repeated requests for the same grammar return instantly.

import Dispatch
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Compiles ``Grammar`` values into ``CompiledGrammar`` values for one tokenizer.
///
/// A compiler is safe to share between threads; compilation of the same grammar from several
/// threads is deduplicated by the cache.
public final class GrammarCompiler: Sendable {
    public let tokenizerInfo: TokenizerInfo
    /// Upper bound on concurrently computed masks; `1` compiles serially.
    public let maxThreads: Int
    public let isCacheEnabled: Bool
    /// Whether compilation prepares the grammar and leaves each token mask to be computed the
    /// first time a matcher needs it (see ``init(tokenizerInfo:maxThreads:cacheEnabled:maxCacheBytes:dynamicCompilation:)``).
    public let isDynamicCompilationEnabled: Bool

    enum CacheKey: Hashable {
        case ebnf(String, rootRule: String)
        case jsonSchema(JSONSchema, JSONSchemaOptions)
        case lark(String, references: String)
    }

    private final class CompilationGate: Sendable {
        let lock = Mutex<CompiledGrammar?>(nil)
        let generation: UInt64
        init(generation: UInt64) { self.generation = generation }
    }

    private struct Cache {
        var entries: [CacheKey: CompiledGrammar] = [:]
        var order: [CacheKey] = []
        var totalBytes = 0
        var inFlight: [CacheKey: CompilationGate] = [:]
        var generation: UInt64 = 0
    }

    private let cache = Mutex(Cache())
    /// Approximate overall cache budget; `nil` is unlimited.
    public let maxCacheBytes: Int?
    /// Budget of the whole-grammar cache (two thirds of ``maxCacheBytes``).
    private let grammarCacheBytes: Int?
    /// Masks shared between grammars whose rules have identical automata; `nil` when the cache
    /// is disabled. Holds the remaining third of the budget.
    let ruleLevelCache: RuleLevelCache?
    /// Whether rules of one grammar with identical automata share masks even when the cache is
    /// disabled. Off only for tests that need masks computed independently, state by state.
    let sharesMasksWithinGrammar: Bool
    /// Tokens a state's first bytes must start for rules to share its mask within a grammar
    /// (hashing the grammar costs about as much as replaying a few hundred tokens).
    let minimumSharedScan: Int
    /// Registration with ``MemoryPressureRelief``, which clears the caches under memory pressure.
    private let pressureRegistration = Atomic<UInt64>(0)

    /// - Parameters:
    ///   - tokenizerInfo: The tokenizer every grammar is compiled against.
    ///   - maxThreads: Parallelism of mask computation; defaults to the active processor count.
    ///   - cacheEnabled: Whether compiled grammars are cached by source, and rule masks across
    ///     grammars.
    ///   - maxCacheBytes: Approximate cache budget; `nil` is unlimited. Defaults to
    ///     ``defaultMaxCacheBytes``, a budget scaled to the device.
    ///   - dynamicCompilation: Compile only the grammar and leave every token mask to be computed
    ///     the first time a matcher needs it, then kept in the compiled grammar for all of its
    ///     matchers (upstream's `enable_dynamic_compilation`). Compilation becomes a small fraction
    ///     of its eager cost, and decoding pays for each new automaton state it reaches; masks
    ///     still come from the rule-level cache when it is enabled. A dynamically compiled
    ///     grammar grows while it is used, so with a finite `maxCacheBytes` compiled grammars are
    ///     not cached (rule masks still are). Off by default.
    public convenience init(tokenizerInfo: TokenizerInfo, maxThreads: Int? = nil, cacheEnabled: Bool = true,
                            maxCacheBytes: Int? = GrammarCompiler.defaultMaxCacheBytes, dynamicCompilation: Bool = false) {
        self.init(tokenizerInfo: tokenizerInfo, maxThreads: maxThreads, cacheEnabled: cacheEnabled, maxCacheBytes: maxCacheBytes,
                  sharesMasksWithinGrammar: true, dynamicCompilation: dynamicCompilation)
    }

    init(tokenizerInfo: TokenizerInfo, maxThreads: Int?, cacheEnabled: Bool, maxCacheBytes: Int?, sharesMasksWithinGrammar: Bool,
         minimumSharedScan: Int = 256, dynamicCompilation: Bool = false) {
        isDynamicCompilationEnabled = dynamicCompilation
        precondition(maxCacheBytes.map { $0 >= 0 } ?? true, "Cache budget must be non-negative")
        self.sharesMasksWithinGrammar = sharesMasksWithinGrammar
        self.minimumSharedScan = minimumSharedScan
        self.tokenizerInfo = tokenizerInfo
        self.maxThreads = max(1, maxThreads ?? ProcessorCount.active)
        isCacheEnabled = cacheEnabled
        self.maxCacheBytes = maxCacheBytes
        grammarCacheBytes = maxCacheBytes.map { $0 / 3 * 2 }
        ruleLevelCache = cacheEnabled ? RuleLevelCache(maxBytes: maxCacheBytes.map { $0 - $0 / 3 * 2 }) : nil
        if cacheEnabled {
            pressureRegistration.store(MemoryPressureRelief.shared.register { [weak self] in self?.clearCache() }, ordering: .relaxed)
        }
    }

    deinit {
        let registration = pressureRegistration.load(ordering: .relaxed)
        if registration != 0 { MemoryPressureRelief.shared.unregister(registration) }
    }

    /// The default cache budget: 1/256 of the device's physical memory, at most 64 MiB (32 MiB on
    /// an 8 GB iPhone). A tool-calling session compiles a new grammar whenever the tool set
    /// changes, so an unbounded cache would grow for the lifetime of the app; upstream XGrammar,
    /// written for servers, defaults to unlimited.
    public static let defaultMaxCacheBytes: Int? = {
        #if canImport(Darwin)
        var memory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &memory, &size, nil, 0) == 0, memory > 0 {
            return Int(min(UInt64(64 << 20), memory / 256))
        }
        #endif
        return 64 << 20
    }()

    /// Drops every cache TGrammar keeps: the compiled grammars and shared rule masks of every
    /// live compiler, and the process-wide automaton memos. Grammars already handed out stay
    /// valid; only cache entries are released.
    ///
    /// This runs automatically when the system reports memory pressure. Call it yourself to
    /// free memory at a moment of your choosing, such as when a model is unloaded.
    public static func purgeCaches() {
        MemoryPressureRelief.shared.purgeAll()
    }

    // MARK: Entry points

    /// Compiles a grammar written in EBNF.
    public func compile(ebnf: String, rootRule: String = "root") throws(GrammarError) -> CompiledGrammar {
        try cached(.ebnf(ebnf, rootRule: rootRule)) { () throws(GrammarError) in
            try self.compileUncached(try Grammar(ebnf: ebnf, rootRule: rootRule))
        }
    }

    /// Compiles an already-built grammar. Cached by its printed form.
    public func compile(_ grammar: Grammar) throws(GrammarError) -> CompiledGrammar {
        try cached(.ebnf(grammar.description, rootRule: grammar.rootRule.name)) { () throws(GrammarError) in
            try self.compileUncached(grammar)
        }
    }

    /// Drops every cached compiled grammar and shared rule mask.
    public func clearCache() {
        cache.withLock {
            $0.entries.removeAll()
            $0.order.removeAll()
            $0.totalBytes = 0
            $0.inFlight.removeAll()
            $0.generation &+= 1
        }
        ruleLevelCache?.removeAll()
    }

    /// Approximate size of the caches in bytes.
    public var cacheSizeBytes: Int { cache.withLock { $0.totalBytes } + (ruleLevelCache?.totalBytes ?? 0) }

    /// `key` is evaluated only when the cache is enabled: printing a grammar for its key costs
    /// more than compiling a small one. Not inlined: every `compile` entry point calls it, and a
    /// copy per entry point cost ~5 KB each.
    @inline(never)
    func cached(_ key: @autoclosure () -> CacheKey, _ compute: () throws(GrammarError) -> CompiledGrammar) throws(GrammarError) -> CompiledGrammar {
        // A dynamically compiled grammar grows after insertion, past any accounted budget.
        guard isCacheEnabled, !isDynamicCompilationEnabled || grammarCacheBytes == nil else { return try compute() }
        let key = key()
        if let hit = cache.withLock({ cache -> CompiledGrammar? in
            guard let value = cache.entries[key] else { return nil }
            if let index = cache.order.firstIndex(of: key) {
                cache.order.remove(at: index)
                cache.order.append(key)
            }
            return value
        }) {
            return hit
        }
        let gate = cache.withLock { cache in
            if let gate = cache.inFlight[key] { return gate }
            let gate = CompilationGate(generation: cache.generation)
            cache.inFlight[key] = gate
            return gate
        }
        return try gate.lock.withLock { completed throws(GrammarError) in
            if let completed { return completed }
            defer {
                cache.withLock {
                    if $0.inFlight[key] === gate { $0.inFlight.removeValue(forKey: key) }
                }
            }
            // A concurrent caller may have completed while we waited on this key.
            if let value = cache.withLock({ $0.entries[key] }) {
                completed = value
                return value
            }
            let value = try compute()
            completed = value
            cache.withLock { cache in
                // Oversized entries are returned without violating the cache's memory budget.
                guard cache.generation == gate.generation,
                      grammarCacheBytes.map({ value.memorySize <= $0 }) ?? true else { return }
                if cache.entries[key] == nil {
                    cache.entries[key] = value
                    cache.order.append(key)
                    cache.totalBytes += value.memorySize
                    if let grammarCacheBytes {
                        while cache.totalBytes > grammarCacheBytes, cache.order.count > 1 {
                            let evicted = cache.order.removeFirst()
                            if let removed = cache.entries.removeValue(forKey: evicted) { cache.totalBytes -= removed.memorySize }
                        }
                    }
                }
            }
            return value
        }
    }

    // MARK: Compilation

    func compileUncached(_ source: Grammar) throws(GrammarError) -> CompiledGrammar {
        let grammar = Grammar(storage: try GrammarOptimizer.apply(source.storage))
        let storage = grammar.storage
        try Self.checkTokenIDs(storage, vocabSize: tokenizerInfo.vocabSize)
        if tokenizerInfo.vocabSize == 0 {
            return CompiledGrammar(grammar: grammar, tokenizerInfo: tokenizerInfo, masks: [:])
        }
        let secondSlicing = TagDispatchSlicing(storage, tokenizerInfo.sortedTokens)
        // Masks are computed for every scanable state of every rule's automaton.
        var collected: [(state: ParserState, isRoot: Bool)] = []
        var walker = ReachableStateWalker(storage.completeFSM.unsafelyUnwrapped)
        for ruleID in 0 ..< Int32(storage.ruleCount) {
            let rule = storage.rule(ruleID)
            let fsm = storage.perRuleFSMs[Int(ruleID)].unsafelyUnwrapped.fsm
            walker.walk(from: fsm.start)
            for stateID in walker.states.sorted() where fsm.isScanableState(stateID) {
                let state = ParserState(ruleID: ruleID, sequenceID: rule.bodyExprID, elementID: stateID, ruleStartPos: ParserState.noPreviousInputPosition, budgetDeadline: 0)
                collected.append((state, ruleID == storage.rootRuleID))
            }
        }
        let jobs = collected

        if isDynamicCompilationEnabled {
            // Tag-dispatch data, automaton hashes and the sharing plan are computed with the first
            // mask: compilation itself only prepares the grammar. Masks are shared the way eager
            // compilation shares them (rule-level cache, or among this grammar's rules).
            let states = jobs.map(\.state)
            let ruleLevelCache = ruleLevelCache, tokenizerInfo = tokenizerInfo, minimumSharedScan = minimumSharedScan
            let withinGrammar = sharesMasksWithinGrammar && !(grammar.parserTables?.hasCharBudgetRules ?? false)
            let source = LazyMaskSource(states: states, grammar: grammar, tokenizerInfo: tokenizerInfo, secondSlicing: secondSlicing,
                                        maxThreads: maxThreads) {
                if let ruleLevelCache { return MaskSharing(cache: ruleLevelCache, hashes: GrammarFSMHasher.apply(storage), sharedKeys: nil) }
                guard withinGrammar, Self.rulesMayShareMasks(storage, states, tokenizerInfo, minimumSharedScan) else { return MaskSharing() }
                let hashes = GrammarFSMHasher.apply(storage)
                var seen = Set<RuleLevelCacheKey>(), repeated = Set<RuleLevelCacheKey>()
                for state in states {
                    if let key = TokenMaskComputer.automatonKey(storage, hashes, state), !seen.insert(key).inserted { repeated.insert(key) }
                }
                if repeated.isEmpty { return MaskSharing() }
                return MaskSharing(cache: RuleLevelCache(maxBytes: nil), hashes: hashes, sharedKeys: repeated)
            }
            return CompiledGrammar(grammar: grammar, tokenizerInfo: tokenizerInfo, lazyMasks: source)
        }

        secondSlicing.computeAll()
        // Canonical automaton hashes let this grammar share masks with earlier ones, and its
        // rules share masks among themselves: converters give each JSON string value a rule of
        // its own (for an exact lookahead), and all of them run the same automaton. The mask of
        // such a state is computed once and adapted to every other rule's lookahead.

        var maskCache = ruleLevelCache ?? (sharesMasksWithinGrammar && Self.rulesMayShareMasks(storage, jobs.lazy.map(\.state), tokenizerInfo, minimumSharedScan) ? RuleLevelCache(maxBytes: nil) : nil)
        let fsmHashes = maskCache.map { _ in GrammarFSMHasher.apply(storage) }

        // States whose automaton was seen in an earlier job wait for a second round, so they
        // find that job's mask in the cache instead of replaying the vocabulary in parallel.
        var firstRound: [Int] = []
        var secondRound: [Int] = []
        // Within one grammar only the keys of second-round states are ever looked up, so only
        // their masks are stored (copying every mask into the cache cost more than it saved).
        var sharedKeys: Set<RuleLevelCacheKey>? = nil
        if let fsmHashes, !(grammar.parserTables?.hasCharBudgetRules ?? false) {
            var seen = Set<RuleLevelCacheKey>()
            var repeated = Set<RuleLevelCacheKey>()
            for index in jobs.indices {
                if let key = TokenMaskComputer.automatonKey(storage, fsmHashes, jobs[index].state), !seen.insert(key).inserted {
                    secondRound.append(index)
                    repeated.insert(key)
                } else {
                    firstRound.append(index)
                }
            }
            if ruleLevelCache == nil {
                sharedKeys = repeated
                if repeated.isEmpty { maskCache = nil }
            }
        } else {
            firstRound = Array(jobs.indices)
            if ruleLevelCache == nil { maskCache = nil }
        }
        let sharedMaskCache = maskCache
        let sharedKeySet = sharedKeys

        // Masks are interned as they arrive, so equal token sets are held once while the
        // remaining jobs run (the final grammar interns again, after the last edits).
        let results = Mutex<(masks: [ParserStateCacheKey: AdaptiveTokenMask], interner: MaskStorageInterner)>(([:], MaskStorageInterner()))
        // Each worker reuses one computer (its parser and buffers) across its jobs.
        let compute: @Sendable (inout TokenMaskComputer?, Int) -> Void = { computer, index in
            let job = jobs[index]
            if computer == nil {
                computer = TokenMaskComputer(grammar: grammar, initialState: job.state, tagDispatchSecondSlicing: secondSlicing, tokenizerInfo: self.tokenizerInfo,
                                             ruleLevelCache: sharedMaskCache, fsmHashes: fsmHashes, sharedKeys: sharedKeySet)
            } else {
                computer!.reset(initialState: job.state)
            }
            var mask = computer!.adaptiveTokenMask(isRootRule: job.isRoot)
            mask.compact()
            results.withLock { results in
                results.interner.intern(&mask)
                results.masks[ParserStateCacheKey(job.state)] = mask
            }
        }
        var serialComputer: TokenMaskComputer? = nil
        for round in [firstRound, secondRound] where !round.isEmpty {
            if maxThreads > 1, round.count > 1 {
                let workers = min(maxThreads, round.count)
                let nextJob = Mutex(0)
                DispatchQueue.concurrentPerform(iterations: workers) { _ in
                    var computer: TokenMaskComputer? = nil
                    while let index = nextJob.withLock({ next -> Int? in
                        guard next < round.count else { return nil }
                        defer { next += 1 }
                        return round[next]
                    }) {
                        compute(&computer, index)
                    }
                }
            } else {
                for index in round { compute(&serialComputer, index) }
            }
        }

        // Take the dictionary out of the lock, so editing it below does not copy every mask.
        var masks = results.withLock { results in
            defer { results = ([:], MaskStorageInterner()) }
            return results.masks
        }
        CompiledGrammar.populateRepeatInteriorBitsets(storage, tokenizerInfo, &masks, maxThreads: maxThreads)
        return CompiledGrammar(grammar: grammar, tokenizerInfo: tokenizerInfo, masks: masks)
    }

    /// Whether two rules could usefully share a mask within the grammar. Shared masks are keyed
    /// by the automaton's state and edge counts (besides its canonical hash), so it takes two
    /// rules of equal counts, each with a state whose first bytes start ``minimumSharedScan``
    /// tokens.
    private static func rulesMayShareMasks(_ grammar: GrammarStorage, _ states: some Sequence<ParserState>, _ tokenizerInfo: TokenizerInfo,
                                           _ minimumSharedScan: Int) -> Bool {
        let bounds = tokenizerInfo.firstByteBounds
        var sizes: [Int: Int32] = [:]
        var lastRule: Int32 = -1
        for state in states where state.ruleID != lastRule {
            let fragment = grammar.perRuleFSMs[Int(state.ruleID)].unsafelyUnwrapped
            var firstBytes = ByteSet()
            for edge in fragment.fsm.fsm.edges(of: state.elementID) where edge.isCharRange {
                firstBytes.insert(range: edge.min ... edge.max)
            }
            var scanned = 0
            firstBytes.forEachRun { lower, upper in scanned += Int(bounds[upper] - bounds[lower]) }
            guard scanned >= minimumSharedScan else { continue }
            lastRule = state.ruleID
            let size = fragment.nodeCount << 32 | fragment.edgeCount
            if let other = sizes.updateValue(state.ruleID, forKey: size), other != state.ruleID { return true }
        }
        return false
    }

    /// Token ids written in `Token(...)` / `ExcludeToken(...)` index per-token arrays during
    /// compilation, so they must be in range.
    private static func checkTokenIDs(_ grammar: GrammarStorage, vocabSize: Int) throws(GrammarError) {
        guard let fsm = grammar.completeFSM else { return }
        for state in 0 ..< Int32(fsm.stateCount) {
            for edge in fsm.edges(of: state) where edge.isToken || edge.isExcludeToken {
                for tokenID in fsm.tokenInfo(at: edge.auxIndex).tokenIDs where tokenID < 0 || Int(tokenID) >= vocabSize {
                    throw .invalidGrammar("Token id \(tokenID) in the grammar is out of the vocabulary range [0, \(vocabSize))")
                }
            }
        }
    }

}

/// Active processor count without Foundation.
enum ProcessorCount {
    static var active: Int {
        #if canImport(Darwin)
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.activecpu", &count, &size, nil, 0) == 0, count > 0 { return Int(count) }
        #elseif canImport(Glibc)
        return max(1, Int(sysconf(Int32(_SC_NPROCESSORS_ONLN))))
        #endif
        return 1
    }
}
