# ``TGrammar``

Constrain language-model output to grammars, JSON Schemas and tool-call formats, in pure Swift.

## Overview

TGrammar computes, at every decoding step, the set of tokens a language model may emit so that
its output stays inside a language: a JSON Schema, an EBNF or Lark grammar, a regular
expression, or a model family's tool-call format. Applying that set as a logit mask makes the
output valid by construction.

The engine is a Swift port of [XGrammar](https://github.com/mlc-ai/xgrammar): grammars are
compiled once per vocabulary into automata and adaptive token masks, and an incremental Earley
matcher tracks each sequence. It has no dependencies, needs no Python or C++ runtime, and is
`Sendable` throughout: compiled grammars are immutable and shared, matchers are value types.

```swift
import TGrammar

let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(tokenizerJSON: tokenizerData))
let grammar = try compiler.compile(jsonSchema: .object(properties: [
    .init("city", .string(), required: true),
    .init("days", .integer(minimum: 1, maximum: 14)),
]))

var matcher = GrammarMatcher(grammar)
var mask = TokenBitmask(vocabSize: compiler.tokenizerInfo.vocabSize)
while !matcher.isTerminated {
    matcher.fillNextTokenBitmask(&mask)
    let token = sample(logits, allowing: mask)   // your sampler
    _ = matcher.acceptToken(token)
}
```

TGrammar has no dependencies and does not touch logits tensors. For
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm), the repository's
`docs/MLX_INTEGRATION.md` has the code to add to an app: a `LogitProcessor` for `ChatSession`'s
`GenerationComponents`, and tool-call grammars that `ChatSession`'s own parsers read.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:StructuredOutput>
- <doc:ToolCalling>

### Vocabularies

- ``TokenizerInfo``
- ``DecodedVocabulary``
- ``TokenizerVocabulary``
- ``VocabType``
- ``TokenizerInfoError``

### Grammars

- ``Grammar``
- ``JSONSchema``
- ``JSONSchemaOptions``
- ``StructuralFormat``
- ``StructuralTag``
- ``TagBoundary``
- ``GrammarToken``
- ``NamedGrammar``
- ``GrammarError``

### Tool Calls

- ``ToolDeclaration``
- ``ToolDefinition``
- ``BuiltinToolDefinition``
- ``ToolReference``
- ``ToolChoice``
- ``ReasoningMode``
- ``ReasoningDelimiters``
- ``ToolCallDialect``
- ``ToolCallSyntax``

### Compilation

- ``GrammarCompiler``
- ``CompiledGrammar``

### Decoding

- ``GrammarMatcher``
- ``TokenBitmask``
- ``GrammarCapture``

### Batches and Speculative Decoding

- ``GrammarBatch``
- ``GrammarBatchResult``
- ``TokenMaskBatch``
- ``DraftTokenTree``
- ``DraftTraversalResult``

### Persistence

- ``SerializationError``
- ``serializationVersion``
