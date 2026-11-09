# Integration

## Vocabulary contract

Build one `TokenizerInfo` for each model/tokenizer combination. Read original vocabulary pieces,
not `decode([id])` output: individual pieces may contain partial UTF-8 or encoding markers, and
decoders can normalize or suppress them. Pass the model's final logits dimension and the complete
set of generation stop IDs. The grammar and model must agree about those IDs, including padded
IDs beyond the tokenizer's stored pieces.

For [swift-tokenizers](https://github.com/aleroot/swift-tokenizers), the minimal bridge is:

```swift
import Tokenizers
import TGrammar

struct GrammarVocabulary: TokenizerVocabulary {
    let tokenizer: any Tokenizers.Tokenizer

    func convertIdToToken(_ id: Int) -> String? {
        tokenizer.convertIdToToken(id)
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    var eosTokenId: Int? { tokenizer.eosTokenId }
}

let info = try TokenizerInfo(
    tokenizer: GrammarVocabulary(tokenizer: tokenizer),
    tokenizerJSON: tokenizerData,
    vocabSize: modelVocabularySize,
    stopTokenIDs: generationStopTokenIDs
)
```

Or read `tokenizer.json` directly with `TokenizerInfo(tokenizerJSON:vocabSize:stopTokenIDs:)`.
The wrapper forwards an existential safely; `extension Tokenizer: TokenizerVocabulary` is invalid
Swift because `Tokenizer` is itself a protocol. A concrete class can adopt the protocol instead.

## mlx-swift-lm

The package does not depend on MLX or mlx-swift-lm. [MLX_INTEGRATION.md](MLX_INTEGRATION.md) has
the app-side code for `ChatSession`: vocabulary and stop tokens from a loaded model, the
`LogitProcessor`, `GenerationComponents.constrained(to:)` and tool-call grammars per
`ToolCallFormat`.

## Tool-call framing

Keep the prompt template and `ToolCallDialect` together as model configuration.
The format is an explicit wire contract, not model-name detection: pick the family whose chat
template the loaded model uses. The registry is a port of XGrammar's built-in model structural
tags, including each model's argument encoding (`JSONSchemaOptions.Style`), reasoning delimiters,
special-token exclusions and the Chat Completions tool-choice semantics. Request payloads can be
passed through directly with `ToolDeclaration.tools(json:)` and `ToolChoice(json:)`. For a model whose
syntax is not in the registry, `ToolCallSyntax` supplies custom delimiters through
`toolCalls(_:syntax:)`.

Construct a compiler once for the loaded vocabulary, and reuse it for changed tool sets/schemas.
Use a bounded cache for long-running applications. The factory then creates a matcher per
generation; cancellation drops that sequence's state.

Pass tool metadata to the model's prompt as usual. Feed only sampled output tokens to the matcher.
Display streaming text with the application's tokenizer decoder; mask generation uses vocabulary
piece bytes independently of that display decoder.

With `captureArguments: true`, captures are named by tool. A parameter grammar can complete before
the closing tool-call delimiter arrives, so a capture alone is not an execution event. Frame the
complete call, parse its parameters into the application's typed input, and dispatch through its
existing tool routing. XML captures may include formatting whitespace. Full output completion
also need not mean EOS has been accepted; the generator's stop handling must remain aligned.
