// The decoded vocabulary indexed by token id. Every regular token's bytes already live in the
// sorted token table the compiler walks, so this is a view over that table plus the few tokens
// kept out of it (stop tokens), instead of a second copy of the vocabulary (1.6 MB for Qwen3).

/// The vocabulary decoded to raw bytes, indexed by token id.
///
/// A read-only collection of byte strings: `vocabulary[id]` is the bytes token `id` emits.
/// Empty for special tokens.
public struct DecodedVocabulary: RandomAccessCollection, Sendable, Equatable {
    public typealias Element = ArraySlice<UInt8>
    public typealias Index = Int

    private let sorted: ByteStringTable
    /// Index into `sorted` per token id, `-1` for tokens outside it.
    private let sortedIndexByTokenID: [Int32]
    /// Ids (sorted) and bytes of the non-empty tokens outside `sorted`.
    private let otherIDs: [Int32]
    private let others: ByteStringTable

    public let count: Int
    @inlinable public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    /// - Parameters:
    ///   - decoded: The full decoded vocabulary, used only to pick the tokens outside `sorted`.
    init(decoded: ByteStringTable, sorted: ByteStringTable, sortedIndexByTokenID: [Int32]) {
        self.sorted = sorted
        self.sortedIndexByTokenID = sortedIndexByTokenID
        count = decoded.count
        var ids: [Int32] = []
        var others = ByteStringTable()
        for id in 0 ..< decoded.count where sortedIndexByTokenID[id] < 0 && decoded.length(at: id) > 0 {
            ids.append(Int32(id))
            others.append(decoded[id])
        }
        others.compact()
        otherIDs = ids.compacted()
        self.others = others
    }

    @inline(__always)
    public subscript(id: Int) -> ArraySlice<UInt8> {
        precondition(id >= 0 && id < count, "Token id out of range")
        let index = sortedIndexByTokenID[id]
        if index >= 0 { return sorted[Int(index)] }
        if let slot = SortedIntSet.index(of: Int32(id), in: otherIDs) { return others[slot] }
        return ArraySlice()
    }

    /// Byte length of token `id`, without materializing a view.
    public func length(at id: Int) -> Int {
        precondition(id >= 0 && id < count, "Token id out of range")
        let index = sortedIndexByTokenID[id]
        if index >= 0 { return sorted.length(at: Int(index)) }
        if let slot = SortedIntSet.index(of: Int32(id), in: otherIDs) { return others.length(at: slot) }
        return 0
    }

    /// Total number of bytes across all tokens.
    public var byteCount: Int { sorted.byteCount + others.byteCount }

    public static func == (lhs: DecodedVocabulary, rhs: DecodedVocabulary) -> Bool {
        lhs.count == rhs.count && lhs.indices.allSatisfy { lhs[$0].elementsEqual(rhs[$0]) }
    }
}
