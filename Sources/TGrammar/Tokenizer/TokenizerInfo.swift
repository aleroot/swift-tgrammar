// The tokenizer-side half of structured generation: the vocabulary decoded to raw bytes, the
// stop and special tokens, and the lexicographically sorted token table (with trie subtree
// bounds) that lets the compiler and matcher share prefix work across tokens.

/// Errors raised while building a ``TokenizerInfo``.
public enum TokenizerInfoError: Error, Hashable, Sendable, CustomStringConvertible {
    /// `vocabSize` only ever pads the vocabulary; a value below the number of real tokens would
    /// leave token ids without a slot.
    case vocabSizeTooSmall(vocabSize: Int, tokenCount: Int)
    case invalidVocabularySize(Int)
    case invalidStopTokenID(Int32)
    /// A metadata JSON string could not be parsed or has the wrong shape.
    case invalidMetadata(String)
    /// A `tokenizer.json` document could not be parsed or has the wrong shape.
    case invalidTokenizerJSON(String)
    /// An explicit stop token list must name at least one token.
    case emptyStopTokenIDs

    public var description: String {
        switch self {
        case let .vocabSizeTooSmall(vocabSize, tokenCount):
            "vocab_size (\(vocabSize)) must be at least the number of tokens in the vocab (\(tokenCount))."
        case .invalidVocabularySize(let size): "Vocabulary size \(size) must be between 0 and Int32.max"
        case .invalidStopTokenID(let id): "Stop token ID \(id) is outside the model vocabulary"
        case let .invalidMetadata(message):
            "Invalid tokenizer metadata: \(message)"
        case let .invalidTokenizerJSON(message):
            "Invalid tokenizer.json: \(message)"
        case .emptyStopTokenIDs:
            "stop_token_ids cannot be empty"
        }
    }
}

/// Vocabulary and token metadata a grammar is compiled against.
///
/// Although tokenizers spell their pieces in encoding-specific ways (`<0x1B>` for `"\u{1B}"` in a
/// byte-fallback vocabulary, `Ġ` for a space in a byte-level one), `TokenizerInfo` always exposes
/// the vocabulary decoded to the raw bytes the model emits.
///
/// Some models pad the vocabulary (Phi-3, DeepSeek-V2 pad to a multiple of 32) or expose fewer
/// logits than the tokenizer has tokens (Llama-3.2 Vision). Always pass the **model's**
/// `vocabSize` — the width of `lm_head` — because it determines the width of the token mask.
public final class TokenizerInfo: Sendable {
    /// Original vocabulary pieces, indexed by token id.
    ///
    /// Only the pieces whose spelling differs from the conventional encoding of their decoded
    /// bytes are stored (special tokens outside the byte-level alphabet, byte-fallback single
    /// characters); this table is rebuilt from them on each access, so read it once.
    public var encodedVocab: ByteStringTable {
        var table = ByteStringTable(capacity: decodedVocab.count, byteCapacity: decodedVocab.byteCount)
        for id in 0 ..< decodedVocab.count { table.append(encodedPiece(id)) }
        return table
    }

    /// Token ids whose original piece is `piece`, in increasing order.
    func tokenIDs(forPiece piece: [UInt8]) -> [Int32] {
        // Decoding is a function, so a matching piece decodes to the token's bytes. Regular tokens
        // with those bytes form one run of the sorted table; the others are stop and special
        // tokens. Only these candidates are spelled and compared with the piece.
        var decoded: [UInt8] = []
        piece.withUnsafeBufferPointer { TokenDecoder.decode($0, as: vocabType, into: &decoded) }
        var candidates: [Int32] = []
        var low = 0, high = sortedTokens.count
        while low < high {
            let mid = (low + high) >> 1
            if sortedTokens[mid].lexicographicallyPrecedes(decoded) { low = mid + 1 } else { high = mid }
        }
        while low < sortedTokens.count, sortedTokens[low].elementsEqual(decoded) {
            candidates.append(sortedTokenIDs[low])
            low += 1
        }
        for id in stopTokenIDs + specialTokenIDs where Int(id) < decodedVocab.count && decodedVocab[Int(id)].elementsEqual(decoded) {
            candidates.append(id)
        }
        return candidates.filter { encodedPiece(Int($0)).elementsEqual(piece) }.sorted()
    }

