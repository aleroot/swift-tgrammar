// Port of the tokenizer-independent parts of xgrammar's tests/python/test_tokenizer_info.py and
// the TokenizerInfo fixture of test_serialization.py. Cases that download Hugging Face tokenizers
// upstream are reproduced here with hand-built vocabularies and inline tokenizer.json fixtures.

import Foundation
import Testing

@testable import TGrammar

@Suite("Tokenizer info")
struct TokenizerInfoTests {
    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    // MARK: Vocabulary decoding

    @Test func byteFallbackDecoding() throws {
        let info = try TokenizerInfo(
            encodedVocab: ["<0x01>", "▁▁", "er", "▁исследова", "<0xff>", "<0xG1>", "</s>"],
            vocabType: .byteFallback)
        #expect(Array(info.decodedVocab[0]) == [0x01])
        #expect(Array(info.decodedVocab[1]) == bytes("  "))
        #expect(Array(info.decodedVocab[2]) == bytes("er"))
        #expect(Array(info.decodedVocab[3]) == bytes(" исследова"))
        #expect(Array(info.decodedVocab[4]) == [0xFF])
        #expect(Array(info.decodedVocab[5]) == bytes("<0xG1>"))
        #expect(info.stopTokenIDs == [6])
    }

    @Test func byteLevelDecoding() throws {
        let info = try TokenizerInfo(
            encodedVocab: ["\"", "ä½ł", "Ġautomotive", "Ċ", "ġ", "<|eot_id|>", "日本"],
            vocabType: .byteLevel)
        #expect(Array(info.decodedVocab[0]) == bytes("\""))
        #expect(Array(info.decodedVocab[1]) == bytes("你"))
        #expect(Array(info.decodedVocab[2]) == bytes(" automotive"))
        #expect(Array(info.decodedVocab[3]) == [0x0A])
        #expect(Array(info.decodedVocab[4]) == [0x7F])
        // Scalars outside the byte-level alphabet keep the piece verbatim.
        #expect(Array(info.decodedVocab[5]) == bytes("<|eot_id|>"))
        #expect(Array(info.decodedVocab[6]) == bytes("日本"))
        #expect(info.stopTokenIDs == [5])
    }

    @Test func rawVocabularyIsKeptVerbatim() throws {
        let pieces: [[UInt8]] = [bytes("+"), [0xA1], bytes("我"), bytes("<0x0A>"), bytes("Ġx")]
        let info = try TokenizerInfo(encodedVocab: pieces, vocabType: .raw)
        for (id, piece) in pieces.enumerated() {
            #expect(Array(info.decodedVocab[id]) == piece)
        }
        #expect(info.stopTokenIDs.isEmpty)
    }

    @Test func byteLevelAlphabetRoundTrips() {
        for byte in 0 ..< 256 {
            let scalar = ByteLevelAlphabet.byteToScalar[byte]
            #expect(ByteLevelAlphabet.byte(for: scalar) == UInt8(byte))
        }
        #expect(ByteLevelAlphabet.characters.count == 256)
        #expect(ByteLevelAlphabet.byte(for: 0x120) == 0x20)
        #expect(ByteLevelAlphabet.byte(for: 0x144) == nil)
        #expect(ByteLevelAlphabet.byte(for: 0xAD) == nil)
    }

    // MARK: Stop and special tokens

