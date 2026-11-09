# Architecture

`TGrammar` separates structure definition, tokenizer-dependent compilation, and mutable sequence
state. Public definitions are `Sendable`; compiler caches synchronize with Swift's `Mutex`.
The core has no third-party dependencies. Tensor integration lives in a separate package.

## Pipeline

```text
EBNF / Lark / regex / JSON Schema / StructuralFormat / tool definitions
    → Grammar (normalized arena)
    → GrammarOptimizer (rule graph, lookahead, nullable rules, automata)
    → GrammarCompiler + TokenizerInfo (adaptive token masks)
    → CompiledGrammar
    → GrammarMatcher per sequence
    → TokenBitmask → sampler → acceptToken
```

`Grammar` and `CompiledGrammar` are immutable final classes, shared by matchers. `GrammarMatcher`
is a value type with copy-on-write histories: assigning it creates an independent branch.
`GrammarCompiler` is a synchronized service for one tokenizer and model vocabulary width.

## Storage and automata

Expressions occupy an `Int32` arena with CSR offsets. A record contains kind, length, and payload;
`GrammarExpr` reads an `ArraySlice<Int32>` view without allocating a node object. Kind numbers and
payloads follow XGrammar v18. Rule attributes carry capture names, lazy completion, budgets,
temperature, lookahead, and suffix/stop metadata.

`FSM` is the mutable construction form. `CompactFSM` uses sorted CSR edges. Byte ranges have
nonnegative minima; negative edge kinds encode epsilon, rule references, EOS, counted repetition,
token sets, and excluded-token sets. Each rule is a start/end view into one complete automaton.
Large repetition bounds use counted edges instead of unrolling. State limits bound algebraic
operations such as determinization and intersection.

`ParserTables` owns immutable pointer-backed copies of the hot arena and automaton tables.
Byte scanning reads them without retaining shared Swift array buffers at every access. This
avoids refcount contention during parallel mask compilation. The owner outlives every borrowed
table access; raw pointers are internal.

## Front ends

- EBNF and regex parsers preserve the upstream grammar dialect and normalization snapshots.
- JSON Schema is parsed into an ordered JSON value tree. Integer lexemes remain exact strings;
  references reuse predeclared rules, including recursive local references. Object alternatives
  encode generation order, optional fields, and counts; arbitrary order uses subset states.
- Generic JSON strings are a single regex automaton, including paired Unicode escapes. Keeping
  their loop local makes vocabulary tokens crossing multiple characters cheap to classify.
  Schema exclusions intersect a valid string automaton with an Aho–Corasick exclusion automaton;
  productive paths are emitted at Unicode scalar boundaries and preserve EBNF round trips.
- Lark handles rules, terminals, common imports, ignored lexemes, embedded schemas/subgrammars,
  named references, token terminals, and attributes. Lazy free-text heads in the supported
  `start: tool* tail` shape become dispatch automata: a complete opener commits its payload.
- `StructuralFormat` is a typed Swift composition tree. Conversion remaps imported rule IDs and
  passes the nearest enclosing end delimiter to free-text/token regions. Tool presets compose
  those same primitives; the matcher has no model-specific behavior.

These are generation front ends, with upstream approximations and explicit implementation limits.
They are not complete JSON Schema validators.

## Tokenizer and compiler

`TokenizerInfo` packs encoded, decoded, and lexically sorted pieces in `ByteStringTable` buffers
with offsets. It also stores a token-ID-to-sorted-index map, Unicode character counts, and trie
subtree ends. Raw, byte-level, byte-fallback, and Metaspace inputs are supported. Model padding and
explicit stop IDs are represented at the model's logits width.

For each scanable automaton state, `TokenMaskComputer` replays sorted vocabulary pieces through a
parser. Adjacent pieces share prefix history; a rejected prefix skips its whole trie subtree.
Tokens become accepted, rejected, or uncertain. Adaptive storage chooses lists or bitsets;
lookahead resolves tokens crossing a rule boundary where possible. The walk writes into
pointer-backed buffers that each worker reuses; the mask is built from them in place, and buffers
grown past a few thousand entries are released after the mask, so compile-time scratch stays at
about one vocabulary-sized list per worker that is computing such a mask.

Compilation uses a bounded number of workers. Per-key gates deduplicate concurrent compilation,
and an LRU enforces an optional approximate memory budget. JSON Schema and Lark cache keys include
source options/references so a cache hit can bypass conversion. Clearing the cache advances a
generation; previously in-flight work cannot repopulate it. Oversized grammars are returned
without being retained.

