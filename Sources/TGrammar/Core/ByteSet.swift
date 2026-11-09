// A fixed 256-bit set over byte values, used wherever upstream uses `std::bitset<256>`.

struct ByteSet: Hashable, Sendable {
    private var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)

    init() {}

    init(_ bytes: some Sequence<UInt8>) {
        for byte in bytes { insert(byte) }
    }

    /// The set of every byte in `range`.
    init(range: ClosedRange<UInt8>) {
        for byte in range { insert(byte) }
    }

    static let all: ByteSet = {
        var set = ByteSet()
        set.words = (.max, .max, .max, .max)
        return set
    }()

    var isEmpty: Bool { words.0 == 0 && words.1 == 0 && words.2 == 0 && words.3 == 0 }

    var count: Int {
        words.0.nonzeroBitCount &+ words.1.nonzeroBitCount &+ words.2.nonzeroBitCount &+ words.3.nonzeroBitCount
    }

    /// Calls `body` with each maximal run `lower ..< upper` of consecutive members, in
    /// ascending order, scanning a word at a time.
    func forEachRun(_ body: (_ lower: Int, _ upper: Int) -> Void) {
        @inline(__always) func word(_ index: Int) -> UInt64 {
            switch index {
            case 0: words.0
            case 1: words.1
            case 2: words.2
            default: words.3
            }
        }
        /// First position `>= start` whose membership is `member`, or 256.
        @inline(__always) func next(from start: Int, member: Bool) -> Int {
            var index = start >> 6
            var bits = (member ? word(index) : ~word(index)) & (UInt64.max << UInt64(start & 63))
            while bits == 0 {
                index += 1
                if index == 4 { return 256 }
                bits = member ? word(index) : ~word(index)
            }
            return index << 6 | bits.trailingZeroBitCount
        }
        var position = 0
        while position < 256 {
            let lower = next(from: position, member: true)
            if lower == 256 { return }
            let upper = lower == 255 ? 256 : next(from: lower &+ 1, member: false)
            body(lower, upper)
            position = upper
        }
    }

    @inline(__always)
    func contains(_ byte: UInt8) -> Bool {
        let bit = UInt64(1) << UInt64(byte & 63)
        switch byte >> 6 {
        case 0: return words.0 & bit != 0
        case 1: return words.1 & bit != 0
        case 2: return words.2 & bit != 0
        default: return words.3 & bit != 0
        }
    }

    @inline(__always)
    func contains(_ value: Int32) -> Bool {
        value >= 0 && value <= 255 && contains(UInt8(truncatingIfNeeded: value))
    }

    @inline(__always)
    mutating func insert(_ byte: UInt8) {
        let bit = UInt64(1) << UInt64(byte & 63)
        switch byte >> 6 {
        case 0: words.0 |= bit
        case 1: words.1 |= bit
        case 2: words.2 |= bit
        default: words.3 |= bit
        }
    }

    @inline(__always)
    mutating func remove(_ byte: UInt8) {
        let bit = ~(UInt64(1) << UInt64(byte & 63))
        switch byte >> 6 {
        case 0: words.0 &= bit
        case 1: words.1 &= bit
        case 2: words.2 &= bit
        default: words.3 &= bit
        }
    }

    mutating func insert(range: ClosedRange<Int32>) {
        let low = Swift.max(range.lowerBound, 0)
        let high = Swift.min(range.upperBound, 255)
        if low > high { return }
        for value in low ... high { insert(UInt8(value)) }
    }

    mutating func removeAll() { words = (0, 0, 0, 0) }

    mutating func formUnion(_ other: ByteSet) {
        words.0 |= other.words.0
        words.1 |= other.words.1
        words.2 |= other.words.2
        words.3 |= other.words.3
    }

    mutating func formIntersection(_ other: ByteSet) {
        words.0 &= other.words.0
        words.1 &= other.words.1
        words.2 &= other.words.2
        words.3 &= other.words.3
    }

    var inverted: ByteSet {
        var result = self
        result.words = (~words.0, ~words.1, ~words.2, ~words.3)
        return result
    }

    static func == (lhs: ByteSet, rhs: ByteSet) -> Bool {
        lhs.words.0 == rhs.words.0 && lhs.words.1 == rhs.words.1 && lhs.words.2 == rhs.words.2 && lhs.words.3 == rhs.words.3
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(words.0)
        hasher.combine(words.1)
        hasher.combine(words.2)
        hasher.combine(words.3)
    }

    /// Calls `body` for each maximal run of consecutive members, in ascending order.
    func forEachRange(_ body: (ClosedRange<Int32>) -> Void) {
        var start: Int32 = -1
        for value in Int32(0) ... 255 {
            if contains(UInt8(value)) {
                if start < 0 { start = value }
            } else if start >= 0 {
                body(start ... value &- 1)
                start = -1
            }
        }
        if start >= 0 { body(start ... 255) }
    }
}
