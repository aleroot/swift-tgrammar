// Real vocabularies for the upstream tests marked `hf_token_required`.
//
// The tests are skipped when the vocabulary is not in the local Hugging Face cache; nothing is
// downloaded. Several gated upstream tokenizers have ungated repositories that ship the
// identical `tokenizer.json` vocabulary; those are accepted as stand-ins. The stop token is the
// tokenizer's `eos_token`, which is what upstream's `TokenizerInfo.from_huggingface` uses.

import Foundation
import Synchronization

@testable import TGrammar

/// Upstream's `tokenizer_utils.load_tokenizer`: each distinct request is loaded once and the result
/// shared by every test that asks for it. Upstream `deepcopy`s the cached tokenizer because Hugging
/// Face tokenizers are mutable; a `TokenizerInfo` is immutable, so sharing the instance is already
/// isolated. Failed loads are not cached, as `lru_cache` does not cache exceptions.
final class TokenizerLoadCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct State {
        var entries: [Key: Value] = [:]
        var loads = 0
    }

    private let state = Mutex(State())

    /// How many times a loader ran.
    var loadCount: Int { state.withLock { $0.loads } }

    /// The cached value for `key`, or the result of `load`, which is retained only when it
    /// returns. The lock is held while loading, so concurrent tests never load one vocabulary twice.
    func value(for key: Key, load: (Key) throws -> Value) throws -> Value {
        try state.withLock { state in
            if let cached = state.entries[key] { return cached }
            state.loads += 1
            let value = try load(key)
            state.entries[key] = value
            return value
        }
    }
}

enum LocalTokenizers {
    /// Upstream tokenizer ids used by the ported tests.
    enum Model: String, CaseIterable, Sendable {
        case llama2 = "meta-llama/Llama-2-7b-chat-hf"
        case llama3 = "meta-llama/Meta-Llama-3-8B-Instruct"
        case llama31 = "meta-llama/Llama-3.1-8B-Instruct"
        case qwen25 = "Qwen/Qwen2.5-0.5B"
        case qwen3 = "Qwen/Qwen3-0.6B"

        /// Cache directories whose `tokenizer.json` carries this vocabulary.
        fileprivate var repositories: [String] {
            switch self {
            case .llama2: ["models--meta-llama--Llama-2-7b-chat-hf", "models--huggyllama--llama-7b"]
            case .llama3: ["models--meta-llama--Meta-Llama-3-8B-Instruct"]
            case .llama31: ["models--meta-llama--Llama-3.1-8B-Instruct"]
            case .qwen25: ["models--Qwen--Qwen2.5-0.5B", "models--mlx-community--Qwen2.5-7B-Instruct-4bit"]
            case .qwen3: ["models--Qwen--Qwen3-0.6B"]
            }
        }
    }

    struct Tokenizer: Sendable {
        let model: Model
        let info: TokenizerInfo
        /// `tokenizer.eos_token_id`.
        let eosTokenID: Int32
        /// `tokenizer.convert_tokens_to_ids(piece)` for a single vocabulary piece.
        func tokenID(_ piece: String) -> Int32? { info.tokenID(for: piece) }
    }

    /// A saved tokenizer directory plus the `from_huggingface` arguments; upstream's cache key is
    /// the model id and keyword arguments.
    struct Request: Hashable, Sendable {
        /// A directory holding `tokenizer.json` and `tokenizer_config.json`.
        var directory: URL
        var vocabSize: Int? = nil
        var stopTokenIDs: [Int32]? = nil
    }

    struct Loaded: Sendable {
        let info: TokenizerInfo
        /// `tokenizer.eos_token_id`, when `tokenizer_config.json` names an `eos_token`.
        let eosTokenID: Int32?
    }

