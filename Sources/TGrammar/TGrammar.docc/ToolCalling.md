# Tool Calling

Constrain a model's tool calls to its own wire format, with arguments that follow each tool's
schema.

## Overview

Every model family spells tool calls differently: Qwen3 wraps JSON in `<tool_call>` tags, GLM
uses `<arg_key>`/`<arg_value>` pairs, Gemma 4 has its own value syntax, Harmony routes calls
through channels. `StructuralFormat.toolCalls(_:model:...)` and the matching
`GrammarCompiler.compile(toolCalls:model:...)` build the format for a ``ToolCallDialect``, a port
of XGrammar's model registry:

```swift
let weather = ToolDefinition(name: "get_weather", parameters: .object(properties: [
    .init("city", .string(), required: true),
    .init("unit", .enumeration(["celsius", "fahrenheit"])),
]))

let grammar = try compiler.compile(toolCalls: [weather], model: .qwen3, choice: .automatic)
```

The grammar covers the whole response: the model's reasoning block, free text, and calls whose
names are declared tools and whose arguments follow their schemas, encoded the way the model
writes them (JSON, XML parameters, Gemma values).

With mlx-swift-lm, the repository's `docs/MLX_INTEGRATION.md` has a `compile(toolCalls:for:)`
to copy into the app: it picks the dialect that matches the model's `ToolCallFormat`, takes
`ChatSession`'s `[ToolSpec]`, and adapts the reasoning block and forced choices to each
generation of a chat turn.

### Tools and choices

Tools and choices follow the Chat Completions API. Build them as values, or pass request
payloads through:

```swift
let tools = try ToolDeclaration.tools(json: requestToolsJSON)
let choice = try ToolChoice(json: #"{"type": "function", "function": {"name": "get_weather"}}"#)
```

| ``ToolChoice`` | Output |
| --- | --- |
| `.automatic` | Free text, with calls to any tool |
| `.required` | At least one call |
| `.named(_:)` | Exactly one call to that function |
| `.allowed(_:required:)` | A subset of the tools, optionally required |
| `.none` | Free text; call openers are excluded |

Tools without a parameter schema, or declared with `strict: false`, get syntactically valid but
unconstrained arguments. `parallelCalls: false` ends the response after one call.

### Reasoning

``ReasoningMode`` says how the reasoning block before the answer is handled:

- `.enabled`: the model's native thinking mode. Following each model's chat template, it either
  continues an opener the prompt already ends with (Qwen3, DeepSeek, GLM, Kimi) or generates the
  whole block (MiMo, Gemma 4).
- `.continuation`: the prompt ends with the opener; continue and close it.
- `.optional`, `.required`: a complete block, opener included, that may or must appear.
- `.disabled`: no reasoning block.

The mode must match the prompt: if the template already wrote `<think>`, a grammar that expects
the model to write it would forbid the answer's first token. The mlx-swift-lm integration
detects this from the prompt itself.

The same modes put a reasoning block before any other answer. `maxTokens` caps the reasoning,
after which the block must close; ``ReasoningDelimiters`` defaults to `<think>`, `</think>` and
`"\n\n"` before the answer:

```swift
let city = JSONSchema.object(properties: [.init("city", .string(), required: true)])
let answer = try compiler.compile(structuralFormat: .reasoning(.required, maxTokens: 512,
                                                               then: .jsonSchema(city)))
```

### Token-level markers

Control markers such as `<tool_call>` are matched as text by default, so the grammar also
accepts them spelled from ordinary sub-tokens (`<`, `tool_call`, `>`). A parser that recognises
markers by token id finds no call in such output. `tokenMarkers: true` requires the dedicated
tokens instead, for the formats that declare ``ToolCallDialect/markerTokens`` (Qwen 3, Qwen 3.5,
Qwen 3 Coder and GLM 4.7). Compile it against the model's vocabulary, in which each marker
must be a single token. Free text then excludes markers only as tokens, so use it only with such
parsers; markers inside schema-driven arguments (GLM's `<arg_key>`) stay text. For other
formats, ``StructuralFormat/bindingMarkerTokens(_:)`` applies the same rewrite to any format.

### Other formats

For a model outside the registry, ``ToolCallSyntax`` describes the delimiters explicitly:

```swift
// <call name="get_weather">{"city": "Paris"}</call>
let syntax = ToolCallSyntax(namePrefix: "<call name=\"", nameSuffix: "\">", end: "</call>",
                            trigger: "<call ")
let grammar = try compiler.compile(toolCalls: [weather], syntax: syntax)
```

### Executing calls

A constrained call is syntactically valid and its arguments satisfy the schema's structure, but
the grammar does not execute anything. Parse the completed call with the model's parser, decode
the arguments into your typed input, and dispatch through your own routing. With
`captureArguments: true` each call's arguments are also recorded as a ``GrammarCapture`` named
after the tool; a capture can complete before the closing delimiter, so it is not by itself an
execution event.
