extension Grammar {
    /// XGrammar's versioned JSON arena format. Restoring an optimized grammar also restores its
    /// automata, avoiding grammar transformation work when loading a compiled cache.
    public var serializedJSON: String { storage.serializationValue(versioned: true).serialized() }

    public convenience init(serializedJSON: String) throws(SerializationError) {
        self.init(storage: try GrammarStorage.restore(SerializationValue.parse(serializedJSON)))
    }
}

extension GrammarStorage {
    func serializationValue(versioned: Bool = false) -> JSONValue {
        let s = SerializationValue.self
        let rules = rules.map { rule in
            JSONValue.array([s.text(rule.name), s.number(rule.bodyExprID), s.number(rule.lookaheadAssertionID),
                             .bool(rule.isExactLookahead), s.number(rule.maxTokens), s.number(rule.maxChars),
                             s.text(rule.captureName), .bool(rule.isLazy), rule.temperature.map { .number(String($0)) } ?? .null])
        }
        let suffix = suffixStopInfos.map { info in
            JSONValue.array([s.number(info.ruleID), s.number(info.hiddenSuffixBytes), s.number(info.hiddenStopBytes),
                             s.number(info.bodyRuleID), s.number(info.markerRuleID), s.text(info.stopCaptureName)])
        }
        let complete = completeFSM?.serializationValue
        return s.object([
            ("rules", .array(rules)), ("suffix_stop_infos", .array(suffix)),
            ("grammar_expr_data", s.numbers(exprData)), ("grammar_expr_indptr", s.numbers(exprOffsets)),
            ("root_rule_id", s.number(rootRuleID)), ("complete_fsm", complete ?? .null),
            ("per_rule_fsms", .array(perRuleFSMs.map { view in
                // Rule views share the complete automaton; build its value once.
                view.map { $0.serializationValue(fsm: $0.fsm.fsm == completeFSM ? complete : nil) } ?? .null
            })),
            ("has_token_edges", .bool(hasTokenEdges)),
            ("allow_empty_rule_ids", s.numbers(allowEmptyRuleIDs)), ("optimized", .bool(isOptimized)),
        ], versioned: versioned)
    }

    static func restore(_ value: JSONValue) throws(SerializationError) -> Self {
        let s = SerializationValue.self
        var result = Self()
        result.exprData = try s.integers(s.required(value, "grammar_expr_data"))
        result.exprOffsets = try s.integers(s.required(value, "grammar_expr_indptr"))
        result.rootRuleID = try s.integer(s.required(value, "root_rule_id"))
        result.isOptimized = try s.bool(s.required(value, "optimized"))
        result.rules = try s.array(s.required(value, "rules")).map { raw throws(SerializationError) in
            let raw = try s.array(raw, count: 9)
            var rule = GrammarRule(name: try s.decodeText(raw[0]), bodyExprID: try s.integer(raw[1]), lookaheadAssertionID: try s.integer(raw[2]))
            rule.isExactLookahead = try s.bool(raw[3])
            rule.maxTokens = try s.integer(raw[4])
            rule.maxChars = try s.integer(raw[5])
            rule.captureName = try s.decodeText(raw[6])
            rule.isLazy = try s.bool(raw[7])
            if raw[8] != .null {
                guard case .number(let text) = raw[8], let temperature = Float(text), temperature.isFinite, temperature >= 0 else { throw .format("Invalid temperature") }
                rule.temperature = temperature
            }
            return rule
        }
        result.suffixStopInfos = try s.array(s.required(value, "suffix_stop_infos")).map { raw throws(SerializationError) in
            let raw = try s.array(raw, count: 6)
            var info = SuffixStopInfo()
            info.ruleID = try s.integer(raw[0]); info.hiddenSuffixBytes = try s.integer(raw[1]); info.hiddenStopBytes = try s.integer(raw[2])
            info.bodyRuleID = try s.integer(raw[3]); info.markerRuleID = try s.integer(raw[4]); info.stopCaptureName = try s.decodeText(raw[5])
            return info
        }
        let complete = try s.required(value, "complete_fsm")
        if complete != .null { result.completeFSM = try CompactFSM.restore(complete) }
        result.perRuleFSMs = try s.array(s.required(value, "per_rule_fsms")).map { raw throws(SerializationError) in
            raw == .null ? nil : try CompactFSMWithStartEndWithSize.restore(raw, sharing: result.completeFSM)
        }
        let hasTokenEdges = try s.bool(s.required(value, "has_token_edges"))
        result.allowEmptyRuleIDs = try s.integers(s.required(value, "allow_empty_rule_ids"))
        try result.validateSerializedStorage()
        try s.check(hasTokenEdges == result.hasTokenEdges, "has_token_edges does not match the automaton")
        return result
    }
}

