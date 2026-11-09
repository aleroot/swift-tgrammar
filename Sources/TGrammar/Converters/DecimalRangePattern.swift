import Foundation

// As upstream, bounded number generation uses plain decimal notation with at most six
// fractional digits. Decimal arithmetic preserves the exact input bound at grid boundaries.
//
// The language is every plain decimal on the six-digit grid inside the bounds, written with any
// number of fractional digits up to six (trailing zeros included). It is spelled out per integer
// part rather than per precision: integer parts strictly inside the range take any fraction, and
// only the two boundary integer parts constrain theirs digit by digit. Seven near-copies of the
// range, one per precision, made the regex (and its automaton, built at every compilation) about
// six times larger.
enum DecimalRangePattern {
    private struct Bound {
        var value: Decimal
        var exclusive: Bool
    }

    /// Fractional digits of the grid.
    private static let precision = 6
    private static let anyFraction = #"(\.[0-9]{1,6})?"#

    static func make(_ schema: JSONValue) throws(GrammarError) -> String {
        func read(_ name: String, exclusive: Bool) throws(GrammarError) -> Bound? {
            guard let raw = schema[name] else { return nil }
            guard case .number(let text) = raw, let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { throw .conversion("\(name) must be a finite decimal number") }
            return Bound(value: value, exclusive: exclusive)
        }
        var low = try read("minimum", exclusive: false), high = try read("maximum", exclusive: false)
        if let bound = try read("exclusiveMinimum", exclusive: true), low == nil || bound.value >= low!.value { low = bound }
        if let bound = try read("exclusiveMaximum", exclusive: true), high == nil || bound.value <= high!.value { high = bound }
        if let low, let high, low.value > high.value || (low.value == high.value && (low.exclusive || high.exclusive)) {
            throw .conversion("Unsatisfiable number range")
        }
        var alternatives: [String] = []
        let zeroAllowed = (low == nil || low!.value < 0 || (low!.value == 0 && !low!.exclusive))
            && (high == nil || high!.value > 0 || (high!.value == 0 && !high!.exclusive))
        if zeroAllowed {
            alternatives.append(#"0(\.0{1,6})?"#)
            if low == nil || low!.value < 0 { alternatives.append(#"-0\.0{1,6}"#) }
        }
        let scale = Decimal(sign: .plus, exponent: precision, significand: 1)
        for negative in [false, true] {
            let magnitudeLow = negative ? high.map { Bound(value: -$0.value, exclusive: $0.exclusive) } : low
            let magnitudeHigh = negative ? low.map { Bound(value: -$0.value, exclusive: $0.exclusive) } : high
            if let high = magnitudeHigh, high.value <= 0 { continue }
            // The range in grid units; zero has its own canonical branches.
            var lowerScaled = (magnitudeLow?.value ?? 0) * scale
            var roundedLow = Decimal()
            NSDecimalRound(&roundedLow, &lowerScaled, 0, .up)
            if magnitudeLow?.exclusive == true, roundedLow == lowerScaled { roundedLow += 1 }
            roundedLow = Swift.max(roundedLow, 1)
            var roundedHigh: Decimal?
            if let high = magnitudeHigh {
                var scaled = high.value * scale
                var rounded = Decimal()
                NSDecimalRound(&rounded, &scaled, 0, .down)
                if high.exclusive, rounded == scaled { rounded -= 1 }
                if rounded < roundedLow { continue }
                roundedHigh = rounded
            }
            guard !roundedLow.isNaN, roundedHigh?.isNaN != true else { throw .unsupported("Number range exceeds decimal precision") }
            let magnitude = try magnitudePattern(lower: try gridDigits(roundedLow), upper: try roundedHigh.map(gridDigits))
            alternatives.append((negative ? "-" : "") + magnitude)
        }
        guard !alternatives.isEmpty else { throw .conversion("Number range contains no value on the six-digit grid") }
        return "(" + alternatives.joined(separator: "|") + ")"
    }

    /// A positive grid value: its integer part in plain digits and its six fractional digits.
    private struct GridDigits {
        var integer: Decimal
        var fraction: [Int]
        var hasFraction: Bool { fraction.contains { $0 != 0 } }
    }

    private static func gridDigits(_ scaled: Decimal) throws(GrammarError) -> GridDigits {
        var text = NSDecimalNumber(decimal: scaled).stringValue
        guard text.utf8.allSatisfy({ (48 ... 57).contains($0) }) else { throw .unsupported("Number bound cannot be represented on the six-digit grid") }
        if text.count <= precision { text = String(repeating: "0", count: precision + 1 - text.count) + text }
        let integer = Decimal(string: String(text.dropLast(precision)), locale: Locale(identifier: "en_US_POSIX")) ?? 0
        return GridDigits(integer: integer, fraction: text.utf8.suffix(precision).map { Int($0) - 48 })
    }

    private static func plain(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }

    /// Plain decimals between two positive grid values (`upper == nil`: unbounded).
    private static func magnitudePattern(lower: GridDigits, upper: GridDigits?) throws(GrammarError) -> String {
        if let upper, upper.integer == lower.integer {
            let fraction = between(lower.fraction, upper.fraction, from: 0)
            return plain(lower.integer) + (lower.hasFraction ? #"\."# + fraction : #"(\."# + fraction + ")?")
        }
        var parts: [String] = []
        // The lower integer part: any fraction not below the bound's.
        parts.append(plain(lower.integer) + (lower.hasFraction ? #"\."# + atLeast(lower.fraction, from: 0) : anyFraction))
        // Integer parts strictly inside: any fraction.
        let firstInner = lower.integer + 1
        if let upper {
            let lastInner = upper.integer - 1
            if firstInner <= lastInner {
                parts.append(IntegerRangePattern.decimal(lower: plain(firstInner), upper: plain(lastInner), fractionDigits: 0) + anyFraction)
            }
            // The upper integer part: no fraction, or one not above the bound's.
            parts.append(plain(upper.integer) + #"(\."# + atMost(upper.fraction, from: 0) + ")?")
        } else {
            parts.append(IntegerRangePattern.decimal(lower: plain(firstInner), upper: nil, fractionDigits: 0) + anyFraction)
        }
        return "(" + parts.joined(separator: "|") + ")"
    }

    // MARK: Fractions
    //
    // A fraction is written with 1 to 6 digits and compared after padding with zeros. Each
    // builder matches the fractional digits from position `index` on.

    private static func digitRange(_ low: Int, _ high: Int) -> String { low == high ? String(low) : "[\(low)-\(high)]" }

    /// Any 0 to `count` further digits.
    private static func anyDigits(upTo count: Int) -> String { count == 0 ? "" : "[0-9]{0,\(count)}" }

    private static func choice(_ alternatives: [String]) -> String {
        alternatives.count == 1 ? alternatives[0] : "(" + alternatives.joined(separator: "|") + ")"
    }

    /// Fractions whose padded value is at most `bound` (zero digits included).
    private static func atMost(_ bound: [Int], from index: Int) -> String {
        let remaining = precision - 1 - index
        var alternatives: [String] = []
        if bound[index] > 0 { alternatives.append(digitRange(0, bound[index] - 1) + anyDigits(upTo: remaining)) }
        alternatives.append(String(bound[index]) + (remaining == 0 ? "" : "(" + atMost(bound, from: index + 1) + ")?"))
        return choice(alternatives)
    }

    /// Fractions whose padded value is at least `bound`.
    private static func atLeast(_ bound: [Int], from index: Int) -> String {
        let remaining = precision - 1 - index
        var alternatives: [String] = []
        if bound[index] < 9 { alternatives.append(digitRange(bound[index] + 1, 9) + anyDigits(upTo: remaining)) }
        if bound[(index + 1)...].allSatisfy({ $0 == 0 }) {
            alternatives.append(String(bound[index]) + anyDigits(upTo: remaining))
        } else {
            alternatives.append(String(bound[index]) + atLeast(bound, from: index + 1))
        }
        return choice(alternatives)
    }

    /// Fractions whose padded value lies between `low` and `high`.
    private static func between(_ low: [Int], _ high: [Int], from index: Int) -> String {
        let remaining = precision - 1 - index
        let (a, b) = (low[index], high[index])
        let lowRestIsZero = low[(index + 1)...].allSatisfy { $0 == 0 }
        if a == b {
            if remaining == 0 { return String(a) }
            let rest = between(low, high, from: index + 1)
            return String(a) + (lowRestIsZero ? "(" + rest + ")?" : rest)
        }
        var alternatives: [String] = []
        if remaining == 0 {
            alternatives.append(String(a))
        } else {
            alternatives.append(String(a) + (lowRestIsZero ? anyDigits(upTo: remaining) : atLeast(low, from: index + 1)))
        }
        if a + 1 <= b - 1 { alternatives.append(digitRange(a + 1, b - 1) + anyDigits(upTo: remaining)) }
        alternatives.append(String(b) + (remaining == 0 ? "" : "(" + atMost(high, from: index + 1) + ")?"))
        return choice(alternatives)
    }
}
