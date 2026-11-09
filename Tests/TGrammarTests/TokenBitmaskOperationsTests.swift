// Port of xgrammar's tests/python/test_token_bitmask_operations.py: mask allocation/reset,
// masked-token extraction, single-token detection, and the CPU `apply_token_bitmask_inplace`
// kernel (row strides, selected rows, float32/float16/bfloat16, width detection). The CUDA,
// Triton, torch.compile and MLX kernel rows are not applicable (see docs/MLX_INTEGRATION.md).

import Testing

@testable import TGrammar

@Suite("Token bitmask operations")
struct TokenBitmaskOperationsTests {
    /// Deterministic generator so the random masks are reproducible across runs.
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// `bool_mask_to_bitmask`: packs a per-row allow table, padding the last word with ones.
    private static func batch(_ boolMask: [[Bool]]) -> TokenMaskBatch {
        let vocabSize = boolMask.first?.count ?? 0
        var batch = TokenMaskBatch(rows: boolMask.count, vocabSize: vocabSize)
        batch.setAll()
        for (row, allowed) in boolMask.enumerated() {
            for (token, isAllowed) in allowed.enumerated() where !isAllowed {
                batch.words[row * batch.wordsPerRow + token >> 5] &= ~(1 << UInt32(token & 31))
            }
        }
        return batch
    }

    /// `torch.where(bool_mask, logits, -inf)` on a row-major buffer.
    private static func expected(_ logits: [Float], width: Int, rowStride: Int, boolMask: [[Bool]], rows: [Int]? = nil) -> [Float] {
        var result = logits
        for row in rows ?? Array(boolMask.indices) {
            for token in 0 ..< width where !boolMask[row][token] { result[row * rowStride + token] = -.infinity }
        }
        return result
    }

    // MARK: Allocation and reset

    @Test func allocateResetTokenBitmask() {
        let batchSize = 10, vocabSize = 128_005
        var batch = TokenMaskBatch(rows: batchSize, vocabSize: vocabSize)
        #expect(batch.rowCount == batchSize)
        #expect(batch.wordsPerRow == (vocabSize + 31) / 32)
        #expect(batch.words.count == batchSize * ((vocabSize + 31) / 32))
        // A fresh Swift batch masks everything (rows are filled by the matcher); `setAll` is the
        // counterpart of `allocate_token_bitmask` / `reset_token_bitmask`.
        #expect(batch.words.allSatisfy { $0 == 0 })
        batch.setAll()
        #expect(batch.words.allSatisfy { $0 == 0xFFFF_FFFF })
        batch.clearAll()
        #expect(batch.words.allSatisfy { $0 == 0 })
        batch.setAll()
        #expect(batch.words.allSatisfy { $0 == 0xFFFF_FFFF })
    }

    // MARK: Masked tokens and single-token masks

    @Test(arguments: [1024, 32000, 32001, 32011], [0, 1])
    func maskedTokensFromBitmask(vocabSize: Int, index: Int) {
        var generator = SplitMix64(seed: UInt64(vocabSize * 2 + index))
        let boolMask = (0 ..< 2).map { _ in (0 ..< vocabSize).map { _ in Bool.random(using: &generator) } }
        let batch = Self.batch(boolMask)
        let expected = (0 ..< vocabSize).filter { !boolMask[index][$0] }.map(Int32.init)
        #expect(batch[index].maskedTokenIDs == expected)
        #expect(batch[index].count == vocabSize - expected.count)
    }

    @Test func isSingleTokenBitmask() {
        let batchIndex = 1, vocabSize = 1024, tokenID = 100
        var boolMask = [[Bool]](repeating: [Bool](repeating: false, count: vocabSize), count: 2)
        #expect(Self.batch(boolMask)[batchIndex].singleAllowedToken == nil)
        boolMask[batchIndex][tokenID] = true
        #expect(Self.batch(boolMask)[batchIndex].singleAllowedToken == Int32(tokenID))
        boolMask[batchIndex][tokenID + 1] = true
        #expect(Self.batch(boolMask)[batchIndex].singleAllowedToken == nil)
    }

