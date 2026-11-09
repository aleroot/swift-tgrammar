import Foundation
import Testing

@testable import TGrammar

/// Language check of the bounded-number pattern (`DecimalRangePattern`). Over a window of integer
/// parts and fractions around each range, a plain decimal with at most six fractional digits is
/// accepted exactly when its value lies within the bounds. Zero keeps its canonical spellings:
/// `-0` alone is never accepted, and `-0.0…` only when the range reaches below zero.
struct DecimalRangePatternTests {
    struct Range: CustomTestStringConvertible, Sendable {
        var low: String?
        var lowExclusive = false
        var high: String?
        var highExclusive = false

        var schema: String {
            var members: [String] = []
            if let low { members.append(#""\#(lowExclusive ? "exclusiveMinimum" : "minimum")": \#(low)"#) }
            if let high { members.append(#""\#(highExclusive ? "exclusiveMaximum" : "maximum")": \#(high)"#) }
            return "{" + members.joined(separator: ", ") + "}"
        }
        var testDescription: String { schema }
    }

    static let ranges: [Range] = [
        Range(low: "-90", high: "90"),
        Range(low: "-180", high: "180"),
        Range(low: "0.5", high: "2.25"),
        Range(low: "0", lowExclusive: true, high: "1", highExclusive: true),
        Range(low: "-2.5", high: "-0.125", highExclusive: true),
        Range(low: "1.0000005"),
        Range(low: "3.75", lowExclusive: true),
        Range(high: "-1.5"),
        Range(low: "0", high: "0"),
        Range(low: "12.345678", high: "13.1"),
        Range(low: "9.99", high: "10.01"),
        Range(low: "-0.000001", high: "0.000001"),
        Range(low: "7.25", high: "7.2501"),
        Range(low: "0", lowExclusive: true),
        Range(high: "0", highExclusive: true),
    ]

    /// Fractions to try: every one or two digits, plus prefixes of each bound's six digits with
    /// the last digit nudged either way, plus extreme six-digit spellings.
    static func fractions(near bounds: [Decimal]) -> [String] {
        var result: Set<String> = [""]
        for a in 0 ... 9 {
            result.insert("\(a)")
            for b in 0 ... 9 { result.insert("\(a)\(b)") }
        }
        result.formUnion(["000000", "000001", "999999", "100000", "000010", "5000", "12500", "999"])
        for bound in bounds {
            var scaled = bound.magnitude * 1_000_000
            var rounded = Decimal()
            NSDecimalRound(&rounded, &scaled, 0, .plain)
            let digits = Array(String(String(describing: rounded).suffix(6)).leftPadded(to: 6))
            for length in 1 ... 6 {
                let prefix = digits[0 ..< length]
                let last = Int(String(prefix.last!))!
                for delta in -1 ... 1 where (0 ... 9).contains(last + delta) {
                    result.insert(String(prefix.dropLast()) + String(last + delta))
                }
            }
        }
        return result.sorted()
    }

    static func integerParts(near bounds: [Decimal]) -> [String] {
        var parts = Set((-3 ... 3).map(String.init))
        parts.insert("-0")
        for bound in bounds {
            var value = bound
            var truncated = Decimal()
            NSDecimalRound(&truncated, &value, 0, .down)
            let center = NSDecimalNumber(decimal: truncated).intValue
            for offset in -2 ... 2 { parts.insert(String(center + offset)) }
        }
        return parts.sorted()
    }

    /// Regression: `X?` linked the start of `X` to its first end state even when that state has
    /// outgoing edges, so `([0-4][0-9]{0,4})?` accepted `6` (upstream's `Optional` does the same).
    @Test(arguments: [
        (#"([0-4][0-9]{0,4})?"#, "6", false),
        (#"([0-4][0-9]{0,4})?"#, "", true),
        (#"([0-4][0-9]{0,4})?"#, "46", true),
        (#"2([0-4][0-9]{0,4}|5)?"#, "26", false),
        (#"2([0-4][0-9]{0,4}|5)?"#, "25", true),
        (#"2(\.([0-1][0-9]{0,5}|2(([0-4][0-9]{0,4}|5)?)))?"#, "2.26", false),
        (#"2(\.([0-1][0-9]{0,5}|2(([0-4][0-9]{0,4}|5)?)))?"#, "2.24", true),
        (#"(a[b-c]*)?"#, "b", false),
        (#"(a[b-c]*)?"#, "abcb", true),
    ])
    func optionalSkipsOnlyTheWholeGroup(_ pattern: String, _ input: String, _ accepted: Bool) throws {
        #expect(try RegexFSMBuilder.build(Array(pattern.utf8)).accepts(input) == accepted)
        #expect(try GrammarFSMBuilder.regex(Array(pattern.utf8)).accepts(input) == accepted)
    }

    @Test(arguments: ranges)
    func acceptsExactlyTheValuesInRange(_ range: Range) throws {
        let pattern = try DecimalRangePattern.make(try JSONValue.parse(range.schema))
        let automaton = try GrammarFSMBuilder.regex(Array(pattern.utf8))
        let low = range.low.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        let high = range.high.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        func within(_ value: Decimal) -> Bool {
            if let low, range.lowExclusive ? value <= low : value < low { return false }
            if let high, range.highExclusive ? value >= high : value > high { return false }
            return true
        }
        let bounds = [low, high].compactMap { $0 }
        var mismatches: [String] = []
        for integer in Self.integerParts(near: bounds) {
            for fraction in Self.fractions(near: bounds) {
                let text = fraction.isEmpty ? integer : integer + "." + fraction
                let value = try #require(Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")))
                var expected = within(value)
                if value == 0, text.hasPrefix("-") { expected = expected && !fraction.isEmpty && (low.map { $0 < 0 } ?? true) }
                if automaton.accepts(text) != expected { mismatches.append("\(text): expected \(expected)") }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(20))")
    }
}

private extension String {
    func leftPadded(to length: Int) -> String { count >= length ? self : String(repeating: "0", count: length - count) + self }
}
