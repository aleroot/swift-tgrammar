// Byte-level encoding of code point ranges into automaton edges. A code point's UTF-8 bytes are
// packed left-aligned into a `UInt32` (`b0<<24 | b1<<16 | b2<<8 | b3` for four bytes, `b0<<8 | b1`
// for two, …) so that a range of same-length characters is a range of integers that can be split
// byte by byte into chains of edges.

enum UTF8Ranges {
    static let max1Byte: UInt32 = 0x7F
    static let min2Bytes: UInt32 = 0xC080
    static let max2Bytes: UInt32 = 0xDFBF
    static let min3Bytes: UInt32 = 0xE0_8080
    static let max3Bytes: UInt32 = 0xEF_BFBF
    static let min4Bytes: UInt32 = 0xF080_8080
    static let max4Bytes: UInt32 = 0xF7BF_BFBF

    static let maxCodepoint: UInt32 = 0x10FFFF

    /// Packs the UTF-8 bytes of `codepoint` as described above.
    static func packed(_ codepoint: UInt32) -> UInt32 {
        if codepoint <= 0x7F { return codepoint }
        if codepoint <= 0x7FF {
            let byte0 = 0xC0 | ((codepoint >> 6) & 0x1F)
            let byte1 = 0x80 | (codepoint & 0x3F)
            return (byte0 << 8) | byte1
        }
        if codepoint <= 0xFFFF {
            let byte0 = 0xE0 | ((codepoint >> 12) & 0x0F)
            let byte1 = 0x80 | ((codepoint >> 6) & 0x3F)
            let byte2 = 0x80 | (codepoint & 0x3F)
            return (byte0 << 16) | (byte1 << 8) | byte2
        }
        let byte0 = 0xF0 | ((codepoint >> 18) & 0x07)
        let byte1 = 0x80 | ((codepoint >> 12) & 0x3F)
        let byte2 = 0x80 | ((codepoint >> 6) & 0x3F)
        let byte3 = 0x80 | (codepoint & 0x3F)
        return (byte0 << 24) | (byte1 << 16) | (byte2 << 8) | byte3
    }

