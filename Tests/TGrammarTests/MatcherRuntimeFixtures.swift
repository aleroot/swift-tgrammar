// Literal corpora of the upstream matcher tests, stored in Fixtures/MatcherRuntime.json.

import Foundation
import Testing

struct MatcherRuntimeFixtures: Decodable, Sendable {
    struct JSONDocuments: Decodable, Sendable {
        let accepted: [String]
        let refused: [String]
        let pressure: [String]
    }

    /// Rejected-token counts after each byte of `input` (and once more at the end) when the
    /// grammar is matched against `tokenizer`'s vocabulary.
    struct RejectedSizes: Decodable, Sendable, CustomTestStringConvertible {
        let id: String
        let tokenizer: String
        let grammar: String
        let schema: String?
        let input: String
        let sizes: [Int]
        var testDescription: String { id }
        var model: LocalTokenizers.Model? { .init(rawValue: tokenizer) }
    }

    struct TagDispatchScenario: Decodable, Sendable, CustomTestStringConvertible {
        let id: String
        let ebnf: String
        let input: String
        var testDescription: String { id }
    }

    let revision: String
    let json: JSONDocuments
    let rejectedSizes: [RejectedSizes]
    let tagDispatchScenarios: [TagDispatchScenario]
    /// Upstream tokenizer id → text → `tokenizer.encode(text, add_special_tokens=False)`.
    let recordedTokens: [String: [String: [Int32]]]

    static let upstream: MatcherRuntimeFixtures = {
        let url = Bundle.module.url(forResource: "MatcherRuntime", withExtension: "json")!
        return try! JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }()
}