extension CompactFSM {
    var serializationValue: JSONValue {
        let s = SerializationValue.self
        return s.object([
            ("edges", s.object([("data_", .array(edges.map { s.numbers([$0.min, $0.max, $0.target]) })), ("indptr_", s.numbers(offsets))])),
            ("edge_aux_data", s.numbers(auxData)), ("edge_num", s.number(edgeCount)),
        ])
    }

    static func restore(_ value: JSONValue) throws(SerializationError) -> Self {
        let s = SerializationValue.self
        let rows = try s.required(value, "edges")
        let edges = try s.array(s.required(rows, "data_")).map { raw throws(SerializationError) in
            let raw = try s.array(raw, count: 3)
            return FSMEdge(min: try s.integer(raw[0]), max: try s.integer(raw[1]), target: try s.integer(raw[2]))
        }
        let offsets: [Int32] = try s.integers(s.required(rows, "indptr_"))
        let aux: [Int32] = try s.integers(s.required(value, "edge_aux_data"))
        let count: Int = try s.integer(s.required(value, "edge_num"))
        try s.check(count == edges.count && offsets.first == 0 && offsets.last.map(Int.init) == edges.count && offsets.allSatisfy { $0 >= 0 && $0 <= edges.count }, "Invalid FSM CSR bounds")
        try s.check(zip(offsets, offsets.dropFirst()).allSatisfy { $0 <= $1 }, "FSM offsets are not ordered")
        let fsm = Self(offsets: offsets, edges: edges, auxData: aux)
        try fsm.validateSerializedFSM()
        return fsm
    }
}

extension CompactFSMWithStartEndWithSize {
    func serializationValue(fsm fsmValue: JSONValue? = nil) -> JSONValue {
        let s = SerializationValue.self
        return .array([.array([fsmValue ?? fsm.fsm.serializationValue, s.number(fsm.start), s.numbers(fsm.ends), .bool(fsm.isDFA), s.number(fsm.edgeCount)]),
                       s.number(edgeCount), s.number(nodeCount)])
    }
    static func restore(_ value: JSONValue, sharing complete: CompactFSM?) throws(SerializationError) -> Self {
        let s = SerializationValue.self
        let outer = try s.array(value, count: 3)
        let view = try s.array(outer[0], count: 5)
        var fsm = try CompactFSM.restore(view[0])
        if let complete, fsm == complete { fsm = complete }
        let start: Int32 = try s.integer(view[1])
        let ends: [Int32] = try s.integers(view[2])
        let viewCount: Int = try s.integer(view[4])
        let edgeCount: Int = try s.integer(outer[1])
        let nodeCount: Int = try s.integer(outer[2])
        try s.check(start >= 0 && start < fsm.stateCount && ends.allSatisfy { $0 >= 0 && $0 < fsm.stateCount }, "FSM start or end is out of range")
        try s.check(ends == Array(Set(ends)).sorted(), "FSM end states are not sorted and unique")
        try s.check(viewCount == fsm.edgeCount && edgeCount >= 0 && edgeCount <= fsm.edgeCount && nodeCount >= 0 && nodeCount <= fsm.stateCount, "Invalid FSM fragment size")
        return Self(fsm: .init(fsm: fsm, start: start, ends: ends, isDFA: try s.bool(view[3])), edgeCount: edgeCount, nodeCount: nodeCount)
    }
}