    @Test func specialTokenDetection() throws {
        // Only the empty string is treated as a special token.
        let vocab = ["", "<s>", "</s>", "[@BOS@]", "regular", "<>", "<think>", "</think>"]
        let info = try TokenizerInfo(
            encodedVocab: vocab,
            metadataJSON: #"{"vocab_type":1,"vocab_size":8,"add_prefix_space":true,"stop_token_ids":[2]}"#)
        #expect(Set(info.specialTokenIDs) == [0])
        #expect(info.stopTokenIDs == [2])
        #expect(info.vocabType == .byteFallback)
        #expect(info.addPrefixSpace)
    }

    @Test(arguments: TokenizerInfo.detectedStopTokens)
    func stopTokenAutoDetection(stop: String) throws {
        let info = try TokenizerInfo(encodedVocab: ["a", stop, "b"])
        #expect(info.stopTokenIDs == [1])
        #expect(info.sortedTokenIDs == [0, 2])
    }

    @Test func customizeStopTokenIDs() throws {
        let info = try TokenizerInfo(encodedVocab: ["</s>", "a", "b", "c", "d"], stopTokenIDs: [1, 2, 3])
        #expect(info.stopTokenIDs == [1, 2, 3])
        // Explicit stop ids disable detection: `</s>` is a regular token here.
        #expect(info.sortedTokenIDs == [0, 4])
    }

    @Test func paddingVocabSize() throws {
        let vocab = (0 ..< 100).map(String.init)
        let info = try TokenizerInfo(encodedVocab: vocab, vocabSize: 105)
        #expect(info.vocabSize == 105)
        #expect(info.decodedVocab.count == 100)
        #expect(info.specialTokenIDs.suffix(5) == [100, 101, 102, 103, 104])
        #expect(info.token(104) == nil)
        #expect(info.sortedIndexByTokenID.count == 105)
        #expect(info.sortedIndexByTokenID[104] == -1)
    }

    @Test func vocabSizeSmallerThanVocabIsRejected() {
        let vocab = (0 ..< 100).map(String.init)
        #expect(throws: TokenizerInfoError.vocabSizeTooSmall(vocabSize: 1, tokenCount: 100)) {
            try TokenizerInfo(encodedVocab: vocab, vocabSize: 1)
        }
    }

    @Test func invalidModelWidthsAndStopIDsAreRejected() throws {
        for width in [-1, Int(Int32.max) + 1] {
            #expect(throws: TokenizerInfoError.invalidVocabularySize(width)) { try TokenizerInfo(encodedVocab: ["a"], vocabSize: width) }
            #expect(throws: TokenizerInfoError.invalidVocabularySize(width)) { try TokenizerInfo(tokenizerJSON: Data("{}".utf8), vocabSize: width) }
        }
        for id: Int32 in [-1, 2] {
            #expect(throws: TokenizerInfoError.invalidStopTokenID(id)) { try TokenizerInfo(encodedVocab: ["a", "b"], stopTokenIDs: [id]) }
        }
    }

    @Test func explicitStopInModelPadding() throws {
        let info = try TokenizerInfo(encodedVocab: ["a", "b"], vocabSize: 5, stopTokenIDs: [4])
        #expect(info.stopTokenIDs == [4] && info.specialTokenIDs == [2, 3])
        let restored = try TokenizerInfo(serializedJSON: info.serializedJSON)
        var matcher = GrammarMatcher(try GrammarCompiler(tokenizerInfo: restored).compile(ebnf: "root ::= \"a\""))
        let accepted = matcher.acceptToken(0)
        let mask = matcher.nextTokenBitmask()
        #expect(accepted && mask.allowedTokenIDs == [4])
        let stopped = matcher.acceptToken(4)
        #expect(stopped && matcher.isTerminated)
    }

    // MARK: Sorted vocabulary and trie

    /// The fixture of upstream test_serialization.py.
    private func fixture() throws -> TokenizerInfo {
        try TokenizerInfo(
            encodedVocab: ["1", "212", "a", "A", "b", "一", "-", "aBc", "abc"],
            vocabType: .byteFallback, vocabSize: 10, stopTokenIDs: [0, 1], addPrefixSpace: true)
    }

