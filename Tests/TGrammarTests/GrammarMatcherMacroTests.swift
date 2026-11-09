// Port of xgrammar's tests/python/test_grammar_matcher_macro.py: TagDispatch acceptance, stop
// strings, excludes and token-mask generation.

import Testing

@testable import TGrammar

@Suite("Grammar matcher (TagDispatch macro)")
struct GrammarMatcherMacroTests {
    @Test func simple() throws {
        let grammar = try Grammar(ebnf: """
            root ::= TagDispatch(("tag1", rule1), ("tag2", rule2))
            rule1 ::= "abcd"
            rule2 ::= "efg"
            """)
        #expect(try Upstream.accepts(grammar, "tag1abcd"))
        #expect(try Upstream.accepts(grammar, "tag1abcdtag2efg"))
        #expect(try Upstream.accepts(grammar, "tag1abcdqqqqtag2efg"))
        #expect(try !Upstream.accepts(grammar, "tag1abc"))
        #expect(try !Upstream.accepts(grammar, "tag1abce"))
        #expect(try !Upstream.accepts(grammar, "ttag1abd"))
    }

    @Test func complexRule() throws {
        let grammar = try Grammar(ebnf: """
            root ::= TagDispatch(("tag1", rule1), ("tag2", rule2))
            rule1 ::= "abcd" [p]*
            rule2 ::= "efg" [t]*
            """)
        #expect(try Upstream.accepts(grammar, "tag1abcd"))
        #expect(try Upstream.accepts(grammar, "tag1abcdppppptag2efg"))
        #expect(try Upstream.accepts(grammar, "tag2efgtttttag1abc"))
        #expect(try !Upstream.accepts(grammar, "tag1efg"))
    }

    @Test func noLoopAfterDispatch() throws {
        let grammar = try Grammar(ebnf: """
            root ::= TagDispatch(("tag1", rule1), ("tag2", rule2), loop_after_dispatch=false)
            rule1 ::= "abcd" [p]*
            rule2 ::= "efg" [t]*
            """)
        #expect(try Upstream.accepts(grammar, "tag1abcd"))
        #expect(try Upstream.accepts(grammar, "tag2efgttt"))
        #expect(try !Upstream.accepts(grammar, "tag1abcdppppptag2"))
        #expect(try !Upstream.accepts(grammar, "tag2efgtag1"))
    }

    @Test func stopString() throws {
        let grammar = try Grammar(ebnf: """
            root ::= root1 stop "w"
            root1 ::= TagDispatch(
              ("tag1", rule1),
              ("tag2", rule2),
              excludes=("tag3", "ll")
            )
            stop ::= "tag3" | "ll"
            rule1 ::= "abcd" [p]*
            rule2 ::= "efg" [t]*
            """)
        #expect(try Upstream.accepts(grammar, "tag1abcdllw"))
        #expect(try Upstream.accepts(grammar, "tag1abcdtag3w"))
        #expect(try Upstream.accepts(grammar, "tag1abcdqqqtag2efgtag3w"))
        #expect(try Upstream.accepts(grammar, "tag1abcd", requireTermination: false))
        #expect(try Upstream.accepts(grammar, "tag2efgttt", requireTermination: false))
        #expect(try !Upstream.accepts(grammar, "tag1abcd"))
        #expect(try !Upstream.accepts(grammar, "tag2efgttt"))
        #expect(try !Upstream.accepts(grammar, "tag1abce"))
        #expect(try !Upstream.accepts(grammar, "tag1abcdlltag3w", requireTermination: false))
    }

    @Test func stopStringNoLoop() throws {
        let grammar = try Grammar(ebnf: """
            root ::= root1 stop "w"
            root1 ::= TagDispatch(
              ("tag1", rule1),
              ("tag2", rule2),
              excludes=("tag3", "ll"),
              loop_after_dispatch=false
            )
            stop ::= "tag3" | "ll"
            rule1 ::= "abcd" [p]*
            rule2 ::= "efg" [t]*
            """)
        #expect(try Upstream.accepts(grammar, "tag1abcdllw"))
        #expect(try Upstream.accepts(grammar, "tag1abcdtag3w"))
        #expect(try Upstream.accepts(grammar, "tag1abcd", requireTermination: false))
        #expect(try Upstream.accepts(grammar, "tag2efgttt", requireTermination: false))
        #expect(try !Upstream.accepts(grammar, "tag1abcdqqqtag2efgtag3w"))
        #expect(try !Upstream.accepts(grammar, "tag1abcd"))
        #expect(try !Upstream.accepts(grammar, "tag2efgttt"))
        #expect(try !Upstream.accepts(grammar, "tag1abce"))
        #expect(try !Upstream.accepts(grammar, "tag1abcdlltag3w", requireTermination: false))
    }

