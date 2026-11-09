// A sorted set of sorted-vocabulary indices stored as half-open runs. Tokens whose fate a state
// cannot decide alone are lexicographic neighbours (every token under some trie prefix), so a
// mask's uncertain set is a few runs even when it holds most of the vocabulary: with Qwen3, a
// string state's 102,863 uncertain indices are 83 runs, 664 bytes instead of 411 KB.

struct IndexRuns: Sendable, Hashable, Sequence {
    /// Ascending, non-adjacent `[start, end)` pairs, interleaved.
    private(set) var bounds: [Int32] = []
    /// Number of indices.
    private(set) var count = 0

    init() {}

    /// From ascending, distinct indices.
    init(_ sorted: some Sequence<Int32>) {
        var bounds: [Int32] = []
        var count = 0
        for index in sorted {
            if let end = bounds.last, end == index {
                bounds[bounds.count - 1] = index + 1
            } else {
                bounds.append(index)
                bounds.append(index + 1)
            }
            count += 1
        }
        self.bounds = bounds.compacted()
        self.count = count
    }

    var isEmpty: Bool { count == 0 }
    var runCount: Int { bounds.count >> 1 }
    @inline(__always) func start(ofRun run: Int) -> Int32 { bounds[run << 1] }
    @inline(__always) func end(ofRun run: Int) -> Int32 { bounds[run << 1 | 1] }

    /// The indices as a plain sorted list.
    var array: [Int32] {
        var result: [Int32] = []
        result.reserveCapacity(count)
        for run in 0 ..< runCount { result.append(contentsOf: start(ofRun: run) ..< end(ofRun: run)) }
        return result
    }

    var storageBytes: Int { bounds.storageBytes }

    /// Shares `bounds` with an equal set's buffer (see `MaskStorageInterner`).
    mutating func withBounds(_ body: (inout [Int32]) -> Void) { body(&bounds) }

    func makeIterator() -> Iterator { Iterator(bounds: bounds) }

    struct Iterator: IteratorProtocol {
        let bounds: [Int32]
        var current: Int32
        var end: Int32
        var run = 0

        init(bounds: [Int32]) {
            self.bounds = bounds
            current = bounds.first ?? 0
            end = bounds.count > 1 ? bounds[1] : 0
        }

        mutating func next() -> Int32? {
            if current == end {
                run += 2
                guard run < bounds.count else { return nil }
                current = bounds[run]
                end = bounds[run + 1]
            }
            defer { current += 1 }
            return current
        }
    }
}
