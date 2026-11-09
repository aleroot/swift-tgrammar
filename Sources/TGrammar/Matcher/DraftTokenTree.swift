/// A speculative token tree, represented by child/sibling indices. Node zero represents
/// the current target-model position; its token is already committed and is not consumed.
public struct DraftTokenTree: Sendable {
    public struct Node: Sendable, Hashable {
        public let tokenID: Int32
        public let firstChild: Int?
        public let nextSibling: Int?
        public init(_ tokenID: Int32, firstChild: Int? = nil, nextSibling: Int? = nil) {
            self.tokenID = tokenID; self.firstChild = firstChild; self.nextSibling = nextSibling
        }
    }
    public let nodes: [Node]

    public init(nodes: [Node]) throws(GrammarError) {
        guard !nodes.isEmpty, nodes[0].nextSibling == nil else { throw .invalidGrammar("A draft tree needs a root without siblings") }
        var incoming = Array(repeating: 0, count: nodes.count)
        for node in nodes {
            for target in [node.firstChild, node.nextSibling].compactMap({ $0 }) {
                guard nodes.indices.contains(target), target != 0 else { throw .invalidGrammar("Draft tree edge is out of bounds or points to the root") }
                incoming[target] += 1
                guard incoming[target] == 1 else { throw .invalidGrammar("Draft tree nodes cannot have multiple incoming edges") }
            }
        }
        var seen = Set<Int>()
        var pending = [0]
        while let index = pending.popLast() {
            guard seen.insert(index).inserted else { throw .invalidGrammar("Draft tree contains a cycle") }
            if let next = nodes[index].firstChild { pending.append(next) }
            if let next = nodes[index].nextSibling { pending.append(next) }
        }
        guard seen.count == nodes.count else { throw .invalidGrammar("Draft tree contains unreachable nodes or a cycle") }
        self.nodes = nodes
    }
}

/// Flat packed masks for a batch or speculative tree. Each row uses the same layout as
/// ``TokenBitmask`` and can be transferred to an MLX or Metal buffer directly.
public struct TokenMaskBatch: Sendable, Hashable {
    public let vocabSize: Int
    public let rowCount: Int
    public let wordsPerRow: Int
    public internal(set) var words: [UInt32]

    public init(rows: Int, vocabSize: Int) {
        precondition(rows >= 0 && vocabSize >= 0)
        rowCount = rows; self.vocabSize = vocabSize
        wordsPerRow = TokenBitmask.wordCount(vocabSize: vocabSize)
        words = Array(repeating: 0, count: rows * wordsPerRow)
    }
    public subscript(row: Int) -> TokenBitmask {
        precondition(row >= 0 && row < rowCount)
        let start = row * wordsPerRow
        return .init(vocabSize: vocabSize, words: Array(words[start ..< start + wordsPerRow]))
    }
    mutating func setRow(_ row: Int, _ mask: TokenBitmask) {
        let start = row * wordsPerRow
        for index in 0 ..< wordsPerRow { words[start + index] = mask.words[index] }
    }
    /// Allows every token in every row (XGrammar's `reset_token_bitmask`).
    public mutating func setAll() {
        for index in words.indices { words[index] = .max }
    }
    /// Masks every token in every row.
    public mutating func clearAll() {
        for index in words.indices { words[index] = 0 }
    }
    public func withUnsafeWords<Result>(_ body: (UnsafeBufferPointer<UInt32>) throws -> Result) rethrows -> Result {
        try words.withUnsafeBufferPointer(body)
    }

    /// Writes `-infinity` into the masked entries of a row-major logits buffer.
    ///
    /// Row `r` of the batch is applied to `logits[r * rowStride ..< r * rowStride + width]`, where
    /// `rowStride` defaults to `vocabSize` and `width = min(vocabSize, rowStride)`; a larger stride
    /// leaves the trailing entries of each row untouched, as XGrammar's CPU kernel does. `rows`
    /// selects the rows to apply (every row of the batch by default) and lets the logits hold a
    /// different number of rows than the batch; every selected row must exist in both.
    public func apply<Scalar: BinaryFloatingPoint>(to logits: UnsafeMutableBufferPointer<Scalar>, rowStride: Int? = nil, rows: [Int]? = nil) {
        applyRows(to: logits, rowStride: rowStride, rows: rows, fill: -.infinity)
    }

    /// `apply(to:rowStride:rows:)` for `bfloat16` logits stored as raw bit patterns.
    public func apply(toBFloat16 logits: UnsafeMutableBufferPointer<UInt16>, rowStride: Int? = nil, rows: [Int]? = nil) {
        applyRows(to: logits, rowStride: rowStride, rows: rows, fill: TokenBitmask.bfloat16NegativeInfinity)
    }

    private func applyRows<Scalar>(to logits: UnsafeMutableBufferPointer<Scalar>, rowStride: Int?, rows: [Int]?, fill: Scalar) {
        let stride = rowStride ?? vocabSize
        precondition(stride >= 0, "rowStride must be non-negative")
        let width = min(vocabSize, stride)
        let logitsRows = stride == 0 ? 0 : logits.count / stride
        if let rows {
            for row in rows {
                precondition(row >= 0 && row < rowCount && row < logitsRows, "Row \(row) is out of bounds: it should be in [0, \(min(rowCount, logitsRows)))")
            }
        } else {
            precondition(rowCount == logitsRows, "The logits hold \(logitsRows) rows but the batch has \(rowCount); pass `rows` to apply a subset")
        }
        guard width > 0, let base = logits.baseAddress else { return }
        words.withUnsafeBufferPointer { words in
            let wordsBase = words.baseAddress.unsafelyUnwrapped
            if let rows {
                for row in rows {
                    TokenBitmask.fillMasked(words: wordsBase + row * wordsPerRow, vocabSize: width, logits: base + row * stride, with: fill)
                }
            } else {
                for row in 0 ..< rowCount {
                    TokenBitmask.fillMasked(words: wordsBase + row * wordsPerRow, vocabSize: width, logits: base + row * stride, with: fill)
                }
            }
        }
    }
}

public struct DraftTraversalResult: Sendable {
    public let masks: TokenMaskBatch
    public let temperatures: [Float?]
    /// False when the deadline interrupted traversal. Unvisited/rejected rows stay zero.
    public let didFinish: Bool
}