    /// Resolves an original vocabulary piece. Used while compiling structural formats.
    public func tokenID(for piece: String) -> Int32? {
        tokenIDs(forPiece: Array(piece.utf8)).first
    }

    /// The original piece of token `id`.
    func encodedPiece(_ id: Int) -> [UInt8] {
        if let slot = SortedIntSet.index(of: Int32(id), in: encodedExceptionIDs) { return Array(encodedExceptions[slot]) }
        var piece: [UInt8] = []
        TokenDecoder.appendConventionalPiece(decodedVocab[id], as: vocabType, into: &piece)
        return piece
    }

    /// Ids (sorted) and pieces of the tokens not spelled by their conventional encoding.
    private let encodedExceptionIDs: [Int32]
    private let encodedExceptions: ByteStringTable
    /// How the pieces were spelled before decoding.
    public let vocabType: VocabType
    /// Width of the model's logits; also the width of every token mask.
    public let vocabSize: Int
    /// Whether the tokenizer prepends a space to the text before tokenizing.
    public let addPrefixSpace: Bool

    /// The vocabulary decoded to raw bytes, indexed by token id. Contains one entry per token
    /// handed to the initializer; ids in `decodedVocab.count ..< vocabSize` are padding and are
    /// listed in ``specialTokenIDs``. A view over ``sortedTokens``: the bytes are stored once.
    public let decodedVocab: DecodedVocabulary
    /// Tokens the matcher may emit once the grammar can terminate. Detected from well-known
    /// end-of-sequence spellings unless given explicitly.
    public let stopTokenIDs: [Int32]
    /// Tokens that are always masked out: empty pieces and padding ids.
    public let specialTokenIDs: [Int32]

    /// All regular (non-stop, non-special) tokens in lexicographic byte order. Sorting maximizes
    /// prefix reuse when the matcher walks the vocabulary.
    public let sortedTokens: ByteStringTable
    /// `sortedTokenIDs[i]` is the token id of `sortedTokens[i]`.
    public let sortedTokenIDs: [Int32]
    /// Pseudo-trie over ``sortedTokens``: the tokens having `sortedTokens[i]` as a prefix occupy
    /// exactly `i ..< trieSubtreeEnds[i]`. Rejecting a token therefore rejects a whole range.
    public let trieSubtreeEnds: [Int32]
    /// Index into ``sortedTokens`` for each token id, `-1` for stop, special and padding ids.
    public let sortedIndexByTokenID: [Int32]
    /// Number of UTF-8 code points (leading bytes) in each sorted token. Computed on each access
    /// (only character budgets need it): read it once.
    public var sortedTokenCharCounts: [Int32] {
        (0 ..< sortedTokens.count).map { sortedTokenCharCount($0) }
    }

    /// Number of UTF-8 code points in `sortedTokens[index]`.
    @inline(__always)
    func sortedTokenCharCount(_ index: Int) -> Int32 {
        sortedTokens.withUnsafeBytes(of: index) { token in
            var count: Int32 = 0
            for byte in token where byte & 0xC0 != 0x80 { count &+= 1 }
            return count
        }
    }

    /// The largest value in ``sortedTokenCharCounts``.
    public let maxTokenChars: Int32
    /// `firstByteBounds[b]` is the index of the first sorted token that is not empty and starts
    /// with a byte `>= b` (257 entries, the last one `sortedTokens.count`): the tokens starting
    /// with `b` are `firstByteBounds[b] ..< firstByteBounds[b + 1]`.
    let firstByteBounds: [Int32]