    /// Vocabularies are loaded on first use; building a 150k-token `TokenizerInfo` is not free
    /// in debug builds, so tests only pay for the models they touch.
    private static let cache = TokenizerLoadCache<Request, Loaded>()
    /// One compiler per vocabulary, shared by every test that uses that vocabulary.
    private static let compilers = Mutex<[Model: GrammarCompiler]>([:])

    static func tokenizer(_ model: Model) -> Tokenizer? {
        guard let directory = snapshotDirectory(model),
              let loaded = try? cache.value(for: Request(directory: directory), load: load),
              let eosTokenID = loaded.eosTokenID
        else { return nil }
        return Tokenizer(model: model, info: loaded.info, eosTokenID: eosTokenID)
    }

    /// Whether the vocabulary is cached locally (only the files are checked; nothing is parsed).
    static func has(_ model: Model) -> Bool { snapshotDirectory(model) != nil }
    /// The subset of `models` that is available locally, for parameterized tests.
    static func available(_ models: [Model]) -> [Model] { models.filter(has) }

    /// A shared compiler with its cache enabled, so that parameterized tests compile each distinct
    /// grammar once per vocabulary (as upstream's default `GrammarCompiler` does).
    static func compiler(_ model: Model) -> GrammarCompiler? {
        compilers.withLock { compilers in
            if let compiler = compilers[model] { return compiler }
            guard let tokenizer = tokenizer(model) else { return nil }
            let compiler = GrammarCompiler(tokenizerInfo: tokenizer.info)
            compilers[model] = compiler
            return compiler
        }
    }

    /// `TokenizerInfo.from_huggingface(tokenizer, vocab_size=..., stop_token_ids=...)`.
    static func info(_ model: Model, vocabSize: Int? = nil, stopTokenIDs: [Int32]? = nil) -> TokenizerInfo? {
        if vocabSize == nil, stopTokenIDs == nil { return tokenizer(model)?.info }
        guard let directory = snapshotDirectory(model) else { return nil }
        let request = Request(directory: directory, vocabSize: vocabSize, stopTokenIDs: stopTokenIDs)
        return try? cache.value(for: request, load: load).info
    }

    /// The first Hugging Face snapshot directory that holds both tokenizer files.
    private static func snapshotDirectory(_ model: Model) -> URL? {
        let hub = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        for repository in model.repositories {
            let snapshots = hub.appendingPathComponent(repository).appendingPathComponent("snapshots")
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { continue }
            for entry in entries.sorted() {
                let directory = snapshots.appendingPathComponent(entry)
                let present = ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
                }
                if present { return directory }
            }
        }
        return nil
    }

    /// Loads a saved tokenizer directory the way upstream's `from_huggingface` reads a
    /// `PreTrainedTokenizerFast`: the vocabulary from `tokenizer.json`, the stop token from the
    /// configuration's `eos_token` unless explicit stop ids are requested.
    static func load(_ request: Request) throws -> Loaded {
        let json = try Data(contentsOf: request.directory.appendingPathComponent("tokenizer.json"))
        let configData = try Data(contentsOf: request.directory.appendingPathComponent("tokenizer_config.json"))
        let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] ?? [:]
        let eosPiece: String? = switch config["eos_token"] {
        case let piece as String: piece
        case let token as [String: Any]: token["content"] as? String
        default: nil
        }
        let pieces = try TokenizerJSONScanner.pieces(in: json)
        let eosTokenID = eosPiece.flatMap { piece in
            let bytes = Array(piece.utf8)
            return pieces.firstIndex { $0.utf8.elementsEqual(bytes) }.map(Int32.init)
        }
        let stopTokenIDs = request.stopTokenIDs ?? eosTokenID.map { [$0] }
        let info = try TokenizerInfo(tokenizerJSON: json, vocabSize: request.vocabSize, stopTokenIDs: stopTokenIDs)
        return Loaded(info: info, eosTokenID: eosTokenID)
    }
}

/// Upstream's `_get_masked_tokens_from_bitmask`.
extension TokenBitmask {
    var rejectedCount: Int { vocabSize - count }
}
