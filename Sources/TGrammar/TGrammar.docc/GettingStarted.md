# Getting Started

Build a vocabulary, compile a grammar once, and match one sequence per generation.

## Overview

Constrained decoding has three layers, each with its own lifetime:

| Value | Lifetime | Sharing |
| --- | --- | --- |
| ``TokenizerInfo`` | one per model vocabulary | immutable, `Sendable` |
| ``GrammarCompiler`` / ``CompiledGrammar`` | one compiler per vocabulary; grammars are cached | immutable, `Sendable` |
| ``GrammarMatcher`` | one per generated sequence | value type; copies fork the state |

### Describe the vocabulary

A ``TokenizerInfo`` holds every vocabulary piece decoded to bytes, the stop tokens and the width
of the model's logits. Read it from the model's `tokenizer.json`:

```swift
let info = try TokenizerInfo(
    tokenizerJSON: try Data(contentsOf: modelDirectory.appending(component: "tokenizer.json")),
    stopTokenIDs: [151645]   // the tokens your generation loop stops on
)
```

The document is read byte-exactly: Foundation's JSON APIs merge canonically equivalent pieces and
strip a leading U+FEFF, which silently shifts masks. To read pieces from a live tokenizer
instead, adopt ``TokenizerVocabulary`` and use ``TokenizerInfo/init(tokenizer:tokenizerJSON:vocabSize:stopTokenIDs:)``.

With mlx-swift-lm, the repository's `docs/MLX_INTEGRATION.md` shows how to build all of this
from a loaded model, including the stop tokens the generation loop uses.

### Compile

Create one ``GrammarCompiler`` per vocabulary and keep it. It compiles grammars in parallel,
caches whole grammars, and shares the masks of rules that grammars have in common, so a changed
tool set recompiles only what changed.

```swift
let compiler = GrammarCompiler(tokenizerInfo: info, maxCacheBytes: 64 << 20)
let grammar = try compiler.compile(regex: #"\d{4}-\d{2}-\d{2}"#)
```

Compilation is CPU-bound and can take tens of milliseconds for large schemas on a 150k-token
vocabulary; do it off the main actor, ahead of the request when you can.

When the grammar is only known at request time (a tool set chosen per request, for example),
dynamic compilation prepares it in a small fraction of that time and computes each token mask the
first time a matcher reaches the corresponding grammar state, sharing it with every later matcher:

```swift
let compiler = GrammarCompiler(tokenizerInfo: info, dynamicCompilation: true)
```

The masks a generation needs are then computed while it decodes, on the thread that fills the
mask, instead of before the first token. Decoding speed is unchanged once a state has been seen.

The caches are bounded by ``GrammarCompiler/defaultMaxCacheBytes`` (scaled to the device's
memory) unless you pass a budget, and every TGrammar cache is dropped when the system reports
memory pressure. Call ``GrammarCompiler/purgeCaches()`` to release them yourself, for example when
the model is unloaded. Compiled grammars already handed out stay valid.

### Decode

A ``GrammarMatcher`` follows one sequence. Before each step, fill a ``TokenBitmask`` with the
allowed tokens and mask the logits; after sampling, accept the token:

```swift
var matcher = GrammarMatcher(grammar)
var mask = TokenBitmask(vocabSize: info.vocabSize)
while !matcher.isTerminated {
    if matcher.fillNextTokenBitmask(&mask) {
        mask.apply(to: &logits)            // disallowed tokens become -infinity
    }
    let token = sampler.sample(logits)
    guard matcher.acceptToken(token) else { break }
}
```

``GrammarMatcher/fillNextTokenBitmask(_:)`` returns `false` when every token is allowed, so the
mask can be skipped. Once the grammar is complete, only stop tokens are allowed; accepting one
terminates the matcher. A stop token whose text the grammar itself expects (Harmony's `<|call|>`
closing a tool call) is also allowed where consuming it completes the grammar.

Because the matcher is a value, `let fork = matcher` snapshots it for beam search or speculative
verification, and ``GrammarMatcher/rollback(_:)`` undoes accepted tokens.
``GrammarMatcher/findJumpForwardString()`` returns text the grammar forces next, cut to whole
characters, which a generation loop can append without sampling; ``GrammarMatcher/findJumpForwardTokens()`` returns it
as vocabulary tokens to accept and prefill, keeping already accepted token boundaries.

### Persist

Compiled grammars round-trip through ``CompiledGrammar/serializedJSON``, in XGrammar's
serialization format, so an application can ship or cache compiled tool sets:

```swift
let restored = try CompiledGrammar(serializedJSON: stored, tokenizerInfo: info)
```