    @Test func tagDispatchMaskGenerationCorrectness() throws {
        let grammar = try Grammar(ebnf: """
            root ::= TagDispatch(("tag1", rule1), ("tag2", rule2))
            rule1 ::= "abc"
            rule2 ::= "dg"
            """)
        let tokens = ["a", "b", "c", "d", "g", "t", "1", "2", "1a", "2d", "2a", "2dgt",
                      "2dgtag1a", "2dgtag1b", "tag1a", "tag1b", "c哈哈t", "q", "abcdef"]
        let input = "tag1abcqqtag2dgq"
        let free = ["a", "b", "c", "d", "g", "t", "1", "2", "1a", "2d", "2a", "2dgt", "2dgtag1a", "tag1a", "c哈哈t", "q", "abcdef"]
        let afterTag = ["a", "b", "c", "d", "g", "t", "1", "2", "1a", "2d", "2dgt", "2dgtag1a", "tag1a", "c哈哈t", "q", "abcdef"]
        let expected: [[String]] = [
            free, free, free, afterTag,
            ["a", "abcdef"], ["b"], ["c哈哈t", "c"],
            free, free, free, free, free, afterTag,
            ["d"], ["g"],
            free, free,
        ]

        let tokenizerInfo = try TokenizerInfo(encodedVocab: tokens)
        let compiler = GrammarCompiler(tokenizerInfo: tokenizerInfo, maxThreads: 1)
        var matcher = GrammarMatcher(try compiler.compile(grammar), terminateWithoutStopToken: true)
        var mask = TokenBitmask(vocabSize: tokenizerInfo.vocabSize)

        // A dummy trailing character checks the final bitmask after accepting the input.
        for (index, character) in (input + "0").enumerated() {
            matcher.fillNextTokenBitmask(&mask)
            let accepted = mask.allowedTokenIDs.map { tokens[Int($0)] }
            if index < input.count {
                let ok = matcher.acceptString(String(character))
                #expect(ok, "step \(index)")
            }
            #expect(Set(accepted) == Set(expected[index]), "step \(index)")
        }
    }

    @Test func regressionMultipleTagDispatch() throws {
        let ebnf = """
            root ::= root1 "w"
            root1 ::= TagDispatch(
              ("tag1", rule1),
              ("tag2", rule2),
              loop_after_dispatch=false
            )
            rule1 ::= rule1_dispatch rule1_stop
            rule1_dispatch ::= TagDispatch(
              ("tag1", rule2),
              ("tag2", rule3),
              excludes=("tag3", "ll"),
              loop_after_dispatch=true
            )
            rule1_stop ::= "tag3" | "ll"
            rule2 ::= "efg" [t]*
            rule3 ::= "abcd" [p]*
            """
        #expect(try Upstream.accepts(ebnf: ebnf, "tag1tag1efgllw"))
        #expect(try Upstream.accepts(ebnf: ebnf, "tag1tag2abcdtag3w"))
        #expect(try !Upstream.accepts(ebnf: ebnf, "tag1Ktag2abcdtag3tag1"))
        #expect(try Upstream.accepts(ebnf: ebnf, "tag1tag3w"))
        #expect(try !Upstream.accepts(ebnf: ebnf, "tag1tag3tag2abcdll"))
    }

    @Test func excludedString() throws {
        let grammar = try Grammar(ebnf: """
            root ::= root_dispatch end_tag
            root_dispatch ::= TagDispatch(
              ("start", rule1),
              excludes=("</think>", "</conclude>"),
              loop_after_dispatch=true
            )
            rule1 ::= "12345"
            end_tag ::= "</think>"
            """)
        #expect(grammar.description.contains(#"excludes=("</think>", "</conclude>")"#))
        #expect(try Upstream.accepts(grammar, "start12345</think>"))
        #expect(try !Upstream.accepts(grammar, "start12345</conclude>"))
        #expect(try Upstream.accepts(grammar, "start12345abc</think>"))
        #expect(try !Upstream.accepts(grammar, "start12345</conclude>abc"))
    }
}
