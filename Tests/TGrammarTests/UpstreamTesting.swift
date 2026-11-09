// Swift counterparts of the helpers in upstream's `python/xgrammar/testing.py`.

import Foundation
import Testing

@testable import TGrammar

extension JSONSchemaOptions {
    /// XGrammar's defaults (`any_whitespace=True`), which ported upstream tests assume.
    static let xgrammar = JSONSchemaOptions(anyWhitespace: true)
}

enum Upstream {
    static let emptyTokenizer = try! TokenizerInfo(encodedVocab: [String]())

    #if DEBUG
    private static let isReleaseBuild = false
    #else
    private static let isReleaseBuild = true
    #endif

    /// Upstream's pressure and timing tests over real vocabularies take minutes in an unoptimized
    /// build; they run with `swift test -c release` or with `TGRAMMAR_PRESSURE=1`.
    static let runsPressureTests = isReleaseBuild || ProcessInfo.processInfo.environment["TGRAMMAR_PRESSURE"] != nil
    static let pressureTestsSkipReason: Comment = "Pressure tests run in release builds (`swift test -c release`) or with TGRAMMAR_PRESSURE=1"

    /// `_get_matcher_from_grammar`: a string-only matcher over an empty vocabulary.
    static func matcher(_ grammar: Grammar) throws -> GrammarMatcher {
        let compiler = GrammarCompiler(tokenizerInfo: emptyTokenizer, cacheEnabled: false)
        return GrammarMatcher(try compiler.compile(grammar), terminateWithoutStopToken: true)
    }

    /// `_is_grammar_accept_string`.
    static func accepts(_ grammar: Grammar, _ input: String, requireTermination: Bool = true) throws -> Bool {
        var matcher = try matcher(grammar)
        guard matcher.acceptString(input) else { return false }
        return !requireTermination || matcher.isTerminated
    }

    static func accepts(ebnf: String, _ input: String, requireTermination: Bool = true) throws -> Bool {
        try accepts(try Grammar(ebnf: ebnf), input, requireTermination: requireTermination)
    }

    /// `_get_matcher_from_grammar_and_tokenizer_info`.
    static func matcher(_ grammar: Grammar, _ tokenizerInfo: TokenizerInfo, stopTokenIDs: [Int32]? = nil, terminateWithoutStopToken: Bool = false) throws -> GrammarMatcher {
        let compiler = GrammarCompiler(tokenizerInfo: tokenizerInfo, cacheEnabled: false)
        return GrammarMatcher(try compiler.compile(grammar), stopTokenIDs: stopTokenIDs, terminateWithoutStopToken: terminateWithoutStopToken)
    }

    /// Fills a mask and accepts every byte of `input` in turn, checking that each byte is
    /// accepted, then fills the final mask. Returns the rejected-token counts after each fill
    /// (`len(_get_masked_tokens_from_bitmask(...))` per step).
    @discardableResult
    static func rejectedCounts(_ matcher: inout GrammarMatcher, bytes input: some Sequence<UInt8>, sourceLocation: SourceLocation = #_sourceLocation) -> [Int] {
        var mask = TokenBitmask(vocabSize: matcher.compiledGrammar.tokenizerInfo.vocabSize)
        var counts: [Int] = []
        for byte in input {
            matcher.fillNextTokenBitmask(&mask)
            counts.append(mask.rejectedCount)
            let accepted = matcher.acceptBytes([byte])
            #expect(accepted, "byte \(byte) (\(String(decoding: [byte], as: UTF8.self)))", sourceLocation: sourceLocation)
            if !accepted { break }
        }
        matcher.fillNextTokenBitmask(&mask)
        counts.append(mask.rejectedCount)
        return counts
    }
}