    // MARK: apply_token_bitmask_inplace

    private static let smallBoolMask = [false, true, false, true, false, true, false, true, false, true]
    private static let smallLogits: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

    @Test func applyTokenBitmaskInplace() {
        let mask = TokenBitmask(vocabSize: 10, words: [0b10_1010_1010])
        var logits = Self.smallLogits
        mask.apply(to: &logits)
        #expect(logits == Self.expected(Self.smallLogits, width: 10, rowStride: 10, boolMask: [Self.smallBoolMask]))
    }

    /// `test_apply_token_bitmask_inplace_kernel`: the same mask over `Float16` logits.
    @Test func applyTokenBitmaskInplaceFloat16() {
        let mask = TokenBitmask(vocabSize: 10, words: [0b10_1010_1010])
        var logits = Self.smallLogits.map(Float16.init)
        mask.apply(to: &logits)
        #expect(logits.map(Float.init) == Self.expected(Self.smallLogits, width: 10, rowStride: 10, boolMask: [Self.smallBoolMask]))
    }

    /// Logits rows with a stride wider than the vocabulary (`logits.stride() == (col + 1, 1)`):
    /// column `col` of each row must stay untouched.
    @Test func applyTokenBitmaskInplaceShapeStrideMismatch() {
        let col = 100, compactedCol = (col + 31) / 32
        let boolMask = [(0 ..< col).map { $0 % 2 == 0 }, (0 ..< col).map { $0 % 2 == 1 }]
        var batch = TokenMaskBatch(rows: 2, vocabSize: col)
        batch.words = [UInt32](repeating: 0x5555_5555, count: compactedCol) + [UInt32](repeating: 0xAAAA_AAAA, count: compactedCol)
        let master = (0 ..< col + 1).map { Float($0) + 0.1 } + (0 ..< col + 1).map { Float($0) + 0.2 }
        var logits = master
        logits.withUnsafeMutableBufferPointer { batch.apply(to: $0, rowStride: col + 1) }
        #expect(logits == Self.expected(master, width: col, rowStride: col + 1, boolMask: boolMask))
        #expect(logits[col] == master[col] && logits[2 * col + 1] == master[2 * col + 1])
    }

    enum LogitsType: CustomStringConvertible {
        case float32, float16, bfloat16
        var description: String {
            switch self {
            case .float32: "float32"
            case .float16: "float16"
            case .bfloat16: "bfloat16"
            }
        }
    }

    struct LargeCase: CustomStringConvertible {
        let batchSize: Int, vocabSize: Int, maskedCount: Int, stride: Int, logitsType: LogitsType
        var description: String { "batch \(batchSize), vocab \(vocabSize), masked \(maskedCount), stride \(stride), \(logitsType)" }
    }

    private static let largeCases = [
        LargeCase(batchSize: 1, vocabSize: 128_000, maskedCount: 1024, stride: 1, logitsType: .float32),
        LargeCase(batchSize: 1, vocabSize: 128_000, maskedCount: 120_000, stride: 1, logitsType: .float32),
        LargeCase(batchSize: 1, vocabSize: 128_001, maskedCount: 120_000, stride: 1, logitsType: .float32),
        LargeCase(batchSize: 1, vocabSize: 128_010, maskedCount: 120_000, stride: 1, logitsType: .float32),
    ]

