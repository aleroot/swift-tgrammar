// A bit per token id: 1 = allowed, 0 = masked. Backed by 32-bit words so it can be handed to an
// MLX/Metal kernel or applied to logits on the CPU without conversion.

/// The set of tokens a matcher allows next.
///
/// Bit `i` is set when token `i` may be emitted. The storage is `[UInt32]` with
/// `(vocabSize + 31) / 32` words; bits beyond `vocabSize` in the last word are unspecified.
public struct TokenBitmask: Sendable, Hashable {
    public static let bitsPerWord = 32

    /// Number of valid bits.
    public let vocabSize: Int
    /// Packed bits, least significant bit first.
    public private(set) var words: [UInt32]

    /// Number of words needed for `vocabSize` bits.
    @inline(__always)
    public static func wordCount(vocabSize: Int) -> Int { (vocabSize + bitsPerWord - 1) / bitsPerWord }

    /// An all-zero (everything masked) bitmask.
    public init(vocabSize: Int) {
        precondition(vocabSize >= 0)
        self.vocabSize = vocabSize
        words = Array(repeating: 0, count: Self.wordCount(vocabSize: vocabSize))
    }

    /// Wraps existing words (e.g. one row of a batch buffer).
    public init(vocabSize: Int, words: [UInt32]) {
        precondition(vocabSize >= 0)
        precondition(words.count >= Self.wordCount(vocabSize: vocabSize), "The buffer is too small for \(vocabSize) tokens")
        self.vocabSize = vocabSize
        self.words = words.count == Self.wordCount(vocabSize: vocabSize) ? words : Array(words.prefix(Self.wordCount(vocabSize: vocabSize)))
    }

    @inline(__always)
    public subscript(tokenID: Int) -> Bool {
        get { words[tokenID >> 5] & (1 << UInt32(tokenID & 31)) != 0 }
        set {
            if newValue { words[tokenID >> 5] |= 1 << UInt32(tokenID & 31) } else { words[tokenID >> 5] &= ~(1 << UInt32(tokenID & 31)) }
        }
    }

    @inline(__always)
    public subscript(tokenID: Int32) -> Bool {
        get { self[Int(tokenID)] }
        set { self[Int(tokenID)] = newValue }
    }

    /// Whether `tokenID` is allowed.
    @inline(__always)
    public func allows(_ tokenID: Int32) -> Bool {
        tokenID >= 0 && Int(tokenID) < vocabSize && self[Int(tokenID)]
    }

    public mutating func setAll() {
        words.withUnsafeMutableBufferPointer { $0.update(repeating: .max) }
    }

    public mutating func clearAll() {
        words.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
    }

    public mutating func formUnion(_ other: TokenBitmask) {
        other.words.withUnsafeBufferPointer { source in
            words.withUnsafeMutableBufferPointer { target in
                for index in 0 ..< min(target.count, source.count) { target[index] |= source[index] }
            }
        }
    }

    public mutating func withUnsafeMutableWords<R>(_ body: (UnsafeMutableBufferPointer<UInt32>) throws -> R) rethrows -> R {
        try words.withUnsafeMutableBufferPointer { try body($0) }
    }

    public func withUnsafeWords<R>(_ body: (UnsafeBufferPointer<UInt32>) throws -> R) rethrows -> R {
        try words.withUnsafeBufferPointer(body)
    }

    private var lastWordMask: UInt32 {
        let remaining = vocabSize % Self.bitsPerWord
        return remaining == 0 ? .max : (UInt32(1) << UInt32(remaining)) - 1
    }

    /// Number of allowed tokens.
    public var count: Int {
        guard vocabSize > 0 else { return 0 }
        var total = 0
        for index in 0 ..< words.count - 1 { total += words[index].nonzeroBitCount }
        return total + (words[words.count - 1] & lastWordMask).nonzeroBitCount
    }

    /// Whether every token is allowed.
    public var allowsAll: Bool {
        guard vocabSize > 0 else { return true }
        let mask = lastWordMask
        return words.withUnsafeBufferPointer { words in
            let last = words.count - 1
            var index = 0
            // Sixteen words per branch keep the scan vectorizable.
            while index + 16 <= last {
                var all = UInt32.max
                for offset in index ..< index + 16 { all &= words[offset] }
                if all != .max { return false }
                index += 16
            }
            while index < last {
                if words[index] != .max { return false }
                index += 1
            }
            return words[last] & mask == mask
        }
    }

    /// Whether at least one token is allowed.
    public var allowsAny: Bool {
        guard vocabSize > 0 else { return false }
        let mask = lastWordMask
        return words.withUnsafeBufferPointer { words in
            let last = words.count - 1
            var index = 0
            while index + 16 <= last {
                var any: UInt32 = 0
                for offset in index ..< index + 16 { any |= words[offset] }
                if any != 0 { return true }
                index += 16
            }
            while index < last {
                if words[index] != 0 { return true }
                index += 1
            }
            return words[last] & mask != 0
        }
    }

