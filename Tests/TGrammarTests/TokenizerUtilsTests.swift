// Port of xgrammar's tests/python/test_tokenizer_utils.py: the test-side tokenizer loader
// (`tokenizer_utils.load_tokenizer`) reuses loads across tests, isolates every caller's state, and
// never caches a failed load. The Swift loader is `LocalTokenizers` over `TokenizerLoadCache`; the
// upstream fixture is a two-piece `WordLevel` tokenizer saved with `save_pretrained`.

import Foundation
import Testing

@testable import TGrammar

@Suite("Tokenizer utils")
struct TokenizerUtilsTests {
    private struct LoadFailure: Error, Equatable { let message = "Tokenizer download failed" }

    /// `PreTrainedTokenizerFast(tokenizer_object=Tokenizer(WordLevel({"[UNK]": 0, "hello": 1},
    /// unk_token="[UNK]")), unk_token="[UNK]").save_pretrained(tmp_path)`.
    private static func saveWordLevelTokenizer() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgrammar-tokenizer-utils-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tokenizerJSON = """
            {"version":"1.0","truncation":null,"padding":null,"added_tokens":[{"id":0,"content":"[UNK]","single_word":false,"lstrip":false,"rstrip":false,"normalized":false,"special":true}],"normalizer":null,"pre_tokenizer":null,"post_processor":null,"decoder":null,"model":{"type":"WordLevel","vocab":{"[UNK]":0,"hello":1},"unk_token":"[UNK]"}}
            """
        let tokenizerConfig = """
            {"added_tokens_decoder":{"0":{"content":"[UNK]","lstrip":false,"normalized":false,"rstrip":false,"single_word":false,"special":true}},"clean_up_tokenization_spaces":false,"model_max_length":1000000000000000019884624838656,"tokenizer_class":"PreTrainedTokenizerFast","unk_token":"[UNK]"}
            """
        try Data(tokenizerJSON.utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        try Data(tokenizerConfig.utf8).write(to: directory.appendingPathComponent("tokenizer_config.json"))
        return directory
    }

    @Test func cachedTokenizersAreIndependent() throws {
        let directory = try Self.saveWordLevelTokenizer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TokenizerLoadCache<LocalTokenizers.Request, LocalTokenizers.Loaded>()
        let request = LocalTokenizers.Request(directory: directory)

        let first = try cache.value(for: request, load: LocalTokenizers.load)
        let second = try cache.value(for: request, load: LocalTokenizers.load)
        #expect(cache.loadCount == 1)
        // Upstream deep-copies because Hugging Face tokenizers are mutable; `TokenizerInfo` is an
        // immutable `Sendable` class, so the one instance is shared and already isolated.
        #expect(first.info === second.info)
        #expect(first.info.tokenID(for: "hello") == 1)
        #expect(second.info.tokenID(for: "hello") == 1)
        #expect(first.info.vocabSize == 2)

        // `first.add_special_tokens({"pad_token": "[PAD]"})` has no Swift counterpart: nothing on
        // a `TokenizerInfo` can be changed after loading. Later loads see the saved files only.
        let third = try cache.value(for: request, load: LocalTokenizers.load)
        #expect(cache.loadCount == 1)
        for other in [second, third] {
            #expect(other.info.tokenID(for: "[PAD]") == nil)
            #expect(other.info.vocabSize == 2)
            #expect(other.eosTokenID == nil)
            #expect(other.info.stopTokenIDs.isEmpty)
        }

        // `load_tokenizer(tmp_path, padding_side="left")`: a different keyword argument is a
        // different cache entry, and the default entry keeps its settings.
        let explicitStop = LocalTokenizers.Request(directory: directory, stopTokenIDs: [1])
        let leftPadding = try cache.value(for: explicitStop, load: LocalTokenizers.load)
        #expect(leftPadding.info.stopTokenIDs == [1])
        #expect(third.info.stopTokenIDs.isEmpty)
        #expect(cache.loadCount == 2)
        #expect(try cache.value(for: explicitStop, load: LocalTokenizers.load).info === leftPadding.info)
        #expect(cache.loadCount == 2)
    }

    @Test func failedTokenizerLoadIsNotCached() throws {
        let cache = TokenizerLoadCache<LocalTokenizers.Request, LocalTokenizers.Loaded>()
        let request = LocalTokenizers.Request(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("tgrammar-tokenizer-utils-missing-\(UUID().uuidString)"))

        // `monkeypatch.setattr(AutoTokenizer, "from_pretrained", failing_load)`.
        for _ in 0 ..< 2 {
            #expect(throws: LoadFailure()) {
                try cache.value(for: request) { _ in throw LoadFailure() }
            }
        }
        #expect(cache.loadCount == 2)

        // The real loader on a directory that was never saved fails the same way every time.
        for _ in 0 ..< 2 {
            #expect {
                try cache.value(for: request, load: LocalTokenizers.load)
            } throws: { error in
                (error as? CocoaError)?.code == .fileReadNoSuchFile
            }
        }
        #expect(cache.loadCount == 4)
    }
}