    /// The batch-64 rows generate 8M random logits per case; like upstream's timing rows they run
    /// in release builds or with `TGRAMMAR_PRESSURE=1`.
    private static let largeBatchedCases = [
        LargeCase(batchSize: 64, vocabSize: 128_000, maskedCount: 1024, stride: 1, logitsType: .float32),
        LargeCase(batchSize: 64, vocabSize: 128_000, maskedCount: 120_000, stride: 1, logitsType: .float32),
        LargeCase(batchSize: 64, vocabSize: 128_000, maskedCount: 1024, stride: 4, logitsType: .float32),
        LargeCase(batchSize: 64, vocabSize: 128_000, maskedCount: 120_000, stride: 4, logitsType: .float32),
        LargeCase(batchSize: 64, vocabSize: 128_001, maskedCount: 120_000, stride: 1, logitsType: .float32),
        LargeCase(batchSize: 64, vocabSize: 128_010, maskedCount: 120_000, stride: 1, logitsType: .float32),
        LargeCase(batchSize: 64, vocabSize: 128_000, maskedCount: 1024, stride: 1, logitsType: .float16),
        LargeCase(batchSize: 64, vocabSize: 128_000, maskedCount: 1024, stride: 1, logitsType: .bfloat16),
    ]

    /// `count` distinct positions in `0 ..< vocabSize` (a partial Fisher–Yates shuffle).
    private static func randomPositions(_ count: Int, in vocabSize: Int, using generator: inout SplitMix64) -> ArraySlice<Int> {
        var positions = Array(0 ..< vocabSize)
        for index in 0 ..< count {
            positions.swapAt(index, Int.random(in: index ..< vocabSize, using: &generator))
        }
        return positions[..<count]
    }

