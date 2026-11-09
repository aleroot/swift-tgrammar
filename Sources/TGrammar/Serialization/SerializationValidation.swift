extension GrammarStorage {
    /// Validate all arena records before dereferencing any expression. Rule recursion is legal;
    /// cycles between expression containers are malformed and would recurse in transformations.
    func validateSerializedStorage() throws(SerializationError) {
        let s = SerializationValue.self
        func ruleOK(_ id: Int32) -> Bool { id >= 0 && id < ruleCount }
        func exprOK(_ id: Int32) -> Bool { id >= 0 && id < exprCount }
        try s.check(ruleOK(rootRuleID), "Root rule is out of range")
        var next = 0
        for offset in exprOffsets {
            let start = Int(offset)
            try s.check(start == next && start + 2 <= exprData.count, "Expression offset is out of range")
            let count = Int(exprData[start + 1])
            try s.check(count >= 0 && start + 2 + count <= exprData.count && GrammarExprKind(rawValue: exprData[start]) != nil, "Invalid expression record")
            next = start + 2 + count
        }
        try s.check(next == exprData.count, "Expression arena has unreferenced words")
        var dependencies = [[Int32]](repeating: [], count: exprCount)
        for id in 0 ..< Int32(exprCount) {
            let value = expr(id)
            let count = value.count
            switch value.kind {
            case .byteString: try s.check(value.allSatisfy { $0 >= 0 && $0 <= 255 }, "Literal contains a non-byte")
            case .emptyString: try s.check(count == 0, "Empty expression has a payload")
            case .characterClass, .characterClassStar:
                try s.check(count >= 1 && count % 2 == 1 && (value[0] == 0 || value[0] == 1), "Invalid character class")
                for index in stride(from: 1, to: count, by: 2) {
                    try s.check(value[index] >= 0 && value[index] <= value[index + 1] && value[index + 1] <= 0x10FFFF, "Character range is out of bounds")
                }
            case .ruleRef: try s.check(count == 1 && ruleOK(value[0]), "Rule reference is out of range")
            case .sequence, .choices:
                try s.check(value.allSatisfy(exprOK), "Expression reference is out of range")
                dependencies[Int(id)] = Array(value)
            case .tagDispatch:
                try s.check(count >= 2 && count % 2 == 0, "Invalid tag dispatch")
                for index in stride(from: 0, to: count - 2, by: 2) {
                    try s.check(exprOK(value[index]) && ruleOK(value[index + 1]), "Tag reference is out of range")
                    try s.check(expr(value[index]).kind == .byteString && !expr(value[index]).isEmpty, "Invalid tag trigger")
                }
                try s.check((value[count - 2] == 0 || value[count - 2] == 1) && exprOK(value[count - 1]), "Invalid tag dispatch options")
                let excludes = expr(value[count - 1])
                try s.check(excludes.kind == .choices && excludes.allSatisfy(exprOK), "Invalid tag excludes")
                try s.check(excludes.allSatisfy { expr($0).kind == .byteString && !expr($0).isEmpty }, "Invalid excluded string")
            case .repeat:
                try s.check(count == 3 && ruleOK(value[0]) && value[1] >= 0 && (value[2] == -1 || value[2] >= value[1]), "Invalid repetition")
            case .token, .excludeToken:
                try s.check((value.kind != .token || count > 0) && value.allSatisfy { $0 >= 0 }, "Empty token set or negative token ID")
            case .tokenTagDispatch:
                try s.check(count >= 3 && value[0] >= 0 && 2 * Int(value[0]) + 3 <= count, "Invalid token dispatch")
                let n = Int(value[0])
                for index in 0 ..< n { try s.check(value[1 + 2 * index] >= 0 && ruleOK(value[2 + 2 * index]), "Invalid token dispatch reference") }
                let flag = value[1 + 2 * n], excludes = Int(value[2 + 2 * n])
                try s.check((flag == 0 || flag == 1) && excludes >= 0 && 3 + 2 * n + excludes == count, "Invalid token dispatch options")
                try s.check(value.data.suffix(excludes).allSatisfy { $0 >= 0 }, "Negative excluded token ID")
            case .regex:
                try s.check(count >= 1 && (value[0] == 0 || value[0] == 1) && value.data.dropFirst().allSatisfy { $0 >= 0 && $0 <= 255 }, "Invalid regex payload")
            case .substring:
                var index = 0
                while index < count {
                    let size = Int(value[index]); index += 1
                    try s.check(size >= 0 && size <= count - index, "Invalid substring length")
                    for byte in index ..< index + size { try s.check(value[byte] >= 0 && value[byte] <= 255, "Invalid substring byte") }
                    index += size
                }
            }
        }
        var colors = [UInt8](repeating: 0, count: exprCount)
        for start in 0 ..< exprCount where colors[start] == 0 {
            var stack: [(Int, Bool, Int)] = [(start, false, 0)]
            while let (id, exit, depth) = stack.popLast() {
                if exit { colors[id] = 2; continue }
                try s.check(colors[id] != 1 && depth < 512, "Cyclic or excessively nested expression containers")
                if colors[id] == 2 { continue }
                colors[id] = 1
                stack.append((id, true, depth))
                for child in dependencies[id].reversed() { stack.append((Int(child), false, depth + 1)) }
            }
        }
        try s.check(Set(rules.map(\.name)).count == ruleCount && rules.allSatisfy { !$0.name.isEmpty }, "Duplicate or empty rule name")
        for rule in rules {
            try s.check(exprOK(rule.bodyExprID) && (rule.lookaheadAssertionID == -1 || exprOK(rule.lookaheadAssertionID)), "Rule expression is out of range")
            try s.check(rule.maxTokens >= -1 && rule.maxChars >= -1, "Invalid rule budget")
            func validateSequence(_ value: GrammarExpr) throws(SerializationError) {
                try s.check(value.kind == .sequence, "Alternative must be a sequence")
                try s.check(value.allSatisfy { id in
                    switch expr(id).kind {
                    case .byteString, .characterClass, .characterClassStar, .ruleRef, .repeat, .token, .excludeToken: true
                    default: false
                    }
                }, "Sequence contains an expression that requires normalization")
            }
            let body = expr(rule.bodyExprID)
            switch body.kind {
            case .choices:
                for alternative in body where expr(alternative).kind != .emptyString { try validateSequence(expr(alternative)) }
            case .tagDispatch, .tokenTagDispatch, .regex, .substring: break
            default: throw .format("Rule body requires normalization")
            }
            if rule.lookaheadAssertionID >= 0 { try validateSequence(expr(rule.lookaheadAssertionID)) }
        }
        try s.check(allowEmptyRuleIDs == Array(Set(allowEmptyRuleIDs)).sorted() && allowEmptyRuleIDs.allSatisfy(ruleOK), "Invalid nullable rule IDs")
        try s.check(suffixStopInfos.map(\.ruleID) == Array(Set(suffixStopInfos.map(\.ruleID))).sorted(), "Invalid suffix/stop order")
        for info in suffixStopInfos {
            try s.check(ruleOK(info.ruleID) && (info.bodyRuleID == -1 || ruleOK(info.bodyRuleID)) && (info.markerRuleID == -1 || ruleOK(info.markerRuleID))
                        && info.hiddenStopBytes >= 0 && info.hiddenSuffixBytes >= 0, "Invalid suffix/stop metadata")
        }
        if isOptimized {
            try s.check(completeFSM != nil && perRuleFSMs.count == ruleCount && perRuleFSMs.allSatisfy { $0 != nil }, "Optimized grammar requires one FSM per rule")
        }
        let fsms = [completeFSM].compactMap { $0 } + perRuleFSMs.compactMap { $0?.fsm.fsm }
        for fsm in fsms {
            for edge in fsm.edges {
                if edge.isRuleRef { try s.check(ruleOK(edge.ruleID), "FSM rule reference is out of range") }
                if edge.isRepeatRef { try s.check(ruleOK(fsm.repeatInfo(at: edge.auxIndex).ruleID), "FSM repeat rule is out of range") }
            }
        }
        if isOptimized, let completeFSM {
            try s.check(perRuleFSMs.allSatisfy { $0?.fsm.fsm == completeFSM }, "Per-rule FSM does not share the complete automaton")
        }
    }
}