    /// Adds edges `from → to` accepting every character whose packed encoding lies in
    /// `[min, max]`, where both bounds have the same encoded length.
    private static func addSameLengthRange(_ fsm: inout FSM, from: Int32, to: Int32, min: UInt32, max: UInt32) {
        var byteMin = (UInt8(min & 0xFF), UInt8((min >> 8) & 0xFF), UInt8((min >> 16) & 0xFF), UInt8(min >> 24))
        var byteMax = (UInt8(max & 0xFF), UInt8((max >> 8) & 0xFF), UInt8((max >> 16) & 0xFF), UInt8(max >> 24))

        if byteMax.1 == 0 {
            fsm.addEdge(from: from, to: to, min: Int32(byteMin.0), max: Int32(byteMax.0))
            return
        }

        if byteMax.3 != 0 {
            if byteMax.3 == byteMin.3 {
                let middle = fsm.addState()
                fsm.addEdge(from: from, to: middle, min: Int32(byteMin.3), max: Int32(byteMax.3))
                addSameLengthRange(&fsm, from: middle, to: to, min: min & 0x00FF_FFFF, max: max & 0x00FF_FFFF)
                return
            }
            if min & 0x00FF_FFFF != 0x80_8080 {
                let lowState = fsm.addState()
                fsm.addEdge(from: from, to: lowState, min: Int32(byteMin.3), max: Int32(byteMin.3))
                addSameLengthRange(&fsm, from: lowState, to: to, min: min & 0x00FF_FFFF, max: 0x00BF_BFBF)
            } else {
                byteMin.3 &-= 1
            }
            if max & 0x00FF_FFFF != 0xBF_BFBF {
                let highState = fsm.addState()
                fsm.addEdge(from: from, to: highState, min: Int32(byteMax.3), max: Int32(byteMax.3))
                addSameLengthRange(&fsm, from: highState, to: to, min: 0x0080_8080, max: max & 0x00FF_FFFF)
            } else {
                byteMax.3 &+= 1
            }
            if Int32(byteMax.3) - Int32(byteMin.3) > 1 {
                let mid1 = fsm.addState()
                fsm.addEdge(from: from, to: mid1, min: Int32(byteMin.3) + 1, max: Int32(byteMax.3) - 1)
                let mid2 = fsm.addState()
                fsm.addEdge(from: mid1, to: mid2, min: 0x80, max: 0xBF)
                let mid3 = fsm.addState()
                fsm.addEdge(from: mid2, to: mid3, min: 0x80, max: 0xBF)
                fsm.addEdge(from: mid3, to: to, min: 0x80, max: 0xBF)
            }
            return
        }

        if byteMax.2 != 0 {
            if byteMax.2 == byteMin.2 {
                let middle = fsm.addState()
                fsm.addEdge(from: from, to: middle, min: Int32(byteMin.2), max: Int32(byteMax.2))
                addSameLengthRange(&fsm, from: middle, to: to, min: min & 0x00FFFF, max: max & 0x00FFFF)
                return
            }
            if min & 0x00FFFF != 0x8080 {
                let lowState = fsm.addState()
                fsm.addEdge(from: from, to: lowState, min: Int32(byteMin.2), max: Int32(byteMin.2))
                addSameLengthRange(&fsm, from: lowState, to: to, min: min & 0x00FFFF, max: 0x00BFBF)
            } else {
                byteMin.2 &-= 1
            }
            if max & 0x00FFFF != 0xBFBF {
                let highState = fsm.addState()
                fsm.addEdge(from: from, to: highState, min: Int32(byteMax.2), max: Int32(byteMax.2))
                addSameLengthRange(&fsm, from: highState, to: to, min: 0x008080, max: max & 0x00FFFF)
            } else {
                byteMax.2 &+= 1
            }
            if Int32(byteMax.2) - Int32(byteMin.2) > 1 {
                let mid1 = fsm.addState()
                fsm.addEdge(from: from, to: mid1, min: Int32(byteMin.2) + 1, max: Int32(byteMax.2) - 1)
                let mid2 = fsm.addState()
                fsm.addEdge(from: mid1, to: mid2, min: 0x80, max: 0xBF)
                fsm.addEdge(from: mid2, to: to, min: 0x80, max: 0xBF)
            }
            return
        }

        if byteMax.1 == byteMin.1 {
            let middle = fsm.addState()
            fsm.addEdge(from: from, to: middle, min: Int32(byteMin.1), max: Int32(byteMax.1))
            addSameLengthRange(&fsm, from: middle, to: to, min: min & 0x00FF, max: max & 0x00FF)
            return
        }
        if min & 0x00FF != 0x80 {
            let lowState = fsm.addState()
            fsm.addEdge(from: from, to: lowState, min: Int32(byteMin.1), max: Int32(byteMin.1))
            addSameLengthRange(&fsm, from: lowState, to: to, min: min & 0x00FF, max: 0x00BF)
        } else {
            byteMin.1 &-= 1
        }
        if max & 0x00FF != 0xBF {
            let highState = fsm.addState()
            fsm.addEdge(from: from, to: highState, min: Int32(byteMax.1), max: Int32(byteMax.1))
            addSameLengthRange(&fsm, from: highState, to: to, min: 0x0080, max: max & 0x00FF)
        } else {
            byteMax.1 &+= 1
        }
        if Int32(byteMax.1) - Int32(byteMin.1) > 1 {
            let middle = fsm.addState()
            fsm.addEdge(from: from, to: middle, min: Int32(byteMin.1) + 1, max: Int32(byteMax.1) - 1)
            fsm.addEdge(from: middle, to: to, min: 0x80, max: 0xBF)
        }
    }

