// Building a `TokenizerInfo` from a Hugging Face tokenizer: either from the `tokenizer.json`
// document alone, or from a live tokenizer object (e.g. a swift-tokenizers `Tokenizer`) that can
// report its pieces and encode a probe string. The latter mirrors upstream's
// `TokenizerInfo.from_huggingface`.

import Foundation

/// The minimal tokenizer surface needed to derive a ``TokenizerInfo``.
///
/// A concrete tokenizer can adopt this protocol. When an integration stores `any Tokenizer`,
/// forward these three members through a small wrapper; Swift protocols cannot retroactively
/// conform to another protocol.
public protocol TokenizerVocabulary {
    /// The piece token `id` names, or `nil` when the vocabulary has no entry for it.
    func convertIdToToken(_ id: Int) -> String?
    /// Encodes `text` into token ids.
    func encode(text: String, addSpecialTokens: Bool) -> [Int]
    /// The end-of-sequence token id, when the tokenizer declares one.
    var eosTokenId: Int? { get }
}

extension TokenizerInfo {
    /// Vocabulary encoding and prefix-space behaviour detected from a `tokenizer.json` document.
    public struct DetectedMetadata: Hashable, Sendable {
        public var vocabType: VocabType
        public var addPrefixSpace: Bool
    }

    /// Detects the vocabulary encoding and prefix-space behaviour from a Hugging Face
    /// `tokenizer.json` document.
    ///
    /// The encoding is read from the `decoder` field (`ByteLevel` or `ByteFallback`, possibly
    /// nested in a `Sequence`); anything else is ``VocabType/raw``. A prefix space is detected
    /// from a `{"type": "Prepend", "prepend": "▁"}` normalizer or a `Metaspace` pre-tokenizer
    /// with `prepend_scheme` `always` or `first`.
    public static func detectMetadata(fromTokenizerJSON data: Data) throws(TokenizerInfoError) -> DetectedMetadata {
        let document = try HuggingFaceTokenizerDocument(data: data)
        return document.detectedMetadata
    }

    /// Builds the tokenizer info from a Hugging Face `tokenizer.json` document.
    ///
    /// The vocabulary is read from `model.vocab` plus `added_tokens`, indexed by id. The encoding
    /// detected from the document is cross-checked against the vocabulary itself
    /// (`VocabType.detect(fromVocab:)`), which wins when the two disagree.
    ///
    /// - Parameters:
    ///   - tokenizerJSON: The contents of `tokenizer.json`.
    ///   - vocabSize: The model's vocabulary size. Defaults to the tokenizer's; a smaller value
    ///     drops the trailing ids (tokens the model cannot emit), a larger one pads.
    ///   - stopTokenIDs: Explicit stop tokens. `tokenizer.json` does not name the EOS token, so
    ///     when `nil` they are detected from ``detectedStopTokens``.
    public convenience init(
        tokenizerJSON: Data, vocabSize: Int? = nil, stopTokenIDs: [Int32]? = nil
    ) throws(TokenizerInfoError) {
        if let vocabSize, vocabSize < 0 || vocabSize > Int32.max { throw .invalidVocabularySize(vocabSize) }
        if let stopTokenIDs, stopTokenIDs.isEmpty { throw .emptyStopTokenIDs }
        let document = try HuggingFaceTokenizerDocument(data: tokenizerJSON)
        var metadata = document.detectedMetadata
        let pieces = document.vocabulary
        if let fromVocab = VocabType.detect(fromTable: pieces), fromVocab != metadata.vocabType {
            metadata.vocabType = fromVocab
        }
        let encodedVocab = Self.resize(pieces, to: vocabSize)
        try self.init(
            encodedVocab: encodedVocab, vocabType: metadata.vocabType, vocabSize: vocabSize ?? encodedVocab.count,
            stopTokenIDs: stopTokenIDs, addPrefixSpace: metadata.addPrefixSpace)
    }

    /// Builds the tokenizer info from a live tokenizer.
    ///
    /// Pieces are read through ``TokenizerVocabulary/convertIdToToken(_:)`` for ids
    /// `0 ..< vocabSize`; when `vocabSize` is `nil` the scan stops at the first missing id, so
    /// pass the model's vocabulary size for tokenizers whose id space has holes. The encoding
    /// comes from `tokenizerJSON` when given, cross-checked against the vocabulary itself; without
    /// the document it is detected from the vocabulary alone. Prefix-space behaviour is probed by
    /// encoding a one-character text, which reflects what the tokenizer actually does at runtime.
    ///
    /// - Parameters:
    ///   - tokenizer: The tokenizer.
    ///   - tokenizerJSON: The contents of `tokenizer.json`, if available.
    ///   - vocabSize: The model's vocabulary size.
    ///   - stopTokenIDs: Explicit stop tokens; defaults to the tokenizer's EOS token, falling back
    ///     to detection from ``detectedStopTokens``.
    public convenience init(
        tokenizer: some TokenizerVocabulary,
        tokenizerJSON: Data? = nil,
        vocabSize: Int? = nil,
        stopTokenIDs: [Int32]? = nil
    ) throws(TokenizerInfoError) {
        if let vocabSize, vocabSize < 0 || vocabSize > Int32.max { throw .invalidVocabularySize(vocabSize) }
        if let stopTokenIDs, stopTokenIDs.isEmpty { throw .emptyStopTokenIDs }

        var pieces: [String] = []
        if let vocabSize {
            pieces.reserveCapacity(vocabSize)
            for id in 0 ..< vocabSize { pieces.append(tokenizer.convertIdToToken(id) ?? "") }
        } else {
            while let piece = tokenizer.convertIdToToken(pieces.count) { pieces.append(piece) }
        }

        let fromVocab = VocabType.detect(fromVocab: pieces)
        let vocabType: VocabType
        let addPrefixSpace: Bool
        if let tokenizerJSON {
            let detected = try HuggingFaceTokenizerDocument(data: tokenizerJSON).detectedMetadata
            if let fromVocab, fromVocab != detected.vocabType {
                vocabType = fromVocab
                addPrefixSpace = Self.probeAddPrefixSpace(tokenizer, vocabType: vocabType)
            } else {
                vocabType = detected.vocabType
                addPrefixSpace = detected.addPrefixSpace
            }
        } else {
            vocabType = fromVocab ?? .raw
            addPrefixSpace = Self.probeAddPrefixSpace(tokenizer, vocabType: vocabType)
        }

        let stops = stopTokenIDs ?? tokenizer.eosTokenId.map { [Int32($0)] }
        try self.init(
            encodedVocab: pieces, vocabType: vocabType, vocabSize: vocabSize ?? pieces.count,
            stopTokenIDs: stops, addPrefixSpace: addPrefixSpace)
    }

