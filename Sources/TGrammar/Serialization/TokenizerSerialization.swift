extension TokenizerInfo {
    /// A versioned snapshot. The optional `encoded_vocab` extension preserves original pieces
    /// for atomic structural-token lookup; upstream readers ignore the extension.
    public var serializedJSON: String { serializeJSON() }

    /// Set `preservingEncodedVocabulary` to false to emit exactly the upstream v18 fields.
    public func serializeJSON(preservingEncodedVocabulary: Bool = true) -> String {
        let s = SerializationValue.self
        var members: [(String, JSONValue)] = [
            ("vocab_type", s.number(vocabType.rawValue)), ("vocab_size", s.number(vocabSize)),
            ("add_prefix_space", .bool(addPrefixSpace)), ("stop_token_ids", s.numbers(stopTokenIDs)),
            ("special_token_ids", s.numbers(specialTokenIDs)),
            ("decoded_vocab", .array((0 ..< decodedVocab.count).map { s.bytes(decodedVocab[$0]) })),
            ("sorted_decoded_vocab", .array(sortedTokenIDs.enumerated().map { .array([s.number($0.element), s.bytes(sortedTokens[$0.offset])]) })),
            ("trie_subtree_nodes_range", s.numbers(trieSubtreeEnds)),
        ]
        if preservingEncodedVocabulary {
            let encoded = encodedVocab
            members.append(("encoded_vocab", .array((0 ..< encoded.count).map { s.bytes(encoded[$0]) })))
        }
        return s.object(members, versioned: true).serialized()
    }

    public convenience init(serializedJSON: String) throws(SerializationError) {
        let s = SerializationValue.self
        let value = try s.parse(serializedJSON)
        let typeID: Int32 = try s.integer(s.required(value, "vocab_type"))
        guard let type = VocabType(rawValue: typeID) else { throw .format("Unknown vocabulary type") }
        let size: Int = try s.integer(s.required(value, "vocab_size"))
        let prefix = try s.bool(s.required(value, "add_prefix_space"))
        let stops: [Int32] = try s.integers(s.required(value, "stop_token_ids"))
        let special: [Int32] = try s.integers(s.required(value, "special_token_ids"))
        let decoded = ByteStringTable(try s.array(s.required(value, "decoded_vocab")).map { raw throws(SerializationError) in try s.decodeBytes(raw) })
        try s.check(size >= decoded.count && size <= Int32.max, "Vocabulary size is out of range")
        for ids in [stops, special] { try s.check(ids == Array(Set(ids)).sorted() && ids.allSatisfy { $0 >= 0 && $0 < size }, "Invalid stop or special IDs") }
        let encoded: ByteStringTable
        if let pieces = value["encoded_vocab"] {
            encoded = ByteStringTable(try s.array(pieces).map { raw throws(SerializationError) in try s.decodeBytes(raw) })
            try s.check(encoded.count == decoded.count, "Encoded and decoded vocabulary sizes differ")
            var rebuilt = ByteStringTable(capacity: encoded.count, byteCapacity: decoded.byteCount)
            encoded.withUnsafeStorage { bytes, offsets in
                for id in 0 ..< encoded.count {
                    rebuilt.append { TokenDecoder.decode(UnsafeBufferPointer(rebasing: bytes[Int(offsets[id]) ..< Int(offsets[id + 1])]), as: type, into: &$0) }
                }
            }
            try s.check((0 ..< decoded.count).allSatisfy { decoded[$0].elementsEqual(rebuilt[$0]) }, "Encoded vocabulary does not match decoded bytes")
        } else {
            // Upstream snapshots only retain decoded bytes. Reconstruct conventional pieces;
            // exact original special-token spellings require the optional extension above.
            var pieces = ByteStringTable(capacity: decoded.count, byteCapacity: decoded.byteCount)
            for id in 0 ..< decoded.count {
                pieces.append { TokenDecoder.appendConventionalPiece(decoded[id], as: type, into: &$0) }
            }
            encoded = pieces
        }
        // Build derived indexes once. If validation below fails, this non-escaping instance is
        // discarded; no second vocabulary sort is needed on a successful cache load.
        do { try self.init(encodedVocab: encoded, decodedVocab: decoded, vocabType: type, vocabSize: size, stopTokenIDs: stops, addPrefixSpace: prefix) }
        catch { throw .format(error.description) }
        try s.check(stopTokenIDs == stops && specialTokenIDs == special, "Token partitions do not match decoded vocabulary")
        let sorted = try s.array(s.required(value, "sorted_decoded_vocab"))
        try s.check(sorted.count == sortedTokens.count, "Sorted vocabulary size mismatch")
        for (index, raw) in sorted.enumerated() {
            let pair = try s.array(raw, count: 2)
            let id: Int32 = try s.integer(pair[0])
            let bytes = try s.decodeBytes(pair[1])
            try s.check(id == sortedTokenIDs[index] && bytes.elementsEqual(sortedTokens[index]), "Sorted vocabulary does not match decoded vocabulary")
        }
        let ranges: [Int32] = try s.integers(s.required(value, "trie_subtree_nodes_range"))
        try s.check(ranges == trieSubtreeEnds, "Invalid trie subtree ranges")
    }
}
