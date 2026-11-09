// Port of xgrammar's tests/cpp/test_fsm.cc and the automaton parts of test_fsm_builder.cc:
// regex → automaton construction, the regular operators, epsilon simplification, equivalent
// state merging, determinization, minimization and complement.

import Testing

@testable import TGrammar

@Suite("FSM")
struct FSMTests {
    private func build(_ regex: String) throws -> FSMWithStartEnd {
        try RegexFSMBuilder.build(regex)
    }

    /// Whether some edge out of state 0 accepts `byte`.
    private func startAccepts(_ fsm: FSMWithStartEnd, _ character: Character) -> Bool {
        let value = Int32(character.asciiValue!)
        return fsm.fsm.edges(of: 0).contains { $0.isCharRange && $0.min <= value && $0.max >= value }
    }

    // MARK: Building

    @Test func basicBuild() throws {
        var fsm = try build("abcd\\n")
        #expect(fsm.accepts("abcd\n"))

        fsm = try build("[-a-z\\n]")
        for character in "abcd-\n" { #expect(startAccepts(fsm, character)) }

        fsm = try build("[\\d]")
        for character in "1234567890" { #expect(startAccepts(fsm, character)) }

        fsm = try build("[^\\d]")
        for character in "1234567890" { #expect(!startAccepts(fsm, character)) }
        for character in "abz" { #expect(startAccepts(fsm, character)) }

        fsm = try build("你好a")
        #expect(fsm.accepts("你好a"))

        fsm = try build("(())()()")
        #expect(fsm.accepts(""))

        fsm = try build("[abcdabcdxyzxyz]")
        #expect(fsm.accepts("a"))
        #expect(!fsm.accepts("e"))
        #expect(fsm.fsm.edges(of: 0).count == 2)
    }

    @Test func connections() throws {
        var fsm = try build(" [a-zA-Z0-9]--")
        #expect(fsm.accepts(" a--"))

        fsm = try build("aaa|[\\d]")
        #expect(fsm.accepts("aaa"))
        #expect(fsm.accepts("1"))

        fsm = try build("(([\\d]|[\\w])|aaa)")
        #expect(fsm.accepts("aaa"))
        #expect(fsm.accepts("1"))
        #expect(!fsm.accepts("1a"))
    }

    @Test func quantifiers() throws {
        var fsm = try build("1[\\d]+")
        #expect(fsm.accepts("1111"))
        #expect(!fsm.accepts("1"))

        fsm = try build("1[1]*")
        #expect(fsm.accepts("1111"))
        #expect(fsm.accepts("1"))

        fsm = try build("1[\\d]?")
        #expect(!fsm.accepts("1111"))
        #expect(fsm.accepts("1"))
        #expect(fsm.accepts("11"))

        fsm = try build(" * * + ? *")
        #expect(fsm.accepts(" "))
        #expect(fsm.accepts("      "))
    }

    @Test func optionalGroupCannotSkipSuffixAfterInternalLoop() throws {
        let fsm = try build("x([a-]*a)?z")
        for input in ["xz", "xaz", "x--az"] { #expect(fsm.accepts(input)) }
        for input in ["x-z", "x--z", "x-a-z"] { #expect(!fsm.accepts(input)) }
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        for input in ["x-z", "x--z"] {
            var matcher = GrammarMatcher(try compiler.compile(lark: "start: /x([a-]*a)?z/"), terminateWithoutStopToken: true)
            let accepted = matcher.acceptString(input) && matcher.isCompleted
            #expect(!accepted)
        }
    }

    @Test func integrated() throws {
        let fsm = try build("((naive|bbb|[\\d]+)*[\\w])|  +")
        for accepted in ["naive1", "bbbnaive114514W", "    ", "123", "_"] { #expect(fsm.accepts(accepted)) }
        for rejected in ["naive", "bbbbbb", "naive   ", "123 ", "aaa"] { #expect(!fsm.accepts(rejected)) }
    }

    @Test func email() throws {
        let fsm = try build(#"(\w+)(\.\w+)*@(\w+)(\.\w+)+"#)
        for email in ["asnjdaj_19032910@google.com.test", "12393089340190@a.b.c.d.f.e.org.test", "as____________as@abc.me.test", "ooooohhhhh@123456.test", "ajidoa@a.test"] {
            #expect(fsm.accepts(email), "\(email)")
        }
        for email in ["@google.test", "hello@", "hello@.test", "+++asd@b.test", "hello"] {
            #expect(!fsm.accepts(email), "\(email)")
        }
    }

    @Test func time() throws {
        let fsm = try build(#"(\d{1,2}):(\d{2})(:(\d{2}))?"#)
        for value in ["1:34", "23:59", "00:00", "01:02:03", "23:59:59"] { #expect(fsm.accepts(value), "\(value)") }
        for value in ["19", "12:6", "12:34:", "12:34:5", "12:34:567", "12:123", "12:", ":34:23", "::"] { #expect(!fsm.accepts(value), "\(value)") }
    }

    @Test func boundedRepetitions() throws {
        var fsm = try build("[\\d]{1,5}")
        #expect(fsm.accepts("123"))
        #expect(fsm.accepts("12345"))
        #expect(!fsm.accepts("123456"))
        #expect(!fsm.accepts("1234567"))

        fsm = try build("[\\d]{6}")
        #expect(fsm.accepts("123456"))
        #expect(!fsm.accepts("1234567"))

        fsm = try build("[\\d]{6, }")
        #expect(fsm.accepts("123456"))
        #expect(fsm.accepts("1234567"))
    }

    // MARK: Compact round trip

    @Test func compactRoundTrip() throws {
        let fsm = try build("[\\d\\d\\d]+123")
        #expect(fsm.accepts("123456123"))
        let compact = CompactFSMWithStartEnd(fsm: fsm.fsm.compacted(), start: fsm.start, ends: fsm.ends)
        #expect(compact.accepts("123456123"))
        #expect(compact.expanded().accepts("123456123"))
    }

    // MARK: Determinization, minimization, complement

    @Test func determinizeMinimizeComplement() throws {
        var fsm = try build("([abc]|[\\d])+")
        #expect(fsm.accepts("abc3"))
        fsm = try fsm.determinized()
        #expect(fsm.accepts("abc3"))
        for state in 0 ..< Int32(fsm.stateCount) {
            var seen = Set<Int32>()
            for edge in fsm.fsm.edges(of: state) {
                #expect(!edge.isEpsilon)
                for value in edge.min ... edge.max { #expect(seen.insert(value).inserted) }
            }
        }
        fsm = try fsm.minimized()
        #expect(fsm.accepts("abc3"))
        #expect(fsm.stateCount == 2)

        fsm = try fsm.complement()
        #expect(!fsm.accepts("abc3"))
        #expect(fsm.accepts("abcd"))
    }

    @Test func determinizationBoundsSubsetStates() throws {
        var fsm = FSM(stateCount: 7)
        fsm.addEdge(from: 0, to: 0, min: 97, max: 98)
        fsm.addEdge(from: 0, to: 1, min: 97, max: 97)
        for state in Int32(1) ..< 6 { fsm.addEdge(from: state, to: state + 1, min: 97, max: 98) }
        let nfa = FSMWithStartEnd(fsm: fsm, start: 0, ends: [6])
        #expect(throws: GrammarError.self) { try nfa.determinized(maxStates: 16) }
        let dfa = try nfa.determinized(maxStates: 64)
        #expect(dfa.stateCount == 64)
        #expect(dfa.accepts("abbbbb"))
        #expect(!dfa.accepts("bbbbbb"))
        #expect(!dfa.accepts("abbbb"))
    }

    // MARK: Intersection

    @Test func intersection() throws {
        let left = try build("[c-f]+")
        let right = try build("[d-h]*")
        let fsm = try FSMWithStartEnd.intersect(left, right)
        #expect(fsm.accepts("de"))
        #expect(fsm.accepts("def"))
        #expect(!fsm.accepts(""))
        #expect(!fsm.accepts("cd"))
    }

    @Test func intersectionUsesConfiguredStateLimit() throws {
        let bounded = try build("a{1001}")
        let repeated = try build("a*")
        let intersection = try FSMWithStartEnd.intersect(bounded, repeated, maxStates: 4096)
        #expect(intersection.accepts(String(repeating: "a", count: 1001)))
        #expect(!intersection.accepts(String(repeating: "a", count: 1000)))
        #expect(throws: GrammarError.self) { try FSMWithStartEnd.intersect(bounded, repeated, maxStates: 1000) }
    }

    @Test func intersectionBoundsProductStates() throws {
        var pairs = FSM(stateCount: 2)
        var triples = FSM(stateCount: 3)
        for state in Int32(0) ..< 2 { pairs.addEdge(from: state, to: (state + 1) % 2, min: 97, max: 97) }
        for state in Int32(0) ..< 3 { triples.addEdge(from: state, to: (state + 1) % 3, min: 97, max: 97) }
        let lhs = FSMWithStartEnd(fsm: pairs, start: 0, ends: [0])
        let rhs = FSMWithStartEnd(fsm: triples, start: 0, ends: [0])
        #expect(throws: GrammarError.self) { try FSMWithStartEnd.intersect(lhs, rhs, maxStates: 4) }
        let intersection = try FSMWithStartEnd.intersect(lhs, rhs, maxStates: 6)
        #expect(intersection.accepts("aaaaaa"))
        #expect(!intersection.accepts("aaaaa"))
    }

    // MARK: Reducers

    @Test func simplifyEpsilonAndMerge() throws {
        var fsm = try build("[a][b][c][d]")
        #expect(fsm.accepts("abcd"))
        fsm = fsm.simplifyingEpsilon()
        #expect(fsm.stateCount == 5)
        #expect(fsm.accepts("abcd"))

        fsm = try build("abc|abd")
        fsm = fsm.simplifyingEpsilon().mergingEquivalentStates()
        #expect(fsm.accepts("abc"))
        #expect(!fsm.accepts("abcd"))
        #expect(fsm.stateCount == 4)

        fsm = try build("acd|bcd")
        fsm = fsm.simplifyingEpsilon().mergingEquivalentStates()
        #expect(fsm.accepts("acd"))
        #expect(!fsm.accepts("abcd"))
        #expect(fsm.stateCount == 4)

        fsm = try build("ab*")
        fsm = fsm.simplifyingEpsilon()
        #expect(fsm.accepts("abbb"))
        #expect(fsm.stateCount == 2)
    }

    @Test func mergeEquivalentStatesKeepsStartStateSeparate() {
        var fsm = FSM(stateCount: 4)
        fsm.addEdge(from: 0, to: 0, min: 97, max: 122)
        fsm.addEdge(from: 0, to: 1, min: 97, max: 122)
        fsm.addEdge(from: 1, to: 2, min: 99, max: 99)
        fsm.addEdge(from: 2, to: 3, min: 100, max: 100)
        let merged = FSMWithStartEnd(fsm: fsm, start: 0, ends: [3]).mergingEquivalentStates()
        #expect(!merged.accepts("cd"))
        #expect(merged.accepts("acd"))
        #expect(merged.accepts("xyzcd"))
        #expect(!merged.accepts("d"))
    }

    @Test func mergingNodes() {
        var fsm = FSM(stateCount: 10)
        func edge(_ from: Int32, _ to: Int32, _ character: Character) {
            let value = Int32(character.asciiValue!)
            fsm.addEdge(from: from, to: to, min: value, max: value)
        }
        edge(0, 1, "a"); edge(0, 2, "a")
        edge(1, 3, "b"); edge(1, 3, "c"); edge(1, 4, "b"); edge(1, 4, "c")
        edge(2, 5, "b"); edge(2, 5, "c"); edge(2, 6, "b"); edge(2, 6, "c")
        edge(3, 7, "d"); edge(4, 7, "d"); edge(5, 8, "d"); edge(6, 8, "d")
        edge(7, 9, "e"); edge(8, 9, "e")
        let merged = FSMWithStartEnd(fsm: fsm, start: 0, ends: [9]).mergingEquivalentStates()
        let expected = """
            FSM(num_states=5, start=3, end=[4], edges=[
            0: ['d'->2]
            1: ['b'->0, 'c'->0]
            2: ['e'->4]
            3: ['a'->1]
            4: []
            ])
            """
        #expect(merged.description == expected)
        #expect(merged.stateCount == 5)
    }

    @Test func mergeEquivalentStatesNoCrossRuleChaining() {
        var fsm = FSM(stateCount: 7)
        func edge(_ from: Int32, _ to: Int32, _ character: Character) {
            let value = Int32(character.asciiValue!)
            fsm.addEdge(from: from, to: to, min: value, max: value)
        }
        edge(0, 2, "x"); edge(0, 3, "x"); edge(0, 1, "y")
        edge(1, 4, "a"); edge(2, 4, "a"); edge(3, 5, "b"); edge(4, 6, "m"); edge(5, 6, "n")
        let merged = FSMWithStartEnd(fsm: fsm, start: 0, ends: [6]).mergingEquivalentStates()
        #expect(merged.accepts("xam"))
        #expect(merged.accepts("xbn"))
        #expect(merged.accepts("yam"))
        #expect(!merged.accepts("ybn"))
    }

    @Test func simplifyEpsilonPreservesAcceptance() throws {
        var fsm = try build("(ab)+").simplifyingEpsilon()
        #expect(!fsm.accepts(""))
        #expect(!fsm.accepts("a"))
        #expect(fsm.accepts("ab"))
        #expect(fsm.accepts("abab"))

        fsm = try build("a+").simplifyingEpsilon()
        #expect(!fsm.accepts(""))
        #expect(fsm.accepts("a"))
        #expect(fsm.accepts("aaa"))

        // Accepting state 1 has a single epsilon edge to non-accepting 2, which is also
        // reachable via 0 -b-> 2. Merging would wrongly accept "b".
        var manual = FSM(stateCount: 4)
        manual.addEdge(from: 0, to: 1, min: 97, max: 97)
        manual.addEpsilonEdge(from: 1, to: 2)
        manual.addEdge(from: 0, to: 2, min: 98, max: 98)
        manual.addEdge(from: 2, to: 3, min: 99, max: 99)
        let simplified = FSMWithStartEnd(fsm: manual, start: 0, ends: [1, 3]).simplifyingEpsilon()
        #expect(simplified.accepts("a"))
        #expect(simplified.accepts("ac"))
        #expect(simplified.accepts("bc"))
        #expect(!simplified.accepts("b"))
        #expect(!simplified.accepts(""))

        var mergeable = FSM(stateCount: 3)
        mergeable.addEdge(from: 0, to: 1, min: 97, max: 97)
        mergeable.addEpsilonEdge(from: 1, to: 2)
        let merged = FSMWithStartEnd(fsm: mergeable, start: 0, ends: [2]).simplifyingEpsilon()
        #expect(merged.stateCount == 2)
        #expect(merged.accepts("a"))
        #expect(!merged.accepts(""))
    }

    @Test func epsilonSimplification() {
        var fsm = FSM(stateCount: 10)
        fsm.addEpsilonEdge(from: 0, to: 1)
        fsm.addEpsilonEdge(from: 0, to: 2)
        fsm.addEdge(from: 1, to: 3, min: 98, max: 98)
        fsm.addEpsilonEdge(from: 1, to: 3)
        fsm.addEdge(from: 1, to: 4, min: 98, max: 98)
        fsm.addEdge(from: 3, to: 3, min: 99, max: 99)
        fsm.addEpsilonEdge(from: 2, to: 5)
        fsm.addEdge(from: 2, to: 5, min: 99, max: 99)
        fsm.addEdge(from: 2, to: 6, min: 98, max: 98)
        fsm.addEdge(from: 2, to: 6, min: 99, max: 99)
        fsm.addEpsilonEdge(from: 3, to: 7)
        fsm.addEpsilonEdge(from: 4, to: 7)
        fsm.addEpsilonEdge(from: 5, to: 8)
        fsm.addEpsilonEdge(from: 6, to: 8)
        fsm.addEpsilonEdge(from: 7, to: 9)
        fsm.addEpsilonEdge(from: 8, to: 9)
        let simplified = FSMWithStartEnd(fsm: fsm, start: 0, ends: [9]).simplifyingEpsilon()
        let expected = """
            FSM(num_states=3, start=0, end=[1], edges=[
            0: [Eps->1, Eps->2, 'b'->1, 'b'->2, 'c'->1]
            1: []
            2: [Eps->1, 'c'->2]
            ])
            """
        #expect(simplified.description == expected)
        #expect(simplified.stateCount == 3)
    }

    @Test func efficiency() throws {
        let alternatives = (0 ..< 26).flatMap { index -> [String] in
            let letter = String(UnicodeScalar(UInt8(97 + index)))
            return ["\(letter)0123456789", "\(letter)0123456789"]
        }.joined(separator: "|")
        let pattern = String(repeating: "(\(alternatives))", count: 10)
        var fsm = try build(pattern)
        fsm = fsm.simplifyingEpsilon()
        fsm = fsm.mergingEquivalentStates()
        fsm = try fsm.determinized()
        fsm = try fsm.minimized()
        #expect(fsm.stateCount == 111)
    }

    // MARK: Trie

    @Test func trieWithBackEdges() {
        let patterns: [[UInt8]] = [Array("bcd".utf8), Array("abce".utf8)]
        let result = TrieFSMBuilder.build(patterns: patterns, addBackEdges: true)!
        // After following "abc" of the "abce" branch, 'd' must land on the "bcd" end state.
        var states: Set<Int32> = [result.fsm.start]
        for byte in "abcd".utf8 {
            states = result.fsm.fsm.advance(from: states, value: Int32(byte))
        }
        #expect(states.contains(result.patternEndStates[0]))
    }

    @Test func trieRejectsOverlap() {
        let overlapping: [[UInt8]] = [Array("ab".utf8), Array("abc".utf8)]
        #expect(TrieFSMBuilder.build(patterns: overlapping, allowOverlap: false) == nil)
        #expect(TrieFSMBuilder.build(patterns: overlapping, allowOverlap: true) != nil)
    }
}