    /// Pieces whose presence marks a token as a stop token when none are given explicitly:
    /// Llama 2 `</s>`, Llama 3 `<|end_of_text|>` / `<|eot_id|>`, Phi-2 `<|endoftext|>`, Gemma
    /// `<eos>` / `<end_of_turn>`, DeepSeek-V2 `<｜end▁of▁sentence｜>`.
    public static let detectedStopTokens: [String] = [
        "</s>", "<|end_of_text|>", "<|eot_id|>", "<|endoftext|>", "<eos>", "<|eos|>", "<end_of_turn>",
        "<｜end▁of▁sentence｜>",
    ]

    private static let detectedStopTokenBytes: [[UInt8]] = detectedStopTokens.map { Array($0.utf8) }

    /// Builds the tokenizer info from an encoded vocabulary.
    ///
    /// - Parameters:
    ///   - encodedVocab: The tokenizer's pieces, indexed by token id, spelled as `vocabType`
    ///     prescribes.
    ///   - vocabType: The vocabulary encoding.
    ///   - vocabSize: The model's vocabulary size; defaults to `encodedVocab.count`. Must not be
    ///     smaller than the number of pieces.
    ///   - stopTokenIDs: Explicit stop tokens. When `nil`, they are detected from
    ///     ``detectedStopTokens``.
    ///   - addPrefixSpace: Whether the tokenizer prepends a space to the text.
    public convenience init(
        encodedVocab: ByteStringTable,
        vocabType: VocabType = .raw,
        vocabSize: Int? = nil,
        stopTokenIDs: [Int32]? = nil,
        addPrefixSpace: Bool = false
    ) throws(TokenizerInfoError) {
        var decoded = ByteStringTable(capacity: encodedVocab.count, byteCapacity: encodedVocab.byteCount)
        encodedVocab.withUnsafeStorage { bytes, offsets in
            for id in 0 ..< encodedVocab.count {
                let piece = UnsafeBufferPointer(rebasing: bytes[Int(offsets[id]) ..< Int(offsets[id + 1])])
                decoded.append { TokenDecoder.decode(piece, as: vocabType, into: &$0) }
            }
        }
        decoded.compact()
        try self.init(encodedVocab: encodedVocab, decodedVocab: decoded, vocabType: vocabType,
                      vocabSize: vocabSize, stopTokenIDs: stopTokenIDs, addPrefixSpace: addPrefixSpace)
    }