    /// The single allowed token, if exactly one is allowed.
    public var singleAllowedToken: Int32? {
        count == 1 ? firstAllowed(from: 0).map(Int32.init) : nil
    }

    /// Lowest allowed token id at or after `start`, or `nil`.
    public func firstAllowed(from start: Int = 0) -> Int? {
        guard start < vocabSize else { return nil }
        var wordIndex = start >> 5
        var word = words[wordIndex] >> UInt32(start & 31)
        if word != 0 {
            let result = start + word.trailingZeroBitCount
            return result < vocabSize ? result : nil
        }
        wordIndex += 1
        while wordIndex < words.count {
            word = words[wordIndex]
            if word != 0 {
                let result = wordIndex << 5 + word.trailingZeroBitCount
                return result < vocabSize ? result : nil
            }
            wordIndex += 1
        }
        return nil
    }

    /// Lowest masked token id at or after `start`, or `nil`.
    public func firstMasked(from start: Int = 0) -> Int? {
        guard start < vocabSize else { return nil }
        var wordIndex = start >> 5
        var word = ~words[wordIndex] >> UInt32(start & 31)
        if word != 0 {
            let result = start + word.trailingZeroBitCount
            return result < vocabSize ? result : nil
        }
        wordIndex += 1
        while wordIndex < words.count {
            word = ~words[wordIndex]
            if word != 0 {
                let result = wordIndex << 5 + word.trailingZeroBitCount
                return result < vocabSize ? result : nil
            }
            wordIndex += 1
        }
        return nil
    }

    /// Ids of the masked tokens, ascending.
    public var maskedTokenIDs: [Int32] {
        var result: [Int32] = []
        var cursor = firstMasked(from: 0)
        while let id = cursor {
            result.append(Int32(id))
            cursor = firstMasked(from: id + 1)
        }
        return result
    }

    /// Ids of the allowed tokens, ascending.
    public var allowedTokenIDs: [Int32] {
        var result: [Int32] = []
        result.reserveCapacity(count)
        var cursor = firstAllowed(from: 0)
        while let id = cursor {
            result.append(Int32(id))
            cursor = firstAllowed(from: id + 1)
        }
        return result
    }

    /// Stores `fill` at every masked position among the first `vocabSize` entries of `logits`,
    /// scanning one word at a time: fully allowed words cost a single load, fully masked words a
    /// contiguous 32-wide store, and mixed words one store per cleared bit.
    @inline(__always)
    static func fillMasked<Scalar>(words: UnsafePointer<UInt32>, vocabSize: Int, logits: UnsafeMutablePointer<Scalar>, with fill: Scalar) {
        let fullWords = vocabSize >> 5
        for wordIndex in 0 ..< fullWords {
            var zeros = ~words[wordIndex]
            if zeros == 0 { continue }
            if zeros == .max {
                (logits + (wordIndex << 5)).update(repeating: fill, count: bitsPerWord)
                continue
            }
            repeat {
                logits[wordIndex << 5 | zeros.trailingZeroBitCount] = fill
                zeros &= zeros &- 1
            } while zeros != 0
        }
        let remaining = vocabSize & 31
        if remaining != 0 {
            var zeros = ~words[fullWords] & ((1 << UInt32(remaining)) - 1)
            while zeros != 0 {
                logits[fullWords << 5 | zeros.trailingZeroBitCount] = fill
                zeros &= zeros &- 1
            }
        }
    }

    /// Writes `-infinity` into `logits` for every masked token.
    ///
    /// The first `min(vocabSize, logits.count)` entries are covered, as in XGrammar's CPU kernel:
    /// a mask narrower than the model's logits leaves the trailing logits untouched, so size the
    /// tokenizer's `vocabSize` to the model's logits width. Works for `Float` and `Float16`.
    public func apply<Scalar: BinaryFloatingPoint>(to logits: UnsafeMutableBufferPointer<Scalar>) {
        let count = min(vocabSize, logits.count)
        guard count > 0, let base = logits.baseAddress else { return }
        words.withUnsafeBufferPointer { Self.fillMasked(words: $0.baseAddress.unsafelyUnwrapped, vocabSize: count, logits: base, with: -.infinity) }
    }

    /// Writes `-infinity` into `logits` for every masked token.
    public func apply<Scalar: BinaryFloatingPoint>(to logits: inout [Scalar]) {
        logits.withUnsafeMutableBufferPointer { apply(to: $0) }
    }

    /// `apply(to:)` for `bfloat16` logits stored as raw bit patterns (`0xFF80` is `-infinity`).
    public func apply(toBFloat16 logits: UnsafeMutableBufferPointer<UInt16>) {
        let count = min(vocabSize, logits.count)
        guard count > 0, let base = logits.baseAddress else { return }
        words.withUnsafeBufferPointer { Self.fillMasked(words: $0.baseAddress.unsafelyUnwrapped, vocabSize: count, logits: base, with: Self.bfloat16NegativeInfinity) }
    }

    static let bfloat16NegativeInfinity: UInt16 = 0xFF80
}