extension CompactFSM {
    func validateSerializedFSM() throws(SerializationError) {
        let s = SerializationValue.self
        for state in 0 ..< Int32(stateCount) {
            let row = edges(of: state)
            try s.check(zip(row, row.dropFirst()).allSatisfy { $0 <= $1 }, "FSM edges are not sorted")
            for edge in row {
                try s.check(edge.target >= 0 && edge.target < stateCount, "FSM target is out of range")
                if edge.isCharRange { try s.check(edge.min <= edge.max && edge.max <= 255, "Invalid byte range"); continue }
                try s.check(FSMEdgeKind(rawValue: edge.min) != nil, "Unknown FSM edge kind")
                if edge.isRepeatRef {
                    let index = Int(edge.max)
                    try s.check(index >= 0 && index + 3 <= auxData.count && row.count == 1, "Invalid repetition edge")
                    try s.check(auxData[index] >= 0 && auxData[index + 1] >= 0 && (auxData[index + 2] == -1 || auxData[index + 2] >= auxData[index + 1]), "Invalid repetition bounds")
                } else if edge.isToken || edge.isExcludeToken {
                    let index = Int(edge.max)
                    try s.check(index >= 0 && index < auxData.count, "Token auxiliary index is out of range")
                    let count = Int(auxData[index])
                    try s.check(count >= (edge.isToken ? 1 : 0) && index + 1 + count <= auxData.count && auxData[(index + 1) ..< (index + 1 + count)].allSatisfy { $0 >= 0 }, "Invalid token edge")
                } else if edge.isRuleRef { try s.check(edge.max >= 0, "Negative FSM rule reference") }
            }
        }
    }
}