    @Test func sortedVocabularyAndTrieRanges() throws {
        let info = try fixture()
        #expect(info.stopTokenIDs == [0, 1])
        #expect(info.specialTokenIDs == [9])
        #expect(info.sortedTokenIDs == [6, 3, 2, 7, 8, 4, 5])
        #expect(info.sortedTokens.map { String(decoding: $0, as: UTF8.self) } == ["-", "A", "a", "aBc", "abc", "b", "一"])
        #expect(info.trieSubtreeEnds == [1, 2, 5, 4, 5, 6, 7])
        #expect(info.sortedTokenCharCounts == [1, 1, 1, 3, 3, 1, 1])
        #expect(info.maxTokenChars == 3)
        #expect(info.sortedIndexByTokenID == [-1, -1, 2, 1, 5, 6, 0, 3, 4, -1])
    }

    @Test func trieRangesUseTruePrefixes() throws {
        // "a" is a substring of "ba" but not a prefix: "ba" must not fall into the subtree of "a".
        let info = try TokenizerInfo(encodedVocab: ["a", "ba", "ab", "abc", "b"])
        #expect(info.sortedTokens.map { String(decoding: $0, as: UTF8.self) } == ["a", "ab", "abc", "b", "ba"])
        #expect(info.trieSubtreeEnds == [3, 3, 3, 5, 5])
    }

    @Test func charCountsCountCodePoints() throws {
        let info = try TokenizerInfo(encodedVocab: ["日本語", "🌎x", "<0x80>"], vocabType: .byteFallback)
        // Sorted by bytes: 0x80 (a lone continuation byte, zero chars) < 0xE6 (日) < 0xF0 (🌎).
        #expect(info.sortedTokens.map { Array($0) } == [[0x80], bytes("日本語"), bytes("🌎x")])
        #expect(info.sortedTokenCharCounts == [0, 3, 2])
        #expect(info.maxTokenChars == 3)
    }

    // MARK: Metadata

    @Test func metadataDumpAndLoad() throws {
        let info = try fixture()
        let json = info.metadata.json
        #expect(json == #"{"vocab_type":1,"vocab_size":10,"add_prefix_space":true,"stop_token_ids":[0,1]}"#)

        let loaded = try TokenizerInfo(
            encodedVocab: ["1", "212", "a", "A", "b", "一", "-", "aBc", "abc"], metadataJSON: json)
        #expect(loaded.decodedVocab == info.decodedVocab)
        #expect(loaded.metadata == info.metadata)
        #expect(loaded.sortedTokenIDs == info.sortedTokenIDs)

        // Decoded bytes are a raw vocabulary that decodes to itself.
        let reloaded = try TokenizerInfo(encodedVocab: Array(info.decodedVocab), vocabType: .raw)
        #expect(reloaded.decodedVocab == info.decodedVocab)
    }