    init(encodedVocab: ByteStringTable, decodedVocab decoded: ByteStringTable, vocabType: VocabType,
         vocabSize: Int?, stopTokenIDs: [Int32]?, addPrefixSpace: Bool) throws(TokenizerInfoError) {
        precondition(encodedVocab.count == decoded.count, "Encoded and decoded vocabularies must have the same length")
        var exceptionIDs: [Int32] = []
        var exceptions = ByteStringTable()
        var conventional: [UInt8] = []
        for id in 0 ..< encodedVocab.count {
            conventional.removeAll(keepingCapacity: true)
            TokenDecoder.appendConventionalPiece(decoded[id], as: vocabType, into: &conventional)
            if !encodedVocab[id].elementsEqual(conventional) {
                exceptionIDs.append(Int32(id))
                exceptions.append(encodedVocab[id])
            }
        }
        exceptions.compact()
        encodedExceptionIDs = exceptionIDs.compacted()
        encodedExceptions = exceptions
        let tokenCount = decoded.count
        let vocabSize = vocabSize ?? tokenCount
        guard vocabSize >= 0, vocabSize <= Int32.max else { throw .invalidVocabularySize(vocabSize) }
        guard vocabSize >= tokenCount else {
            throw .vocabSizeTooSmall(vocabSize: vocabSize, tokenCount: tokenCount)
        }
        self.vocabType = vocabType
        self.vocabSize = vocabSize
        self.addPrefixSpace = addPrefixSpace
        if let stopTokenIDs, let invalid = stopTokenIDs.first(where: { $0 < 0 || $0 >= vocabSize }) { throw .invalidStopTokenID(invalid) }

        // Partition ids into stop / special / regular.
        var stopIDs: [Int32] = []
        var specialIDs: [Int32] = []
        var regularIDs: [Int32] = []
        regularIDs.reserveCapacity(tokenCount)
        let explicitStops = stopTokenIDs.map(Set.init)
        for id in 0 ..< tokenCount {
            let token = decoded[id]
            let isStop: Bool =
                if let explicitStops { explicitStops.contains(Int32(id)) }
                else { Self.isDetectedStopToken(token) }
            if isStop {
                stopIDs.append(Int32(id))
            } else if token.isEmpty {
                specialIDs.append(Int32(id))
            } else {
                regularIDs.append(Int32(id))
            }
        }
        for id in tokenCount ..< vocabSize {
            if explicitStops?.contains(Int32(id)) == true { stopIDs.append(Int32(id)) }
            else { specialIDs.append(Int32(id)) }
        }
        self.stopTokenIDs = stopIDs.compacted()
        specialTokenIDs = specialIDs.compacted()

        // Sort regular tokens by their bytes.
        decoded.withUnsafeStorage { bytes, offsets in
            regularIDs.sort { lhs, rhs in
                Self.precedes(bytes, offsets, Int(lhs), Int(rhs))
            }
        }
        var sorted = ByteStringTable(capacity: regularIDs.count, byteCapacity: decoded.byteCount)
        for id in regularIDs { sorted.append(decoded[Int(id)]) }
        sorted.compact()
        sortedTokens = sorted
        sortedTokenIDs = regularIDs

        var indexByID = [Int32](repeating: -1, count: vocabSize)
        for (index, id) in regularIDs.enumerated() {
            indexByID[Int(id)] = Int32(index)
        }
        sortedIndexByTokenID = indexByID
        decodedVocab = DecodedVocabulary(decoded: decoded, sorted: sorted, sortedIndexByTokenID: indexByID)

        // Trie subtree bounds and code point counts in one pass over the sorted storage.
        let sortedCount = sorted.count
        var ends = [Int32](repeating: Int32(sortedCount), count: sortedCount)
        var maxChars: Int32 = 0
        var bounds = [Int32](repeating: Int32(sortedCount), count: 257)
        sorted.withUnsafeStorage { bytes, offsets in
            var prefixStack: [Int] = []
            var nextBound = 0
            for index in 0 ..< sortedCount {
                let start = Int(offsets[index]), end = Int(offsets[index + 1])
                if start < end {
                    while nextBound <= Int(bytes[start]) {
                        bounds[nextBound] = Int32(index)
                        nextBound += 1
                    }
                }
                while let top = prefixStack.last, !Self.isPrefix(bytes, offsets, top, ofRange: start ..< end) {
                    ends[top] = Int32(index)
                    prefixStack.removeLast()
                }
                prefixStack.append(index)
                var count: Int32 = 0
                for i in start ..< end where bytes[i] & 0xC0 != 0x80 { count += 1 }
                maxChars = max(maxChars, count)
            }
        }
        trieSubtreeEnds = ends
        maxTokenChars = maxChars
        firstByteBounds = bounds
    }

    /// Builds the tokenizer info from pieces given as strings. See ``init(encodedVocab:vocabType:vocabSize:stopTokenIDs:addPrefixSpace:)``.
    public convenience init(
        encodedVocab: [String],
        vocabType: VocabType = .raw,
        vocabSize: Int? = nil,
        stopTokenIDs: [Int32]? = nil,
        addPrefixSpace: Bool = false
    ) throws(TokenizerInfoError) {
        try self.init(
            encodedVocab: ByteStringTable(encodedVocab), vocabType: vocabType, vocabSize: vocabSize,
            stopTokenIDs: stopTokenIDs, addPrefixSpace: addPrefixSpace)
    }

