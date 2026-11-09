// Port of the automaton-layout parts of xgrammar's tests/python/test_grammar_fsm_builder.py:
// the exact per-rule FSM layout produced by the optimizer pipeline (state numbers, edge order,
// endpoints) is pinned so that any change to the construction paths is detected. The matcher
// behaviour tests of that file live with the matcher tests.

import Testing

@testable import TGrammar

@Suite("Grammar FSM builder")
struct GrammarFSMBuilderTests {
    private func compiledFSMs(_ ebnf: String) throws -> String {
        GrammarTesting.printGrammarFSMs(try GrammarTesting.optimize(try Grammar(ebnf: ebnf)))
    }

    @Test func nestedExpressionsWithoutNormalization() throws {
        let grammar = try GrammarTesting.fsmBuilder(try GrammarTesting.parseWithoutNormalization(
            "root ::= ((\"a\" | \"bb\") (\"c\" | (\"d\" (\"e\" | \"f\")))) | (Regex(\"[0-9]+\") \"z\")\n"
        ))
        for accepted in ["ac", "bbc", "ade", "adf", "bbde", "bbdf", "0z", "123z"] {
            #expect(GrammarTesting.isRuleFSMAccepting(grammar, ruleID: 0, accepted), "\(accepted)")
        }
        for rejected in ["", "a", "bc", "ad", "z", "12", "1zz", "ace"] {
            #expect(!GrammarTesting.isRuleFSMAccepting(grammar, ruleID: 0, rejected), "\(rejected)")
        }
    }

    @Test(arguments: [
        "root ::= \"a\" TagDispatch((\"tag\", body), loop_after_dispatch=false) \"z\"\nbody ::= \"b\"\n",
        "root ::= Token(2) TokenTagDispatch((3, body), excludes=(5,)) Token(6)\nbody ::= Token(4)\n",
    ])
    func nestedDispatchWithoutNormalization(_ ebnf: String) throws {
        let grammar = try GrammarTesting.fsmBuilder(try GrammarTesting.parseWithoutNormalization(ebnf))
        #expect(!GrammarTesting.printGrammarFSMs(grammar).contains("None"))
    }