    @Test(arguments: [
        #"{"vocab_type":7,"vocab_size":10,"add_prefix_space":true,"stop_token_ids":[0]}"#,
        #"{"vocab_size":10,"add_prefix_space":true,"stop_token_ids":[0]}"#,
        #"{"vocab_type":1,"vocab_size":10,"add_prefix_space":true,"stop_token_ids":["x"]}"#,
        "not json",
    ])
    func invalidMetadataIsRejected(json: String) {
        #expect(throws: TokenizerInfoError.self) {
            try TokenizerInfo.Metadata(json: json)
        }
    }

    // MARK: Vocabulary type detection

    private static let byteFallbackVocab: [String] =
        (0 ..< 256).map(TokenDecoder.byteFallbackPiece) + ["▁hello", "▁world", "你好"]
    private static let byteLevelVocab: [String] =
        ByteLevelAlphabet.characters.sorted() + ["Ġhello", "ä½ł", "<|endoftext|>"]
    /// A large multilingual byte-fallback vocabulary may contain the whole byte-level alphabet as
    /// ordinary pieces (e.g. Gemma); the byte pieces must take precedence.
    private static let mixedVocab: [String] = byteLevelVocab + byteFallbackVocab
    /// A plain-text vocabulary (e.g. WordPiece) matches neither encoding.
    private static let rawVocab: [String] = ["hello", "##ing", "你", "好", "a", "!"]

    @Test(arguments: [
        (byteFallbackVocab, VocabType.byteFallback),
        (byteLevelVocab, .byteLevel),
        (mixedVocab, .byteFallback),
        (rawVocab, nil),
    ])
    func detectVocabTypeFromVocab(vocab: [String], expected: VocabType?) {
        #expect(VocabType.detect(fromVocab: vocab) == expected)
    }

    @Test func byteFallbackPieceSpelling() {
        #expect(TokenDecoder.byteFallbackPiece(0x0A) == "<0x0A>")
        #expect(TokenDecoder.byteFallbackPiece(0xFF) == "<0xFF>")
        #expect(TokenDecoder.byteFallbackPiece(0x00) == "<0x00>")
    }

    // MARK: tokenizer.json

    private func document(_ json: String) -> Data { Data(json.utf8) }

    @Test(arguments: [
        (#"{"decoder":{"type":"ByteLevel"}}"#, VocabType.byteLevel, false),
        (#"{"decoder":{"type":"Sequence","decoders":[{"type":"Replace"},{"type":"ByteFallback"},{"type":"Fuse"}]}}"#, .byteFallback, false),
        (#"{"decoder":{"type":"WordPiece"}}"#, .raw, false),
        (#"{"decoder":{"type":"Metaspace"}}"#, .byteFallback, false),
        (#"{"model":{}}"#, .raw, false),
        (#"{"decoder":{"type":"ByteFallback"},"normalizer":{"type":"Sequence","normalizers":[{"type":"Prepend","prepend":"▁"},{"type":"Replace"}]}}"#, .byteFallback, true),
        (#"{"decoder":{"type":"ByteFallback"},"normalizer":{"type":"Prepend","prepend":"▁"}}"#, .byteFallback, true),
        (#"{"decoder":{"type":"ByteFallback"},"normalizer":{"type":"Prepend","prepend":"_"}}"#, .byteFallback, false),
        (#"{"decoder":{"type":"ByteFallback"},"pre_tokenizer":{"type":"Metaspace","prepend_scheme":"always"}}"#, .byteFallback, true),
        (#"{"decoder":{"type":"ByteFallback"},"pre_tokenizer":{"type":"Metaspace","prepend_scheme":"first"}}"#, .byteFallback, true),
        (#"{"decoder":{"type":"ByteFallback"},"pre_tokenizer":{"type":"Metaspace","prepend_scheme":"never"}}"#, .byteFallback, false),
        (#"{"decoder":{"type":"ByteLevel"},"pre_tokenizer":{"type":"Sequence","pretokenizers":[{"type":"Metaspace","prepend_scheme":"first"}]}}"#, .byteLevel, true),
    ])
    func detectMetadataFromTokenizerJSON(json: String, vocabType: VocabType, addPrefixSpace: Bool) throws {
        let detected = try TokenizerInfo.detectMetadata(fromTokenizerJSON: document(json))
        #expect(detected.vocabType == vocabType)
        #expect(detected.addPrefixSpace == addPrefixSpace)
    }

    @Test func invalidTokenizerJSONIsRejected() {
        #expect(throws: TokenizerInfoError.self) {
            try TokenizerInfo.detectMetadata(fromTokenizerJSON: document("[1, 2]"))
        }
        #expect(throws: TokenizerInfoError.self) {
            try TokenizerInfo.detectMetadata(fromTokenizerJSON: document("{"))
        }
    }

    @Test func buildFromTokenizerJSON() throws {
        let json = #"""
            {
              "normalizer": {"type": "Prepend", "prepend": "▁"},
              "decoder": {"type": "Sequence", "decoders": [{"type": "ByteFallback"}]},
              "added_tokens": [{"id": 0, "content": "<unk>"}, {"id": 1, "content": "<s>"}, {"id": 2, "content": "</s>"}],
              "model": {"type": "BPE", "vocab": {"<unk>": 0, "<s>": 1, "</s>": 2, "<0x0A>": 3, "▁hello": 4, "▁world": 6}}
            }
            """#
        let info = try TokenizerInfo(tokenizerJSON: document(json))
        #expect(info.vocabType == .byteFallback)
        #expect(info.addPrefixSpace)
        #expect(info.vocabSize == 7)
        #expect(info.stopTokenIDs == [2])
        #expect(Array(info.decodedVocab[3]) == [0x0A])
        #expect(Array(info.decodedVocab[4]) == bytes(" hello"))
        #expect(Array(info.decodedVocab[5]).isEmpty)  // hole in the id space
        #expect(info.specialTokenIDs == [5])

        let padded = try TokenizerInfo(tokenizerJSON: document(json), vocabSize: 32, stopTokenIDs: [1])
        #expect(padded.vocabSize == 32)
        #expect(padded.stopTokenIDs == [1])
        #expect(padded.specialTokenIDs.count == 1 + 25)

        let truncated = try TokenizerInfo(tokenizerJSON: document(json), vocabSize: 5)
        #expect(truncated.vocabSize == 5)
        #expect(truncated.decodedVocab.count == 5)
    }

    /// Foundation's parsers lose vocabulary pieces: `JSONSerialization` strips a leading U+FEFF
    /// from strings, and `String`-keyed objects merge canonically equivalent pieces. The Llama 2
    /// vocabulary has both (ids 30143 and seven NFC/NFD pairs); every id must keep its own bytes.
    @Test func tokenizerJSONPiecesAreReadByteExactly() throws {
        let json = #"""
            {"model": {"type": "BPE", "vocab": {"\u00e9": 0, "e\u0301": 1, "\ufeff": 2, "\ufeffx": 3,
                                                "esc\"\\\/\b\f\n\r\t": 4, "\ud83d\ude00": 5, "plain": 6}},
             "added_tokens": [{"id": 7, "content": "<|added\u00e9|>", "special": true}, {"id": -1, "content": "skip"}],
             "decoder": {"type": "ByteLevel"}, "merges": ["a b", "{ }"], "extra": [{"vocab": {"x": 99}}]}
            """#
        let info = try TokenizerInfo(tokenizerJSON: document(json))
        #expect(info.vocabSize == 8)
        #expect(Array(info.encodedVocab[0]) == [0xC3, 0xA9])
        #expect(Array(info.encodedVocab[1]) == [0x65, 0xCC, 0x81])
        #expect(Array(info.encodedVocab[2]) == [0xEF, 0xBB, 0xBF])
        #expect(Array(info.encodedVocab[3]) == [0xEF, 0xBB, 0xBF, 0x78])
        #expect(Array(info.encodedVocab[4]) == bytes("esc\"\\/\u{08}\u{0C}\n\r\t"))
        #expect(Array(info.encodedVocab[5]) == bytes("😀"))
        #expect(Array(info.encodedVocab[7]) == bytes("<|addedé|>"))
        #expect(info.specialTokenIDs.isEmpty)
        #expect(throws: TokenizerInfoError.self) { try TokenizerInfo(tokenizerJSON: document(#"{"model": {"vocab": {"a": 1.5}}}"#)) }
    }

    @Test func unigramVocabularyFromTokenizerJSON() throws {
        let json = #"""
            {"model": {"type": "Unigram", "vocab": [["<unk>", 0.0], ["▁the", -3.2], ["s", -4.1]]},
             "decoder": {"type": "Metaspace"}, "pre_tokenizer": {"type": "Metaspace", "prepend_scheme": "always"}}
            """#
        let info = try TokenizerInfo(tokenizerJSON: document(json))
        // A Metaspace decoder decodes like byte-fallback: `▁` becomes a space.
        #expect(info.vocabType == .byteFallback)
        #expect(info.addPrefixSpace)
        #expect(info.decodedVocab.map { String(decoding: $0, as: UTF8.self) } == ["<unk>", " the", "s"])
    }

    @Test func vocabularyOverridesTokenizerJSONDecoder() throws {
        // The document claims a byte-level decoder but the pieces are clearly byte-fallback.
        let vocab = Self.byteFallbackVocab.map { "\"\($0)\"" }.enumerated().map { "\($1): \($0)" }.joined(separator: ",")
        let json = #"{"decoder":{"type":"ByteLevel"},"model":{"vocab":{"# + vocab + "}}}"
        let info = try TokenizerInfo(tokenizerJSON: document(json))
        #expect(info.vocabType == .byteFallback)
        #expect(Array(info.decodedVocab[0x41]) == [0x41])
        #expect(Array(info.decodedVocab[256]) == bytes(" hello"))
    }

    // MARK: Live tokenizer

    /// A tiny stand-in for a swift-tokenizers `Tokenizer`.
    private struct FakeTokenizer: TokenizerVocabulary {
        var pieces: [String]
        var eosTokenId: Int?
        var prefixSpace: Bool

        func convertIdToToken(_ id: Int) -> String? { id < pieces.count ? pieces[id] : nil }
        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            let spelled = (prefixSpace ? "▁" : "") + text
            return [pieces.firstIndex(of: spelled) ?? 0]
        }
    }

    @Test func buildFromLiveTokenizer() throws {
        let tokenizer = FakeTokenizer(pieces: Self.byteFallbackVocab + ["▁a", "</s>"], eosTokenId: 260, prefixSpace: true)
        let info = try TokenizerInfo(tokenizer: tokenizer)
        #expect(info.vocabType == .byteFallback)
        #expect(info.addPrefixSpace)
        #expect(info.stopTokenIDs == [260])
        #expect(info.vocabSize == 261)
        #expect(Array(info.decodedVocab[259]) == bytes(" a"))

        let noPrefix = FakeTokenizer(pieces: Self.byteFallbackVocab + ["a"], eosTokenId: nil, prefixSpace: false)
        let detected = try TokenizerInfo(tokenizer: noPrefix, vocabSize: 300, stopTokenIDs: [0])
        #expect(!detected.addPrefixSpace)
        #expect(detected.vocabSize == 300)
        #expect(detected.stopTokenIDs == [0])
        #expect(detected.specialTokenIDs == Array(260 ..< 300))

        #expect(throws: TokenizerInfoError.emptyStopTokenIDs) {
            try TokenizerInfo(tokenizer: noPrefix, stopTokenIDs: [])
        }
    }

    @Test func liveTokenizerPrefersVocabularyOverDocument() throws {
        let tokenizer = FakeTokenizer(pieces: Self.byteFallbackVocab + ["▁a"], eosTokenId: 0, prefixSpace: true)
        // tokenizer.json claims byte-level and no prefix space; the vocabulary says otherwise.
        let info = try TokenizerInfo(tokenizer: tokenizer, tokenizerJSON: document(#"{"decoder":{"type":"ByteLevel"}}"#))
        #expect(info.vocabType == .byteFallback)
        #expect(info.addPrefixSpace)
    }

    // MARK: ByteStringTable

    @Test func byteStringTable() {
        var table = ByteStringTable(["ab", "", "cde"])
        #expect(table.count == 3)
        #expect(table.byteCount == 5)
        #expect(Array(table[0]) == bytes("ab"))
        #expect(table[1].isEmpty)
        #expect(table.length(at: 2) == 3)
        table.append(bytes("f"))
        table.append { $0.append(contentsOf: [0x01, 0x02]) }
        #expect(table.count == 5)
        #expect(Array(table[4]) == [0x01, 0x02])
        table.withUnsafeBytes(of: 2) { #expect(Array($0) == bytes("cde")) }
        #expect(table.map(Array.init) == [bytes("ab"), [], bytes("cde"), bytes("f"), [0x01, 0x02]])
        #expect(ByteStringTable(["ab", "c"]) == ByteStringTable([bytes("ab"), bytes("c")]))
        #expect(ByteStringTable(["ab", "c"]) != ByteStringTable(["a", "bc"]))
    }
}
