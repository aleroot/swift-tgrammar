extension CompiledGrammar {
    /// A versioned, deterministic snapshot of the optimized grammar and adaptive token masks.
    /// The tokenizer vocabulary is supplied separately when restoring the snapshot.
    public var serializedJSON: String {
        let s = SerializationValue.self
        let entries = masks.sorted { a, b in
            let x = a.key, y = b.key
            if x.ruleID != y.ruleID { return x.ruleID < y.ruleID }
            if x.sequenceID != y.sequenceID { return x.sequenceID < y.sequenceID }
            if x.elementID != y.elementID { return x.elementID < y.elementID }
            return x.subElementID < y.subElementID
        }.map { key, mask in
            JSONValue.array([s.numbers([key.ruleID, key.sequenceID, key.elementID, -1, 0, key.subElementID, 0, 0, -1, -1]), mask.serializationValue])
        }
        let metadata = tokenizerInfo.metadata
        return s.object([
            ("grammar", grammar.storage.serializationValue()),
            ("tokenizer_metadata", s.object([("vocab_type", s.number(metadata.vocabType.rawValue)), ("vocab_size", s.number(metadata.vocabSize)),
                                            ("add_prefix_space", .bool(metadata.addPrefixSpace)), ("stop_token_ids", s.numbers(metadata.stopTokenIDs))])),
            ("adaptive_token_mask_cache", .array(entries)),
        ], versioned: true).serialized()
    }

    /// Restore with the same vocabulary and model logits width used to compile the snapshot.
    public convenience init(serializedJSON: String, tokenizerInfo: TokenizerInfo) throws(SerializationError) {
        let s = SerializationValue.self
        let value = try s.parse(serializedJSON)
        let storage = try GrammarStorage.restore(s.required(value, "grammar"))
        try s.check(storage.isOptimized, "Compiled grammar is not optimized")
        let metadata = try s.required(value, "tokenizer_metadata")
        let type: Int32 = try s.integer(s.required(metadata, "vocab_type"))
        let size: Int = try s.integer(s.required(metadata, "vocab_size"))
        let prefix = try s.bool(s.required(metadata, "add_prefix_space"))
        let stops: [Int32] = try s.integers(s.required(metadata, "stop_token_ids"))
        try s.check(type == tokenizerInfo.vocabType.rawValue && size == tokenizerInfo.vocabSize && prefix == tokenizerInfo.addPrefixSpace && stops == tokenizerInfo.stopTokenIDs, "Tokenizer metadata mismatch")
        var masks: [ParserStateCacheKey: AdaptiveTokenMask] = [:]
        for entry in try s.array(s.required(value, "adaptive_token_mask_cache")) {
            let pair = try s.array(entry, count: 2)
            let state: [Int32] = try s.integers(pair[0])
            try s.check(state.count == 10, "Invalid parser state")
            let ruleID = state[0]
            try s.check(ruleID >= 0 && ruleID < storage.ruleCount, "Cache rule is out of range")
            let fsm = storage.perRuleFSMs[Int(ruleID)]!.fsm
            try s.check(state[1] == storage.rule(ruleID).bodyExprID && state[2] >= 0 && state[2] < fsm.stateCount && state[5] >= 0, "Invalid cache parser state")
            let key = ParserStateCacheKey(ParserState(ruleID: ruleID, sequenceID: state[1], elementID: state[2], ruleStartPos: -1, subElementID: state[5]))
            try s.check(masks[key] == nil, "Duplicate mask-cache entry")
            masks[key] = try AdaptiveTokenMask.restore(pair[1], tokenizer: tokenizerInfo)
        }
        for edge in storage.completeFSM!.edges where edge.isToken || edge.isExcludeToken {
            try s.check(storage.completeFSM!.tokenInfo(at: edge.auxIndex).tokenIDs.allSatisfy { $0 < tokenizerInfo.vocabSize }, "Grammar token exceeds vocabulary size")
        }
        CompiledGrammar.populateRepeatInteriorBitsets(storage, tokenizerInfo, &masks)
        self.init(grammar: Grammar(storage: storage), tokenizerInfo: tokenizerInfo, masks: masks)
    }
}

extension AdaptiveTokenMask {
    var serializationValue: JSONValue {
        let s = SerializationValue.self
        let bitset = [s.number(acceptedBitset.vocabSize), s.number(acceptedBitset.words.count)] + acceptedBitset.words.map(s.number)
        return s.object([("store_type", s.number(storeType.rawValue)), ("accepted_indices", s.numbers(acceptedIndices)),
                         ("rejected_indices", s.numbers(rejectedIndices)), ("uncertain_indices", s.numbers(uncertainIndices.array)), ("accepted_bitset", .array(bitset))])
    }
    static func restore(_ value: JSONValue, tokenizer: TokenizerInfo) throws(SerializationError) -> Self {
        let s = SerializationValue.self
        let rawType: Int32 = try s.integer(s.required(value, "store_type"))
        guard let type = StoreType(rawValue: rawType) else { throw .format("Unknown mask storage type") }
        let accepted: [Int32] = try s.integers(s.required(value, "accepted_indices"))
        let rejected: [Int32] = try s.integers(s.required(value, "rejected_indices"))
        let uncertain: [Int32] = try s.integers(s.required(value, "uncertain_indices"))
        for indices in [accepted, rejected, uncertain] {
            try s.check(indices == Array(Set(indices)).sorted() && indices.allSatisfy { $0 >= 0 && $0 < tokenizer.sortedTokens.count }, "Mask index is out of range or not sorted")
        }
        try s.check(Set(accepted).isDisjoint(with: rejected) && Set(accepted).isDisjoint(with: uncertain) && Set(rejected).isDisjoint(with: uncertain), "Mask classes overlap")
        let bitset = try s.array(s.required(value, "accepted_bitset"))
        try s.check(bitset.count >= 2, "Invalid bitset")
        let size: Int = try s.integer(bitset[0]), count: Int = try s.integer(bitset[1])
        try s.check(size >= 0 && size <= tokenizer.vocabSize && count == (size + 31) / 32 && count == bitset.count - 2, "Bitset size mismatch")
        try s.check(type != .acceptedBitset || size == tokenizer.vocabSize, "Bitset does not match tokenizer")
        let words: [UInt32] = try bitset.dropFirst(2).map { value throws(SerializationError) in try s.integer(value) }
        var result = Self(vocabSize: tokenizer.vocabSize, sortedTokenIDs: tokenizer.sortedTokenIDs, accepted: [], uncertain: [])
        result.storeType = type
        result.acceptedIndices = accepted; result.rejectedIndices = rejected; result.uncertainIndices = IndexRuns(uncertain)
        result.acceptedBitset = TokenBitmask(vocabSize: size, words: words)
        return result
    }
}