    /// Adds edges (with intermediate states for multi-byte characters) `from → to` accepting
    /// every UTF-8 character whose packed encoding lies in `[min, max]`.
    static func addPackedRangeEdges(_ fsm: inout FSM, from: Int32, to: Int32, min rawMin: UInt32, max rawMax: UInt32) {
        precondition(rawMin <= rawMax, "Invalid character range: min (\(rawMin)) > max (\(rawMax))")
        var min = rawMin
        var max = rawMax
        if max > max4Bytes {
            max = max4Bytes
        } else if max > max3Bytes {
            if max < min4Bytes { max = max3Bytes }
        } else if max > max2Bytes {
            if max < min3Bytes { max = max2Bytes }
        } else if max < min2Bytes, max > max1Byte {
            max = max1Byte
        }
        if min > max4Bytes {
            min = max4Bytes
        } else if min > max3Bytes {
            if min < min4Bytes { min = min4Bytes }
        } else if min > max2Bytes {
            if min < min3Bytes { min = min3Bytes }
        } else if min < min2Bytes, min > max1Byte {
            min = min2Bytes
        }

        if max <= max1Byte {
            addSameLengthRange(&fsm, from: from, to: to, min: min, max: max)
            return
        }
        if max <= max2Bytes {
            if min >= min2Bytes {
                addSameLengthRange(&fsm, from: from, to: to, min: min, max: max)
            } else {
                addSameLengthRange(&fsm, from: from, to: to, min: min, max: max1Byte)
                addSameLengthRange(&fsm, from: from, to: to, min: min2Bytes, max: max)
            }
            return
        }
        if max <= max3Bytes {
            if min >= min3Bytes {
                addSameLengthRange(&fsm, from: from, to: to, min: min, max: max)
            } else if min >= min2Bytes {
                addSameLengthRange(&fsm, from: from, to: to, min: min, max: max2Bytes)
                addSameLengthRange(&fsm, from: from, to: to, min: min3Bytes, max: max)
            } else {
                addSameLengthRange(&fsm, from: from, to: to, min: min, max: max1Byte)
                addSameLengthRange(&fsm, from: from, to: to, min: min2Bytes, max: max2Bytes)
                addSameLengthRange(&fsm, from: from, to: to, min: min3Bytes, max: max)
            }
            return
        }
        if min >= min4Bytes {
            addSameLengthRange(&fsm, from: from, to: to, min: min, max: max)
        } else if min >= min3Bytes {
            addSameLengthRange(&fsm, from: from, to: to, min: min, max: max3Bytes)
            addSameLengthRange(&fsm, from: from, to: to, min: min4Bytes, max: max)
        } else if min >= min2Bytes {
            addSameLengthRange(&fsm, from: from, to: to, min: min, max: max2Bytes)
            addSameLengthRange(&fsm, from: from, to: to, min: min3Bytes, max: max3Bytes)
            addSameLengthRange(&fsm, from: from, to: to, min: min4Bytes, max: max)
        } else {
            addSameLengthRange(&fsm, from: from, to: to, min: min, max: max1Byte)
            addSameLengthRange(&fsm, from: from, to: to, min: min2Bytes, max: max2Bytes)
            addSameLengthRange(&fsm, from: from, to: to, min: min3Bytes, max: max3Bytes)
            addSameLengthRange(&fsm, from: from, to: to, min: min4Bytes, max: max)
        }
    }

    /// Adds edges accepting every code point in `[low, high]`, one packed range per UTF-8
    /// width so that no overlong encoding is produced.
    static func addCodepointRangeEdges(_ fsm: inout FSM, from: Int32, to: Int32, low rawLow: UInt32, high: UInt32) {
        var low = rawLow
        for widthEnd: UInt32 in [0x7F, 0x7FF, 0xFFFF, 0x10FFFF] where low <= high && low <= widthEnd {
            let end = min(high, widthEnd)
            addPackedRangeEdges(&fsm, from: from, to: to, min: packed(low), max: packed(end))
            low = end &+ 1
        }
    }
}