    /// Builds the tokenizer info from pieces given as byte sequences, for vocabularies that are
    /// not valid UTF-8. See ``init(encodedVocab:vocabType:vocabSize:stopTokenIDs:addPrefixSpace:)``.
    public convenience init<Piece: Collection<UInt8>>(
        encodedVocab: [Piece],
        vocabType: VocabType = .raw,
        vocabSize: Int? = nil,
        stopTokenIDs: [Int32]? = nil,
        addPrefixSpace: Bool = false
    ) throws(TokenizerInfoError) {
        try self.init(
            encodedVocab: ByteStringTable(encodedVocab), vocabType: vocabType, vocabSize: vocabSize,
            stopTokenIDs: stopTokenIDs, addPrefixSpace: addPrefixSpace)
    }

    // MARK: - Lookup

    /// The decoded bytes of token `id`, or `nil` for padding ids beyond the decoded vocabulary.
    @inlinable
    public func token(_ id: Int) -> ArraySlice<UInt8>? {
        id >= 0 && id < decodedVocab.count ? decodedVocab[id] : nil
    }

    /// Whether `id` is a stop token.
    public func isStopToken(_ id: Int32) -> Bool {
        stopTokenIDs.contains(id)
    }

    /// `[#id <escaped>, …]`, truncated to `limit` entries (debug rendering shared with tests).
    func describeTokens(_ tokenIDs: [Int32], limit: Int) -> String {
        var result = "["
        let shown = Swift.min(tokenIDs.count, limit)
        for index in 0 ..< shown {
            let id = tokenIDs[index]
            result += "#\(id) <"
            if let token = token(Int(id)) { result += EscapeCodec.escaped(bytes: Array(token)) }
            result += ">"
            if index < shown - 1 { result += ", " }
        }
        if tokenIDs.count > limit { result += ", ..." }
        return result + "]"
    }

    // MARK: - Helpers

    private static func isDetectedStopToken(_ token: ArraySlice<UInt8>) -> Bool {
        let count = token.count
        return detectedStopTokenBytes.contains { $0.count == count && $0.elementsEqual(token) }
    }

    @inline(__always)
    private static func precedes(
        _ bytes: UnsafeBufferPointer<UInt8>, _ offsets: UnsafeBufferPointer<UInt32>, _ lhs: Int, _ rhs: Int
    ) -> Bool {
        let lstart = Int(offsets[lhs]), llen = Int(offsets[lhs + 1]) - lstart
        let rstart = Int(offsets[rhs]), rlen = Int(offsets[rhs + 1]) - rstart
        let common = min(llen, rlen)
        var i = 0
        while i < common {
            let l = bytes[lstart + i], r = bytes[rstart + i]
            if l != r { return l < r }
            i += 1
        }
        return llen < rlen
    }

    @inline(__always)
    private static func isPrefix(
        _ bytes: UnsafeBufferPointer<UInt8>, _ offsets: UnsafeBufferPointer<UInt32>, _ index: Int,
        ofRange range: Range<Int>
    ) -> Bool {
        let start = Int(offsets[index]), length = Int(offsets[index + 1]) - start
        guard length <= range.count else { return false }
        var i = 0
        while i < length {
            if bytes[start + i] != bytes[range.lowerBound + i] { return false }
            i += 1
        }
        return true
    }
}

extension TokenizerInfo: CustomStringConvertible {
    public var description: String {
        "TokenizerInfo(vocabType: \(vocabType), vocabSize: \(vocabSize), tokens: \(decodedVocab.count), "
            + "stopTokenIDs: \(stopTokenIDs), specialTokens: \(specialTokenIDs.count), addPrefixSpace: \(addPrefixSpace))"
    }
}