    /// `test_apply_token_bitmask_inplace_kernel_large` (CPU rows): `stride` is the batch-index
    /// stride (`torch.arange(0, batch_size, stride)`), selecting every `stride`-th row.
    private static func checkKernelLarge(_ testCase: LargeCase, sourceLocation: SourceLocation = #_sourceLocation) {
        var generator = SplitMix64(seed: UInt64(testCase.vocabSize + testCase.maskedCount + testCase.batchSize))
        var boolMask = [[Bool]](repeating: [Bool](repeating: testCase.maskedCount < testCase.vocabSize, count: testCase.vocabSize), count: testCase.batchSize)
        if testCase.maskedCount < testCase.vocabSize {
            for row in 0 ..< testCase.batchSize {
                for position in randomPositions(testCase.maskedCount, in: testCase.vocabSize, using: &generator) { boolMask[row][position] = false }
                #expect(boolMask[row].count(where: { $0 }) + testCase.maskedCount == testCase.vocabSize, sourceLocation: sourceLocation)
            }
        }
        let batch = Self.batch(boolMask)
        let rows = testCase.stride == 1 ? nil : Array(stride(from: 0, to: testCase.batchSize, by: testCase.stride))
        let logits = (0 ..< testCase.batchSize * testCase.vocabSize).map { _ in Float.random(in: -4 ... 4, using: &generator) }
        let expected = Self.expected(logits, width: testCase.vocabSize, rowStride: testCase.vocabSize, boolMask: boolMask, rows: rows)
        switch testCase.logitsType {
        case .float32:
            var masked = logits
            masked.withUnsafeMutableBufferPointer { batch.apply(to: $0, rows: rows) }
            #expect(masked == expected, sourceLocation: sourceLocation)
        case .float16:
            var masked = logits.map(Float16.init)
            masked.withUnsafeMutableBufferPointer { batch.apply(to: $0, rows: rows) }
            #expect(masked == expected.map(Float16.init), sourceLocation: sourceLocation)
        case .bfloat16:
            // bfloat16 is the top half of the float32 bit pattern.
            var masked = logits.map { UInt16(truncatingIfNeeded: $0.bitPattern >> 16) }
            masked.withUnsafeMutableBufferPointer { batch.apply(toBFloat16: $0, rows: rows) }
            #expect(masked == expected.map { $0 == -.infinity ? 0xFF80 : UInt16(truncatingIfNeeded: $0.bitPattern >> 16) }, sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: largeCases)
    func applyTokenBitmaskInplaceKernelLarge(testCase: LargeCase) {
        Self.checkKernelLarge(testCase)
    }

    @Test(.enabled(if: Upstream.runsPressureTests, Upstream.pressureTestsSkipReason), arguments: largeBatchedCases)
    func applyTokenBitmaskInplaceKernelLargeBatched(testCase: LargeCase) {
        Self.checkKernelLarge(testCase)
    }

    /// `test_apply_token_bitmask_inplace_vocab_size`: the applied width is
    /// `min(logits width, mask bits)`, or the mask's narrower `vocabSize` when one is given.
    @Test(arguments: [
        // logits is larger: (2, 130) vs (2, 4 words) -> 128 entries masked
        (130, 128, 128),
        // bitmask is larger: (2, 120) vs (2, 4 words) -> 120 entries masked
        (120, 128, 120),
        // vocab size is specified: (2, 130) vs (2, 4 words), 120 -> 120 entries masked
        (130, 120, 120),
    ])
    func applyTokenBitmaskInplaceVocabSize(logitsWidth: Int, maskVocabSize: Int, maskedWidth: Int) {
        let batch = TokenMaskBatch(rows: 2, vocabSize: maskVocabSize)
        var logits = [Float](repeating: 1, count: 2 * logitsWidth)
        logits.withUnsafeMutableBufferPointer { batch.apply(to: $0, rowStride: logitsWidth) }
        for row in 0 ..< 2 {
            #expect(logits[row * logitsWidth ..< row * logitsWidth + maskedWidth].allSatisfy { $0 == -.infinity })
            #expect(logits[row * logitsWidth + maskedWidth ..< (row + 1) * logitsWidth].allSatisfy { $0 == 1 })
        }
    }

    private static let indicesCases: [(logitsBatchSize: Int, maskBatchSize: Int, vocabSize: Int, indices: [Int])] = [
        (3, 3, 128, [0, 1]),
        (2, 3, 128, [0]),
        (3, 2, 130, [0]),
    ]

    @Test(arguments: indicesCases)
    func applyTokenBitmaskInplaceIndices(testCase: (logitsBatchSize: Int, maskBatchSize: Int, vocabSize: Int, indices: [Int])) {
        let batch = TokenMaskBatch(rows: testCase.maskBatchSize, vocabSize: testCase.vocabSize)
        var logits = [Float](repeating: 1, count: testCase.logitsBatchSize * testCase.vocabSize)
        logits.withUnsafeMutableBufferPointer { batch.apply(to: $0, rows: testCase.indices) }
        for row in 0 ..< testCase.logitsBatchSize {
            let rowLogits = logits[row * testCase.vocabSize ..< (row + 1) * testCase.vocabSize]
            #expect(rowLogits.allSatisfy { $0 == (testCase.indices.contains(row) ? -.infinity : 1) }, "row \(row)")
        }
    }

    @Test(arguments: indicesCases)
    func applyTokenBitmaskInplaceIndicesBF16(testCase: (logitsBatchSize: Int, maskBatchSize: Int, vocabSize: Int, indices: [Int])) {
        let one: UInt16 = 0x3F80
        let batch = TokenMaskBatch(rows: testCase.maskBatchSize, vocabSize: testCase.vocabSize)
        var logits = [UInt16](repeating: one, count: testCase.logitsBatchSize * testCase.vocabSize)
        logits.withUnsafeMutableBufferPointer { batch.apply(toBFloat16: $0, rows: testCase.indices) }
        for row in 0 ..< testCase.logitsBatchSize {
            let rowLogits = logits[row * testCase.vocabSize ..< (row + 1) * testCase.vocabSize]
            #expect(rowLogits.allSatisfy { $0 == (testCase.indices.contains(row) ? 0xFF80 : one) }, "row \(row)")
        }
    }

    /// A row index outside the logits/mask batch would write out of bounds; it is a precondition
    /// failure instead of a crash in the kernel. Exit tests cannot capture context, so the two
    /// upstream rows (`5`, `-1`) are separate functions.
    @Test func applyTokenBitmaskInplaceIndicesOutOfBoundsHigh() async {
        await #expect(processExitsWith: .failure) {
            let batch = TokenMaskBatch(rows: 2, vocabSize: 128)
            var logits = [Float](repeating: 1, count: 2 * 128)
            logits.withUnsafeMutableBufferPointer { batch.apply(to: $0, rows: [5]) }
        }
    }

    @Test func applyTokenBitmaskInplaceIndicesOutOfBoundsNegative() async {
        await #expect(processExitsWith: .failure) {
            let batch = TokenMaskBatch(rows: 2, vocabSize: 128)
            var logits = [Float](repeating: 1, count: 2 * 128)
            logits.withUnsafeMutableBufferPointer { batch.apply(to: $0, rows: [-1]) }
        }
    }