    @Test(arguments: [
        (
            "root ::= \"a\" [0-9] \"b\"",
            """
            Rule 0: root, FSM: CompactFSM(num_states=4, start=2, end=[3], edges=[
            0: [[0-9]->1]
            1: ['b'->3]
            2: ['a'->0]
            3: []
            ])

            """
        ),
        (
            "root ::= \"hello\" [a-zA-Z_] [0-9]* \"world\"",
            """
            Rule 0: root, FSM: CompactFSM(num_states=12, start=2, end=[11], edges=[
            0: [[A-Z]->1, '_'->1, [a-z]->1]
            1: [[0-9]->1, 'w'->7]
            2: ['h'->3]
            3: ['e'->4]
            4: ['l'->5]
            5: ['l'->6]
            6: ['o'->0]
            7: ['o'->8]
            8: ['r'->9]
            9: ['l'->10]
            10: ['d'->11]
            11: []
            ])

            """
        ),
        (
            "root ::= \"<\" [a-c]* \">\"",
            """
            Rule 0: root, FSM: CompactFSM(num_states=3, start=1, end=[2], edges=[
            0: ['>'->2, [a-c]->0]
            1: ['<'->0]
            2: []
            ])

            """
        ),
        (
            "root ::= \"x\" [^0-9] \"y\" [^a-z]* \"z\"",
            #"""
            Rule 0: root, FSM: CompactFSM(num_states=17, start=7, end=[16], edges=[
            0: [[\x80-\xbf]->2]
            1: [[\x80-\xbf]->3]
            2: [[\x80-\xbf]->5]
            3: [[\x80-\xbf]->6]
            4: [[\0-/]->5, [:-\x7f]->5, [\xc2-\xdf]->2, '\xe0'->8, [\xe1-\xef]->0, '\xf0'->9, [\xf1-\xf3]->11, '\xf4'->10]
            5: ['y'->6]
            6: [[\0-`]->6, 'z'->16, [{-\x7f]->6, [\xc2-\xdf]->3, '\xe0'->12, [\xe1-\xef]->1, '\xf0'->13, [\xf1-\xf3]->15, '\xf4'->14]
            7: ['x'->4]
            8: [[\xa0-\xbf]->2]
            9: [[\x90-\xbf]->0]
            10: [[\x80-\x8f]->0]
            11: [[\x80-\xbf]->0]
            12: [[\xa0-\xbf]->3]
            13: [[\x90-\xbf]->1]
            14: [[\x80-\x8f]->1]
            15: [[\x80-\xbf]->1]
            16: []
            ])

            """#
        ),
        (
            "root ::= \"(\" inner \")\" inner\ninner ::= [0-9] [0-9]",
            """
            Rule 0: root, FSM: CompactFSM(num_states=8, start=3, end=[4], edges=[
            0: [Rule(1)->1]
            1: [')'->2]
            2: [Rule(1)->4]
            3: ['('->0]
            4: []
            ])
            Rule 1: inner, FSM: CompactFSM(num_states=8, start=6, end=[7], edges=[
            5: [[0-9]->7]
            6: [[0-9]->5]
            7: []
            ])

            """
        ),
        (
            "root ::= \"a\" item{2,5} \"b\"\nitem ::= [0-9]",
            """
            Rule 0: root, FSM: CompactFSM(num_states=16, start=2, end=[3], edges=[
            0: [Rule(4)->1]
            1: ['b'->3]
            2: ['a'->0]
            3: []
            ])
            Rule 1: root_1, FSM: CompactFSM(num_states=16, start=4, end=[4, 6], edges=[
            4: [[0-9]->5]
            5: [Rule(2)->6]
            6: []
            ])
            Rule 2: root_2, FSM: CompactFSM(num_states=16, start=7, end=[7, 9], edges=[
            7: [[0-9]->8]
            8: [Rule(3)->9]
            9: []
            ])
            Rule 3: root_3, FSM: CompactFSM(num_states=16, start=10, end=[10, 11], edges=[
            10: [[0-9]->11]
            11: []
            ])
            Rule 4: root_4, FSM: CompactFSM(num_states=16, start=14, end=[15], edges=[
            12: [[0-9]->13]
            13: [Rule(1)->15]
            14: [[0-9]->12]
            15: []
            ])

            """
        ),
        (
            "root ::= item{3,}\nitem ::= \"ab\" [xy]",
            """
            Rule 0: root, FSM: CompactFSM(num_states=14, start=0, end=[1], edges=[
            0: [Rule(3)->1]
            1: []
            ])
            Rule 1: item, FSM: CompactFSM(num_states=14, start=3, end=[5], edges=[
            2: ['x'->5, 'y'->5]
            3: ['a'->4]
            4: ['b'->2]
            5: []
            ])
            Rule 2: root_1, FSM: CompactFSM(num_states=14, start=6, end=[6, 8], edges=[
            6: [Rule(1)->7]
            7: [Rule(2)->8]
            8: []
            ])
            Rule 3: root_2, FSM: CompactFSM(num_states=14, start=12, end=[13], edges=[
            9: [Rule(1)->10]
            10: [Rule(1)->11]
            11: [Rule(2)->13]
            12: [Rule(1)->9]
            13: []
            ])

            """
        ),
        (
            "root ::= \"ab\" [0-9] | \"cd\" sub | sub sub\nsub ::= [a-f] \"q\"",
            """
            Rule 0: root, FSM: CompactFSM(num_states=10, start=2, end=[1], edges=[
            0: [Rule(1)->1]
            1: []
            2: ['a'->5, [a-f]->4, 'c'->6]
            3: [[0-9]->1]
            4: ['q'->0]
            5: ['b'->3]
            6: ['d'->0]
            ])
            Rule 1: sub, FSM: CompactFSM(num_states=10, start=8, end=[9], edges=[
            7: ['q'->9]
            8: [[a-f]->7]
            9: []
            ])

            """
        ),
        (
            "root ::= \"中文\" [\\u4e00-\\u9fff] \"端\"",
            #"""
            Rule 0: root, FSM: CompactFSM(num_states=14, start=3, end=[13], edges=[
            0: [[\x80-\xbf]->2]
            1: ['\xe4'->9, [\xe5-\xe9]->10]
            2: ['\xe7'->11]
            3: ['\xe4'->4]
            4: ['\xb8'->5]
            5: ['\xad'->6]
            6: ['\xe6'->7]
            7: ['\x96'->8]
            8: ['\x87'->1]
            9: [[\xb8-\xbf]->0]
            10: [[\x80-\xbf]->0]
            11: ['\xab'->12]
            12: ['\xaf'->13]
            13: []
            ])

            """#
        ),
        (
            "root ::= \"only\"",
            """
            Rule 0: root, FSM: CompactFSM(num_states=5, start=0, end=[4], edges=[
            0: ['o'->1]
            1: ['n'->2]
            2: ['l'->3]
            3: ['y'->4]
            4: []
            ])

            """
        ),
        (
            "root ::= [0-9]",
            """
            Rule 0: root, FSM: CompactFSM(num_states=2, start=0, end=[1], edges=[
            0: [[0-9]->1]
            1: []
            ])

            """
        ),
        (
            "root ::= \"\" \"a\" \"\"",
            """
            Rule 0: root, FSM: CompactFSM(num_states=2, start=0, end=[1], edges=[
            0: ['a'->1]
            1: []
            ])

            """
        ),
        (
            "root ::= a b c\na ::= \"x\" [0-9]*\nb ::= a \"y\" | [^xyz]\nc ::= b{1,3} \"end\"",
            #"""
            Rule 0: root, FSM: CompactFSM(num_states=26, start=2, end=[3], edges=[
            0: [Rule(1)->1, [0-9]->0]
            1: [Rule(2)->3]
            2: ['x'->0]
            3: []
            ])
            Rule 1: b, FSM: CompactFSM(num_states=26, start=7, end=[5], edges=[
            4: [[\x80-\xbf]->6]
            5: []
            6: [[\x80-\xbf]->5]
            7: [[\0-w]->5, 'x'->8, [{-\x7f]->5, [\xc2-\xdf]->6, '\xe0'->9, [\xe1-\xef]->4, '\xf0'->10, [\xf1-\xf3]->12, '\xf4'->11]
            8: [[0-9]->8, 'y'->5]
            9: [[\xa0-\xbf]->6]
            10: [[\x90-\xbf]->4]
            11: [[\x80-\x8f]->4]
            12: [[\x80-\xbf]->4]
            ])
            Rule 2: c, FSM: CompactFSM(num_states=26, start=14, end=[17], edges=[
            13: ['e'->15]
            14: [Rule(5)->13]
            15: ['n'->16]
            16: ['d'->17]
            17: []
            ])
            Rule 3: c_1, FSM: CompactFSM(num_states=26, start=18, end=[18, 20], edges=[
            18: [Rule(1)->19]
            19: [Rule(4)->20]
            20: []
            ])
            Rule 4: c_2, FSM: CompactFSM(num_states=26, start=21, end=[21, 22], edges=[
            21: [Rule(1)->22]
            22: []
            ])
            Rule 5: c_3, FSM: CompactFSM(num_states=26, start=24, end=[25], edges=[
            23: [Rule(3)->25]
            24: [Rule(1)->23]
            25: []
            ])

            """#
        ),
    ])
    func compiledFSMStructureStable(_ ebnf: String, _ expected: String) throws {
        #expect(try compiledFSMs(ebnf) == expected)
    }
}
