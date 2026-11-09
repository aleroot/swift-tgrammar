import Dispatch

/// Masks and sampling temperatures for independent decoding sequences. Terminated rows contain
/// zero masks; callers should skip those sequences when sampling.
public struct GrammarBatchResult: Sendable {
    public struct Row: Sendable {
        public let needsApply: Bool
        public let isTerminated: Bool
        public let temperature: Float?
    }
    public let masks: TokenMaskBatch
    public let rows: [Row]
}

/// Batched constrained decoding without tensor-library dependencies.
public enum GrammarBatch {
    /// Fills one packed mask per sequence and preserves each matcher's pending budget decisions
    /// for its subsequent `acceptToken`. Every matcher must use the same vocabulary size.
    public static func fillNextTokenMasks(for matchers: inout [GrammarMatcher], maxThreads: Int? = nil) -> GrammarBatchResult {
        let vocabSize = matchers.first?.compiledGrammar.tokenizerInfo.vocabSize ?? 0
        precondition(matchers.allSatisfy { $0.compiledGrammar.tokenizerInfo.vocabSize == vocabSize }, "Batch vocabulary sizes must match")
        let count = matchers.count, width = TokenBitmask.wordCount(vocabSize: vocabSize)
        var masks = TokenMaskBatch(rows: count, vocabSize: vocabSize)
        var rows = Array(repeating: GrammarBatchResult.Row(needsApply: false, isTerminated: false, temperature: nil), count: count)
        guard count > 0 else { return .init(masks: masks, rows: rows) }
        let workers = min(count, max(1, maxThreads ?? ProcessorCount.active))
        matchers.withUnsafeMutableBufferPointer { matcherBuffer in
            masks.words.withUnsafeMutableBufferPointer { maskBuffer in
                rows.withUnsafeMutableBufferPointer { rowBuffer in
                    let matcherStorage = BorrowedBuffer(matcherBuffer), maskStorage = BorrowedBuffer(maskBuffer), rowStorage = BorrowedBuffer(rowBuffer)
                    let fill: @Sendable (Int) -> Void = { worker in
                        var mask = TokenBitmask(vocabSize: vocabSize)
                        for index in stride(from: worker, to: count, by: workers) {
                            if matcherStorage.pointer[index].isTerminated {
                                rowStorage.pointer[index] = .init(needsApply: false, isTerminated: true, temperature: matcherStorage.pointer[index].temperature)
                                continue
                            }
                            let needed = matcherStorage.pointer[index].fillNextTokenBitmask(&mask)
                            for word in 0 ..< width { maskStorage.pointer[index * width + word] = mask.words[word] }
                            rowStorage.pointer[index] = .init(needsApply: needed, isTerminated: false, temperature: matcherStorage.pointer[index].temperature)
                        }
                    }
                    if workers == 1 { fill(0) } else { DispatchQueue.concurrentPerform(iterations: workers, execute: fill) }
                }
            }
        }
        return .init(masks: masks, rows: rows)
    }

    /// Accepts `tokens[i]` into `matchers[i]`; returns whether each matcher accepted its token.
    public static func accept(tokens: some Collection<Int32>, for matchers: inout [GrammarMatcher]) -> [Bool] {
        precondition(tokens.count == matchers.count, "The batch has \(matchers.count) matchers but \(tokens.count) tokens")
        return zip(matchers.indices, tokens).map { index, token in matchers[index].acceptToken(token) }
    }

    /// Accepts `strings[i]` into `matchers[i]`; returns whether each matcher accepted its string.
    public static func accept(strings: some Collection<String>, for matchers: inout [GrammarMatcher]) -> [Bool] {
        precondition(strings.count == matchers.count, "The batch has \(matchers.count) matchers but \(strings.count) strings")
        return zip(matchers.indices, strings).map { index, string in matchers[index].acceptString(string) }
    }

    /// Rolls `matchers[i]` back by `counts[i]` tokens; a count of zero leaves the matcher as is.
    public static func rollback(_ counts: some Collection<Int>, for matchers: inout [GrammarMatcher]) {
        precondition(counts.count == matchers.count, "The batch has \(matchers.count) matchers but \(counts.count) rollback counts")
        for (index, count) in zip(matchers.indices, counts) where count > 0 { matchers[index].rollback(count) }
    }

    /// These pointers are borrowed only by synchronous concurrentPerform calls within their
    /// buffer scopes. Each worker reads/writes disjoint rows; no Swift Array mutation occurs
    /// while the buffers are borrowed, and no pointer escapes this method.
    private final class BorrowedBuffer<Element: Sendable>: @unchecked Sendable {
        let pointer: UnsafeMutableBufferPointer<Element>
        init(_ pointer: UnsafeMutableBufferPointer<Element>) { self.pointer = pointer }
    }
}
