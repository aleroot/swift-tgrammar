// Port of the BatchGrammarMatcher tests of xgrammar's tests/python/test_grammar_matcher_basic.py:
// batch acceptance, rollback and mask filling over independent matchers.

import Testing

@testable import TGrammar

@Suite("Grammar batch")
struct GrammarBatchTests {
    private static func matchers(_ grammars: [String], vocab: [String]) throws -> [GrammarMatcher] {
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: vocab), cacheEnabled: false)
        return try grammars.map { GrammarMatcher(try compiler.compile(ebnf: $0)) }
    }

    private static func matchers(_ grammar: Grammar, count: Int, vocab: [String]) throws -> [GrammarMatcher] {
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: vocab), cacheEnabled: false)
        let compiled = try compiler.compile(grammar)
        return Array(repeating: GrammarMatcher(compiled), count: count)
    }

    /// Accepts every token in turn; `#expect` cannot call mutating methods itself.
    private static func accepts(_ matcher: inout GrammarMatcher, _ tokens: Int32...) -> Bool {
        tokens.allSatisfy { matcher.acceptToken($0) }
    }

    private static func allows(_ matcher: inout GrammarMatcher, _ token: Int32) -> Bool {
        matcher.nextTokenBitmask()[token]
    }

    static let threeGrammars = [#"root ::= "a""#, "root ::= [0-9]+", #"root ::= "ab""#]

    @Test(arguments: [
        (threeGrammars, ["a", "123", "ab"], [true, true, true]),
        (threeGrammars, ["b", "123a", "d"], [false, false, false]),
        (threeGrammars, ["a", "123a", "ab"], [true, false, true]),
        ([#"root ::= "a""#], ["a"], [true]),
        ([#"root ::= "a""#], ["b"], [false]),
        ([#"root ::= "你好""#, #"root ::= "こんにちは""#, #"root ::= "안녕하세요""#], ["你好", "こんにちは", "안녕하세요"], [true, true, true]),
    ])
    func acceptStrings(_ grammars: [String], _ inputs: [String], _ expected: [Bool]) throws {
        var batch = try Self.matchers(grammars, vocab: [])
        let accepted = GrammarBatch.accept(strings: inputs, for: &batch)
        #expect(accepted == expected)
    }

    @Test(arguments: [
        (threeGrammars, [Int32(2), 5, 2], [true, true, true]),
        (threeGrammars, [3, 2, 4], [false, false, false]),
        (threeGrammars, [2, 8, 9], [true, false, true]),
        ([#"root ::= "a""#], [2], [true]),
        ([#"root ::= "a""#], [3], [false]),
    ])
    func acceptTokens(_ grammars: [String], _ tokens: [Int32], _ expected: [Bool]) throws {
        var batch = try Self.matchers(grammars, vocab: ["<s>", "</s>", "a", "b", "c", "1", "2", "3", "123a", "ab"])
        let accepted = GrammarBatch.accept(tokens: tokens, for: &batch)
        #expect(accepted == expected)
    }

    /// Three matchers roll back 0, 1 and 2 tokens after every pair; re-accepting reproduces the
    /// masks seen before the rollback.
    @Test func rollback() throws {
        let vocab = ["<s>", "</s>", "a", "abc", "b\"", "\"", ":\"", "{", "}", ", ", "6", ":", "\n", " ", "\"a\":true"]
        let ids = ["{", "\"", "abc", "b\"", ":", "6", ", ", " ", "\"a\":true", "}"].map { Int32(vocab.firstIndex(of: $0)!) }
        var batch = try Self.matchers(.builtinJSON, count: 3, vocab: vocab)
        let lengths = [0, 1, 2]
        for pair in stride(from: 0, to: ids.count, by: 2) {
            let first = ids[pair], second = ids[pair + 1]
            var masks: [[TokenBitmask]] = []
            for index in batch.indices {
                let beforeFirst = batch[index].nextTokenBitmask()
                let acceptedFirst = batch[index].acceptToken(first)
                let beforeSecond = batch[index].nextTokenBitmask()
                let acceptedSecond = batch[index].acceptToken(second)
                #expect(acceptedFirst && acceptedSecond)
                masks.append([beforeFirst, beforeSecond, batch[index].nextTokenBitmask()])
            }
            GrammarBatch.rollback(lengths, for: &batch)
            for (index, length) in lengths.enumerated() {
                var observed = [batch[index].nextTokenBitmask()]
                if length == 2 {
                    #expect(Self.accepts(&batch[index], first))
                    observed.append(batch[index].nextTokenBitmask())
                }
                if length >= 1 {
                    #expect(Self.accepts(&batch[index], second))
                    observed.append(batch[index].nextTokenBitmask())
                }
                #expect(observed == Array(masks[index][(2 - length)...]))
            }
        }
    }

    @Test func rollbackSingleMatcher() throws {
        var batch = try Self.matchers([#"root ::= "a" "b""#], vocab: ["<s>", "</s>", "a", "b"])
        #expect(Self.accepts(&batch[0], 2, 3))
        GrammarBatch.rollback([2], for: &batch)
        let allowed = batch[0].nextTokenBitmask().allowedTokenIDs
        #expect(allowed == [2])
        #expect(Self.accepts(&batch[0], 2, 3))
    }

    @Test func rollbackZeroAndMixed() throws {
        var batch = try Self.matchers(try Grammar(ebnf: #"root ::= "a" "b""#), count: 2, vocab: ["<s>", "</s>", "a", "b", "c"])
        #expect(Self.accepts(&batch[0], 2, 3) && Self.accepts(&batch[1], 2))
        GrammarBatch.rollback([1, 0], for: &batch)
        #expect(Self.allows(&batch[0], 3) && Self.allows(&batch[1], 3))
        #expect(Self.accepts(&batch[0], 3) && Self.accepts(&batch[1], 3))
    }

    @Test func emptyBatches() {
        var batch: [GrammarMatcher] = []
        GrammarBatch.rollback([], for: &batch)
        let accepted = GrammarBatch.accept(tokens: [], for: &batch)
        let filled = GrammarBatch.fillNextTokenMasks(for: &batch)
        #expect(accepted.isEmpty && filled.rows.isEmpty)
    }

    @Test func mismatchedSizesTrap() async {
        await #expect(processExitsWith: .failure) {
            var batch = try Self.matchers(try Grammar(ebnf: #"root ::= "a""#), count: 2, vocab: ["<s>", "a"])
            GrammarBatch.rollback([1], for: &batch)
        }
        await #expect(processExitsWith: .failure) {
            var batch = try Self.matchers(try Grammar(ebnf: #"root ::= "a""#), count: 2, vocab: ["<s>", "a"])
            _ = GrammarBatch.accept(tokens: [1, 1, 1], for: &batch)
        }
    }

    /// Batch masks equal each matcher's own mask, before and after a batch acceptance.
    @Test(arguments: [1, 2])
    func fillNextTokenMasks(maxThreads: Int) throws {
        let vocab = ["ab", "</s>", "a", "b", "c", "1", "2", "3", "123a"]
        var batch = try Self.matchers(Self.threeGrammars + ["root ::= [a-z0-9]+"], vocab: vocab)
        let expected: [[[Int32]]] = [
            [[2], [5, 6, 7], [0, 2], [0, 2, 3, 4, 5, 6, 7, 8]],
            [[1], [1, 5, 6, 7], [3], [0, 1, 2, 3, 4, 5, 6, 7, 8]],
        ]
        for step in expected.indices {
            let result = GrammarBatch.fillNextTokenMasks(for: &batch, maxThreads: maxThreads)
            for row in batch.indices {
                let own = batch[row].nextTokenBitmask()
                #expect(result.masks[row].allowedTokenIDs == expected[step][row], "step \(step) row \(row)")
                #expect(result.masks[row] == own)
            }
            if step == 0 {
                let accepted = GrammarBatch.accept(strings: ["a", "1", "a", "123a"], for: &batch)
                #expect(accepted == [true, true, true, true])
            }
        }
    }
}