A second, rule-level cache shares masks across grammars. `GrammarFSMHasher` gives every rule's
automaton a canonical hash (BFS state renumbering; referenced rules hashed first, simple reference
cycles rotated into position-independent hashes, lazy rules and repetition bounds folded in) and a
*partial* hash when one reference at the start state is unhashable. `RuleLevelCache` is a 16-shard
LRU keyed by hash, canonical state, and state/edge counts. Masks of rules without a lookahead are
stored as is; for rules with one, a copy whose lookahead-decided tokens are uncertain is stored
under the automaton key and the exact mask under a combined key, and a hit on the automaton key is
re-resolved against the current lookahead (`adaptWithLookahead`). Grammars with character budgets
and the start state of partially hashed rules bypass the cache. The budget splits two thirds to
whole grammars and one third to rule masks, as upstream.

With the cache disabled, rules of one grammar still share masks through a per-compilation
`RuleLevelCache`, but only when worth it: two rules of equal automaton size must each have a state
whose first bytes start at least `minimumSharedScan` (256) vocabulary tokens, and only the keys a
second-round state looks up are stored. Small grammars (a regex, say) skip hashing altogether.

`CompiledGrammar.maskTable` finds a state's mask through a dense element-id table (compiled masks
belong to automaton states with unique ids; owner rule and sequence are checked, with a dictionary
fallback), so decoding does not hash a key per state per token.

## Matching and runtime state

The Earley parser stores scanable states, completable parents, and capture events in CSR row
histories. Matching does not recursively descend the rule graph. Each accepted token records
the parser rows and byte extent needed to roll back it as one operation. Rejected inputs restore
state transactionally. Byte and atomic-token paths start from the same state and merge.

At mask time, accepted sets are unioned, rejected sets intersected, and uncertain tokens replayed
from the live states. Budgets can commit a region's exit before the next accept. Their pending
decision is part of fork/rollback state. Character accounting follows Unicode scalars, including
UTF-8 split across vocabulary pieces; token budgets count emitted tokens.

Lazy rules commit their earliest completion per occurrence. Captures materialize accepted bytes
from completion events; deduplication retains the longest completion for an ordinary occurrence.
Suffix markers disappear from that rule's capture; stop markers also disappear from enclosing
captures along their completion ancestry. Variable markers use body/marker automata to find the
split. Captures roll back with parser rows.

Temperature queries select the innermost annotated region, with the upstream policy for ambiguous
live branches. A sampler must consume that value itself; the core never changes sampling policy.

## Batch and MLX integration

`TokenBitmask` packs one allow bit per token in `UInt32` words, LSB first. `TokenMaskBatch` is a flat
row-major buffer with the same layout. `GrammarBatch` lends disjoint matcher/mask elements to
synchronous workers; borrowed pointer wrappers never escape that operation. Terminated rows are
zeroed, and each row reports whether the mask needs application and its active temperature.

`DraftTokenTree` validates child/sibling links, reachability, and single-parent ownership before
iterative traversal. Traversal works on a matcher copy, rolls siblings back to their parent,
preserves pending budget decisions, and optionally observes a duration limit. Invalid or unvisited
nodes have zero masks, and the original matcher remains unchanged.

The package has no MLX code. `docs/MLX_INTEGRATION.md` gives applications the processor that
uploads packed mask words and unpacks them with MLX tensor operations on the selected device,
with index/bit-shift plans cached per processor. That `GrammarLogitProcessor` owns one matcher,
resets to its initial state on prompt, and implements independent copies. MLX arrays are not
declared `Sendable`; create processors on the generation's isolation domain.

## Persistence and validation

Grammar, tokenizer, and compiled snapshots use XGrammar serialization version 18. Restoring validates arena
offsets, normalized expression shapes, graph references, attribute bounds, FSM CSR/edge payloads,
and token-mask indices before constructing parser tables. Binary token bytes use Latin-1 JSON
strings as upstream does. A tokenizer extension preserves original encoded pieces; it can be
omitted for exact upstream snapshots.

Compiled snapshots require the same tokenizer vocabulary. The v18 metadata check catches width,
encoding, prefix-space, and stop-ID mismatches but does not fingerprint vocabulary content.
Approximate memory sizes exclude allocator spare capacity and shared tokenizer storage.

## Test seam

Swift Testing suites port XGrammar's exact arena/automaton snapshots, language cases, token masks,
and stateful matcher operations. Each fixture case names its upstream source test and parameter
row. Runtime tests cover interactions that text acceptance alone cannot verify. Tests that need a
real model vocabulary read it from the local Hugging Face cache and are skipped when it is absent;
the suite never downloads anything.
