# Structured Output

Choose the front end that describes your output: JSON Schema, EBNF, Lark, regular expressions,
or structural formats that mix free text with constrained regions.

## Overview

Every front end produces a ``Grammar``; ``GrammarCompiler`` turns any of them into a
``CompiledGrammar`` for a vocabulary. The compiler also has a direct method for each.

### JSON Schema

Build schemas with typed factories, or pass the JSON source your application already has:

```swift
let event = JSONSchema.object(properties: [
    .init("title", .string(minLength: 1, maxLength: 80), required: true),
    .init("date", .string(format: "date"), required: true),
    .init("attendees", .array(items: .string(), maxItems: 10)),
    .init("priority", .enumeration(["low", "normal", "high"])),
])
let grammar = try compiler.compile(jsonSchema: event)

let fromSource = try compiler.compile(jsonSchema: #"{"type": "array", "items": {"type": "integer"}}"#)
```

``JSONSchemaOptions`` controls layout. By default output has one canonical layout,
`{"key": value, "list": [1, 2]}`, so a model cannot spend tokens on whitespace and decoding stays
fast. `indent`, `itemSeparator` and `keySeparator` pick another fixed layout. `anyWhitespace`
accepts any JSON whitespace (XGrammar's default); pair it with `maxWhitespaceCount` when
generating, or a model whose preferred token is masked out can emit whitespace until its token
limit. `strict` forbids undeclared properties, `anyOrder` accepts properties in any order, and
`excludes` keeps strings from containing delimiters. Tool-call grammars accept any whitespace
inside arguments, so every model keeps the spacing it was trained on.

The converter supports local `$ref` (including recursion), `anyOf`/`oneOf`, `allOf` of compatible
branches, `const`/`enum`, `prefixItems`, pattern and additional properties, integer and decimal
ranges, string length bounds, patterns and the common `format`s. It is a generator: keywords
that do not shape syntax are approximated, so validate business rules after decoding.

### Grammars and expressions

```swift
let arithmetic = try compiler.compile(ebnf: #"""
root ::= expr
expr ::= term (("+" | "-") term)*
term ::= [0-9]+ | "(" expr ")"
"""#)

let date = try compiler.compile(regex: #"\d{4}-\d{2}-\d{2}"#)

let command = try compiler.compile(lark: #"""
start: verb " " NOUN
verb: "open" | "close"
NOUN: /[a-z]+/
"""#)
```

EBNF follows XGrammar's dialect, including character classes, repetition ranges `{m,n}`,
lookahead assertions and the built-in JSON grammar (``Grammar/builtinJSON``). Grammars compose
with ``Grammar/union(_:)`` and ``Grammar/concatenating(_:)``.

### Structural formats

A ``StructuralFormat`` describes output that is mostly free text with constrained regions,
such as a chat answer that may embed tagged JSON:

```swift
let answer = StructuralFormat.triggeredTags(
    triggers: ["<data>"],
    tags: [StructuralTag(begin: "<data>", content: .jsonSchema(event), end: "</data>")]
)
let grammar = try compiler.compile(structuralFormat: answer)
```

Formats nest: `.sequence`, `.choice`, `.optional`, `.repeated`, `.anyText(excluding:maxTokens:)`
and `.tagsWithSeparator` cover reasoning blocks, lists of calls and bounded free text. Token-level
variants (`.token`, `.tokenTriggeredTags`, `.anyTokens`) match special tokens by id, so a
multi-token spelling of `<think>` cannot stand in for the real token. `.captured(_:_:)` records
the text of a region, read back with ``GrammarMatcher/captures(deduplicate:)``, and
`.temperature(_:_:)` attaches a sampling temperature to a region, read with
``GrammarMatcher/temperature``.

XGrammar's structural-tag JSON is accepted unchanged with
``GrammarCompiler/compile(structuralTagJSON:)``.