    /// Regression for mlc-ai/xgrammar#611: a mask narrower than the logits leaves the trailing
    /// logits unmasked. Upstream warns; here the behaviour is documented on `apply(to:)` and the
    /// masking itself is asserted.
    @Test(arguments: [1, 4])
    func applyTokenBitmaskInplaceUndersizedBitmask(batchSize: Int) {
        let batch = TokenMaskBatch(rows: batchSize, vocabSize: 40)  // ceil(40 / 32) = 2 words -> 64 bits < 70
        #expect(batch.wordsPerRow * 32 == 64)
        let wideBatch = TokenMaskBatch(rows: batchSize, vocabSize: 64)
        var logits = [Float](repeating: 1, count: batchSize * 70)
        logits.withUnsafeMutableBufferPointer { wideBatch.apply(to: $0, rowStride: 70) }
        for row in 0 ..< batchSize {
            #expect(logits[row * 70 ..< row * 70 + 64].allSatisfy { $0 == -.infinity })
            #expect(logits[row * 70 + 64 ..< (row + 1) * 70].allSatisfy { $0 == 1 })
        }
        // The 40-token mask itself masks only its own vocabulary.
        logits = [Float](repeating: 1, count: batchSize * 70)
        logits.withUnsafeMutableBufferPointer { batch.apply(to: $0, rowStride: 70) }
        for row in 0 ..< batchSize {
            #expect(logits[row * 70 ..< row * 70 + 40].allSatisfy { $0 == -.infinity })
            #expect(logits[row * 70 + 40 ..< (row + 1) * 70].allSatisfy { $0 == 1 })
        }
    }

    /// Masks wider than, and exactly covering, 64 logits mask all of them.
    @Test(arguments: [96, 64])
    func applyTokenBitmaskInplaceBitmaskCoversLogits(maskVocabSize: Int) {
        let mask = TokenBitmask(vocabSize: maskVocabSize)
        #expect(mask.words.count * 32 >= 64)
        var logits = [Float](repeating: 1, count: 64)
        mask.apply(to: &logits)
        #expect(logits.allSatisfy { $0 == -.infinity })
    }

    @Test func applyTokenBitmaskInplaceGivenVocabSize() {
        let mask = TokenBitmask(vocabSize: 40)
        var logits = [Float](repeating: 1, count: 70)
        mask.apply(to: &logits)
        #expect(logits[..<40].allSatisfy { $0 == -.infinity })
        #expect(logits[40...].allSatisfy { $0 == 1 })
    }

    @Test func applyToEmptyBuffers() {
        let mask = TokenBitmask(vocabSize: 0)
        var empty: [Float] = []
        mask.apply(to: &empty)
        #expect(empty.isEmpty)
        var logits: [Float] = [1, 2]
        mask.apply(to: &logits)
        #expect(logits == [1, 2])
        let batch = TokenMaskBatch(rows: 0, vocabSize: 16)
        var none: [Float] = []
        none.withUnsafeMutableBufferPointer { batch.apply(to: $0) }
    }
}
