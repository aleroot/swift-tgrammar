// Swift-only: the word-scanning run iterator of `ByteSet`, which the token-mask computation
// uses to turn the bytes a state accepts first into intervals of the sorted vocabulary.

import Testing

@testable import TGrammar

@Suite("Byte set")
struct ByteSetTests {
    private func naiveRuns(_ set: ByteSet) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start = -1
        for byte in 0 ... 256 {
            if byte < 256, set.contains(UInt8(byte)) {
                if start == -1 { start = byte }
            } else if start != -1 {
                runs.append(start ..< byte)
                start = -1
            }
        }
        return runs
    }

    private func runs(_ set: ByteSet) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        set.forEachRun { runs.append($0 ..< $1) }
        return runs
    }

    @Test func runsMatchAByteByByteScan() {
        var sets: [ByteSet] = [ByteSet(), .all, ByteSet([0]), ByteSet([255]), ByteSet([63, 64]),
                               ByteSet(range: 0x30 ... 0x39), ByteSet(range: 60 ... 200), ByteSet([0, 2, 127, 128, 191, 192, 254, 255])]
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 200 {
            var set = ByteSet()
            for _ in 0 ..< Int.random(in: 0 ... 40, using: &generator) {
                let lower = Int32.random(in: 0 ... 255, using: &generator)
                set.insert(range: lower ... min(255, lower + Int32.random(in: 0 ... 12, using: &generator)))
            }
            sets.append(set)
        }
        for set in sets { #expect(runs(set) == naiveRuns(set)) }
    }

    @Test func firstByteBoundsDelimitTokensByFirstByte() throws {
        let info = try TokenizerInfo(encodedVocab: ["", "a", "ab", "b", "\u{7F}", "é", "ÿ", "0", "00", "</s>"])
        let sorted = info.sortedTokens
        #expect(info.firstByteBounds.count == 257)
        for byte in 0 ... 256 {
            let expected = (0 ..< sorted.count).first { index in
                guard let first = sorted[index].first else { return false }
                return Int(first) >= byte
            } ?? sorted.count
            #expect(Int(info.firstByteBounds[byte]) == expected, "byte \(byte)")
        }
    }
}
