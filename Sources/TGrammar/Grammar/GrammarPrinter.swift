// Prints a grammar back to the EBNF dialect. The output is normalized, stable and re-parseable,
// and the test corpus compares it character for character.

struct GrammarPrinter {
    let storage: GrammarStorage

    init(_ storage: GrammarStorage) { self.storage = storage }

    func printGrammar() -> String {
        var output = ""
        for ruleID in 0 ..< storage.ruleCount {
            printRule(Int32(ruleID), into: &output)
            output += "\n"
        }
        return output
    }

    func printRule(_ ruleID: Int32, into output: inout String) {
        let rule = storage.rule(ruleID)
        let suffixStop = storage.suffixStopInfo(for: ruleID)
        output += rule.name
        printAttributes(of: rule, suffixStop: suffixStop, into: &output)
        output += " ::= "
        printExpr(rule.bodyExprID, into: &output)
        if rule.lookaheadAssertionID != -1 {
            output += " (="
            printExpr(rule.lookaheadAssertionID, into: &output)
            output += ")"
        }
    }

    private func printAttributes(of rule: GrammarRule, suffixStop: SuffixStopInfo?, into output: inout String) {
        var attributes: [String] = []
        if rule.maxTokens >= 0 { attributes.append("max_tokens=\(rule.maxTokens)") }
        if rule.maxChars >= 0 { attributes.append("max_chars=\(rule.maxChars)") }
        if !rule.captureName.isEmpty { attributes.append("capture=\"\(rule.captureName)\"") }
        if let suffixStop {
            if suffixStop.hiddenSuffixBytes > 0 {
                attributes.append("capture_hidden_suffix_bytes=\(suffixStop.hiddenSuffixBytes)")
            }
            if suffixStop.hiddenStopBytes > 0 {
                attributes.append("capture_hidden_stop_bytes=\(suffixStop.hiddenStopBytes)")
            }
            if suffixStop.bodyRuleID >= 0 {
                attributes.append("capture_hidden_body_rule_id=\(suffixStop.bodyRuleID)")
                attributes.append("capture_hidden_marker_rule_id=\(suffixStop.markerRuleID)")
            }
            if !suffixStop.stopCaptureName.isEmpty {
                attributes.append("stop_capture=\"\(suffixStop.stopCaptureName)\"")
            }
        }
        if rule.isLazy { attributes.append("lazy") }
        if let temperature = rule.temperature { attributes.append("temperature=\(temperature)") }
        if attributes.isEmpty { return }
        output += "["
        output += attributes.joined(separator: ", ")
        output += "]"
    }

    func printExpr(_ exprID: Int32, into output: inout String) {
        printExpr(storage.expr(exprID), into: &output)
    }

    func printExpr(_ expr: GrammarExpr, into output: inout String) {
        switch expr.kind {
        case .byteString:
            printString(storage.byteString(expr), into: &output)
        case .characterClass:
            printCharacterClass(expr, into: &output)
        case .characterClassStar:
            printCharacterClass(expr, into: &output)
            output += "*"
        case .emptyString:
            output += "\"\""
        case .ruleRef:
            output += storage.rule(expr[0]).name
        case .sequence:
            output += "("
            for (index, child) in expr.enumerated() {
                if index > 0 { output += " " }
                printExpr(child, into: &output)
            }
            output += ")"
        case .choices:
            output += "("
            for (index, child) in expr.enumerated() {
                if index > 0 { output += " | " }
                printExpr(child, into: &output)
            }
            output += ")"
        case .tagDispatch:
            printTagDispatch(storage.tagDispatch(expr), into: &output)
        case .repeat:
            output += storage.rule(expr[0]).name
            output += "{\(expr[1]), \(expr[2])}"
        case .token:
            output += "Token("
            printIntegerList(expr, into: &output)
            output += ")"
        case .excludeToken:
            output += "ExcludeToken("
            printIntegerList(expr, into: &output)
            output += ")"
        case .tokenTagDispatch:
            printTokenTagDispatch(storage.tokenTagDispatch(expr), into: &output)
        case .regex:
            output += "Regex("
            printString(storage.regexPattern(expr), into: &output)
            if storage.regexIsJSONString(expr) { output += ", json_string=true" }
            output += ")"
        case .substring:
            output += "Substring("
            for (index, chunk) in storage.substringChunks(expr).enumerated() {
                if index > 0 { output += ", " }
                printString(chunk, into: &output)
            }
            output += ")"
        }
    }

    /// The byte string of a rule body or tag, escaped per code point. Stray bytes are kept
    /// re-parseable as `\xHH` escapes.
    private func printString(_ bytes: [UInt8], into output: inout String) {
        output += "\""
        bytes.withUnsafeBufferPointer { EscapeCodec.escape(bytes: $0, into: &output) }
        output += "\""
    }

    private func printIntegerList(_ expr: GrammarExpr, into output: inout String) {
        for (index, value) in expr.enumerated() {
            if index > 0 { output += ", " }
            output += String(value)
        }
    }

    private func printCharacterClass(_ expr: GrammarExpr, into output: inout String) {
        output += "["
        if expr[0] != 0 { output += "^" }
        var index = 1
        while index < expr.count {
            let lower = expr[index]
            let upper = expr[index &+ 1]
            EscapeCodec.escape(lower, into: &output, custom: Self.characterClassEscape)
            if lower != upper {
                output += "-"
                EscapeCodec.escape(upper, into: &output, custom: Self.characterClassEscape)
            }
            index += 2
        }
        output += "]"
    }

    private static func characterClassEscape(_ codepoint: Codepoint) -> String? {
        switch codepoint {
        case 0x2D: "\\-"
        case 0x5D: "\\]"
        default: nil
        }
    }

    private func printTagDispatch(_ dispatch: TagDispatch, into output: inout String) {
        output += "TagDispatch(\n"
        for pair in dispatch.tagRulePairs {
            output += "  ("
            printString(pair.tag, into: &output)
            output += ", \(storage.rule(pair.ruleID).name)),\n"
        }
        output += "  loop_after_dispatch=\(dispatch.loopAfterDispatch ? "true" : "false"),\n"
        output += "  excludes=("
        for (index, exclude) in dispatch.excludes.enumerated() {
            if index > 0 { output += ", " }
            printString(exclude, into: &output)
        }
        output += ")\n)"
    }

    private func printTokenTagDispatch(_ dispatch: TokenTagDispatch, into output: inout String) {
        output += "TokenTagDispatch(\n"
        for pair in dispatch.triggerRulePairs {
            output += "  (\(pair.tokenID), \(storage.rule(pair.ruleID).name)),\n"
        }
        output += "  loop_after_dispatch=\(dispatch.loopAfterDispatch ? "true" : "false"),\n"
        output += "  excludes=("
        output += dispatch.excludes.map(String.init).joined(separator: ", ")
        output += ")\n)"
    }
}
