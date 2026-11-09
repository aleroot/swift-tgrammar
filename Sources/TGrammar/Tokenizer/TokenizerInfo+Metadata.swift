// Compact metadata that, together with the encoded vocabulary, fully determines a
// `TokenizerInfo`. The JSON form is byte-compatible with upstream XGrammar's `dump_metadata`, so
// metadata produced by either implementation can be exchanged.

import Foundation

extension TokenizerInfo {
    /// Everything about a tokenizer that is not the vocabulary itself.
    public struct Metadata: Hashable, Sendable, Codable {
        public var vocabType: VocabType
        public var vocabSize: Int
        public var addPrefixSpace: Bool
        public var stopTokenIDs: [Int32]

        public init(vocabType: VocabType, vocabSize: Int, addPrefixSpace: Bool, stopTokenIDs: [Int32]) {
            self.vocabType = vocabType
            self.vocabSize = vocabSize
            self.addPrefixSpace = addPrefixSpace
            self.stopTokenIDs = stopTokenIDs
        }

        enum CodingKeys: String, CodingKey {
            case vocabType = "vocab_type"
            case vocabSize = "vocab_size"
            case addPrefixSpace = "add_prefix_space"
            case stopTokenIDs = "stop_token_ids"
        }

        /// Parses the JSON produced by ``json``.
        public init(json: String) throws(TokenizerInfoError) {
            do {
                self = try JSONDecoder().decode(Metadata.self, from: Data(json.utf8))
            } catch {
                throw .invalidMetadata(String(describing: error))
            }
        }

        /// The metadata as compact JSON, e.g.
        /// `{"vocab_type":1,"vocab_size":32000,"add_prefix_space":true,"stop_token_ids":[2]}`.
        public var json: String {
            let stops = stopTokenIDs.map(String.init).joined(separator: ",")
            return "{\"vocab_type\":\(vocabType.rawValue),\"vocab_size\":\(vocabSize),"
                + "\"add_prefix_space\":\(addPrefixSpace),\"stop_token_ids\":[\(stops)]}"
        }
    }

    /// The metadata of this tokenizer info.
    public var metadata: Metadata {
        Metadata(vocabType: vocabType, vocabSize: vocabSize, addPrefixSpace: addPrefixSpace, stopTokenIDs: stopTokenIDs)
    }

    /// Rebuilds a tokenizer info from an encoded vocabulary and previously exported metadata.
    public convenience init(encodedVocab: [String], metadata: Metadata) throws(TokenizerInfoError) {
        try self.init(
            encodedVocab: encodedVocab, vocabType: metadata.vocabType, vocabSize: metadata.vocabSize,
            stopTokenIDs: metadata.stopTokenIDs, addPrefixSpace: metadata.addPrefixSpace)
    }

    /// Rebuilds a tokenizer info from an encoded vocabulary and a metadata JSON string.
    public convenience init(encodedVocab: [String], metadataJSON: String) throws(TokenizerInfoError) {
        try self.init(encodedVocab: encodedVocab, metadata: Metadata(json: metadataJSON))
    }
}
