// Memory footprint regressions: TGrammar targets phones and laptops, where every compiled grammar
// and vocabulary stays resident next to the model.

import Foundation
import Testing

@testable import TGrammar

@Suite("Memory footprint")
struct MemoryFootprintTests {
    /// Printable ASCII, every lowercase pair, and every pair behind a quote (`"ab`): a quote
    /// token closes a JSON string, so string states get long uncertain or rejected lists.
    static let vocabulary: [String] = {
        let letters = (UInt8(ascii: "a") ... UInt8(ascii: "z")).map { String(UnicodeScalar($0)) }
        var pieces = (0x20 ... 0x7E).map { String(UnicodeScalar(UInt8($0))) }
        for first in letters { for second in letters { pieces.append(first + second); pieces.append("\"" + first + second) } }
        return pieces
    }()

    static func compiledSchema() throws -> CompiledGrammar {
        let info = try TokenizerInfo(encodedVocab: vocabulary)
        let schema = JSONSchema.object(properties: [
            .init("city", .string(), required: true), .init("notes", .string(), required: true),
            .init("restaurant", .string(), required: true),
        ])
        return try GrammarCompiler(tokenizerInfo: info, cacheEnabled: false).compile(jsonSchema: schema)
    }

    /// Masks are built in the computer's scratch buffers, which grow to the vocabulary size.
    /// Before compaction a mask holding a few indices kept that whole buffer alive.
    @Test func masksKeepNoScratchCapacity() throws {
        let compiled = try Self.compiledSchema()
        for mask in compiled.masks.values {
            for indices in [mask.acceptedIndices, mask.rejectedIndices, mask.uncertainIndices.bounds] {
                #expect(indices.storageBytes <= max(64, indices.count * 4 / 8) + indices.count * 4)
            }
        }
    }

    /// Per-occurrence string rules reach equal partitions; equal lists share one buffer.
    @Test func equalMaskStorageIsShared() throws {
        let compiled = try Self.compiledSchema()
        var buffers: [[Int32]: Set<UnsafeRawPointer>] = [:]
        for mask in compiled.masks.values {
            for indices in [mask.acceptedIndices, mask.rejectedIndices, mask.uncertainIndices.bounds] where indices.count >= MaskStorageInterner.minimumInternedIndices {
                indices.withUnsafeBufferPointer { _ = buffers[indices, default: []].insert(UnsafeRawPointer($0.baseAddress!)) }
            }
        }
        #expect(!buffers.isEmpty)
        for (indices, pointers) in buffers { #expect(pointers.count == 1, "\(indices.count) indices stored \(pointers.count) times") }
    }

    /// Uncertain sets are stored as runs of consecutive sorted-vocabulary indices.
    @Test(arguments: [[], [7], [0, 1, 2, 3], [1, 3, 5], [0, 1, 2, 10, 11, 20, 30, 31, 32, 33]] as [[Int32]])
    func indexRunsRoundTrip(_ indices: [Int32]) {
        let runs = IndexRuns(indices)
        #expect(Array(runs) == indices)
        #expect(runs.array == indices)
        #expect(runs.count == indices.count && runs.isEmpty == indices.isEmpty)
        let expectedRuns = indices.indices.filter { $0 == 0 || indices[$0] != indices[$0 - 1] + 1 }.count
        #expect(runs.runCount == expectedRuns)
        #expect(runs == IndexRuns(indices))
    }

    /// A string state's uncertain tokens are whole trie subtrees (here every `"xy`, whose fate
    /// depends on what may follow a JSON value): few runs, little storage.
    @Test func uncertainSetsAreStoredAsRuns() throws {
        let info = try TokenizerInfo(encodedVocab: Self.vocabulary)
        let compiled = try GrammarCompiler(tokenizerInfo: info, cacheEnabled: false).compile(.builtinJSON)
        var indices = 0, bytes = 0
        for mask in compiled.masks.values {
            indices += mask.uncertainIndices.count
            bytes += mask.uncertainIndices.storageBytes
        }
        #expect(indices > 0)
        #expect(bytes < indices * MemoryLayout<Int32>.stride)
    }

    @Test func memorySizeCountsSharedBuffersOnce() throws {
        let compiled = try Self.compiledSchema()
        var naive = 0
        for mask in compiled.masks.values { naive += mask.memorySize }
        #expect(compiled.maskMemorySize < naive)
    }

    /// Only pieces that differ from the conventional spelling of their bytes are stored; the
    /// rest are re-spelled on demand and must round-trip exactly.
    @Test(arguments: [VocabType.raw, .byteFallback, .byteLevel])
    func encodedVocabularyRoundTrips(_ vocabType: VocabType) throws {
        let pieces: [String] = switch vocabType {
        case .raw: ["a", " b", "<|im_end|>", "é", ""]
        case .byteFallback: ["<0x0A>", "<0x41>", "A", "▁the", "▁", "<s>", "é", "x y"]
        case .byteLevel: ["Ġthe", "Ċ", "<|im_start|>", "<|addedé|>", "abc", "Ã©"]
        }
        let info = try TokenizerInfo(encodedVocab: pieces, vocabType: vocabType)
        let encoded = info.encodedVocab
        #expect(encoded.count == pieces.count)
        for (id, piece) in pieces.enumerated() {
            #expect(Array(encoded[id]) == Array(piece.utf8))
            #expect(info.tokenIDs(forPiece: Array(piece.utf8)).contains(Int32(id)))
        }
    }

    @Test func purgeCachesEmptiesCompilerCaches() throws {
        let info = try TokenizerInfo(encodedVocab: Self.vocabulary)
        let compiler = GrammarCompiler(tokenizerInfo: info)
        let compiled = try compiler.compile(jsonSchema: JSONSchema.object(properties: [.init("value", .string(), required: true)]))
        #expect(compiler.cacheSizeBytes > 0)
        GrammarCompiler.purgeCaches()
        #expect(compiler.cacheSizeBytes == 0)
        var matcher = GrammarMatcher(compiled)
        let accepted = matcher.acceptString(#"{"value": "ok"}"#)
        #expect(accepted)
        #expect(matcher.isCompleted)
    }
}