    /// Whether encoding `"a"` yields a piece carrying the encoding's space marker.
    static func probeAddPrefixSpace(_ tokenizer: some TokenizerVocabulary, vocabType: VocabType) -> Bool {
        let marker: String
        switch vocabType {
        case .byteFallback: marker = "▁"
        case .byteLevel: marker = "Ġ"
        case .raw: return false
        }
        guard let first = tokenizer.encode(text: "a", addSpecialTokens: false).first,
              let piece = tokenizer.convertIdToToken(first)
        else { return false }
        return piece.hasPrefix(marker)
    }

    /// Pads with empty pieces or truncates so that the result has `vocabSize` entries.
    private static func resize(_ pieces: ByteStringTable, to vocabSize: Int?) -> ByteStringTable {
        guard let vocabSize, vocabSize != pieces.count else { return pieces }
        var result = ByteStringTable(capacity: vocabSize, byteCapacity: pieces.byteCount)
        for index in 0 ..< Swift.min(vocabSize, pieces.count) { result.append(pieces[index]) }
        for _ in pieces.count ..< Swift.max(vocabSize, pieces.count) { result.append(EmptyCollection()) }
        return result
    }
}

// MARK: - tokenizer.json

/// The parts of a Hugging Face `tokenizer.json` that matter for grammar-guided generation.
///
/// The vocabulary is read byte-exactly by ``TokenizerJSONScanner`` because Foundation's parsers
/// merge or alter some pieces. Only the small pipeline members (decoder, normalizer,
/// pre-tokenizer) go through `JSONSerialization`: parsing the whole document, merges included,
/// would allocate tens of megabytes of Foundation objects for a 150k-token vocabulary.
struct HuggingFaceTokenizerDocument {
    let root: [String: Any]
    let vocabulary: ByteStringTable

    private static let metadataKeys = ["decoder", "normalizer", "pre_tokenizer"]

    init(data: Data) throws(TokenizerInfoError) {
        let (vocabulary, members) = try TokenizerJSONScanner.scan(data, metadataKeys: Self.metadataKeys)
        let parsed = autoreleasepool { () -> Result<[String: Any], TokenizerInfoError> in
            var root: [String: Any] = [:]
            for (key, json) in members {
                do {
                    root[key] = try JSONSerialization.jsonObject(with: json, options: .fragmentsAllowed)
                } catch {
                    return .failure(.invalidTokenizerJSON(String(describing: error)))
                }
            }
            return .success(root)
        }
        root = try parsed.get()
        self.vocabulary = vocabulary
    }

    var detectedMetadata: TokenizerInfo.DetectedMetadata {
        .init(vocabType: vocabType, addPrefixSpace: hasPrependNormalizer || hasMetaspacePreTokenizer)
    }

    /// `ByteLevel` or `ByteFallback` from the `decoder` (possibly a `Sequence`), else raw.
    ///
    /// A `Metaspace` decoder (SentencePiece Unigram models such as T5 or NLLB) is reported as
    /// ``VocabType/byteFallback``: its only effect is `▁` → space, which is precisely what the
    /// byte-fallback decoder does when no `<0xNN>` pieces exist. Upstream leaves such
    /// vocabularies raw and would match the literal `▁` bytes instead of spaces.
    private var vocabType: VocabType {
        for component in components(of: "decoder", listKey: "decoders") {
            switch component["type"] as? String {
            case "ByteLevel": return .byteLevel
            case "ByteFallback", "Metaspace": return .byteFallback
            default: continue
            }
        }
        return .raw
    }

    /// `{"type": "Prepend", "prepend": "▁"}` in the normalizer (possibly a `Sequence`).
    private var hasPrependNormalizer: Bool {
        components(of: "normalizer", listKey: "normalizers").contains { component in
            component["type"] as? String == "Prepend" && component["prepend"] as? String == "▁"
        }
    }

    /// `{"type": "Metaspace", "prepend_scheme": "always" | "first"}` in the pre-tokenizer
    /// (possibly a `Sequence`).
    private var hasMetaspacePreTokenizer: Bool {
        components(of: "pre_tokenizer", listKey: "pretokenizers").contains { component in
            guard component["type"] as? String == "Metaspace",
                  let scheme = component["prepend_scheme"] as? String
            else { return false }
            return scheme == "always" || scheme == "first"
        }
    }

    /// The pipeline component at `key`, flattened when it is a `Sequence`.
    private func components(of key: String, listKey: String) -> [[String: Any]] {
        guard let component = root[key] as? [String: Any] else { return [] }
        if component["type"] as? String == "Sequence" {
            return component[listKey] as? [[String: Any]] ?? []
        }
        return [component]
    }
}
