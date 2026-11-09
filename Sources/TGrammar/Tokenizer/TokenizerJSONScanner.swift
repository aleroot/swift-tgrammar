// A minimal byte-level reader for the vocabulary parts of a Hugging Face `tokenizer.json`.
//
// Foundation's parsers cannot read a vocabulary faithfully: `JSONSerialization` strips a leading
// U+FEFF from every string, and both it and `JSONDecoder` key objects by `String`, which merges
// pieces that are distinct byte sequences but canonically equivalent (the Llama 2 vocabulary has
// seven such pairs and a lone U+FEFF piece). Token ids must stay aligned with the model's
// embedding rows, so the pieces are read straight from the bytes, in one pass, without
// intermediate `Dictionary` keys. The pipeline metadata (decoder, normalizer, pre-tokenizer) only
// has ASCII keys and simple values and keeps using `JSONSerialization`.

import Foundation

struct TokenizerJSONScanner {
    enum ScanError: Error {
        case malformed(offset: Int)
        var offset: Int { switch self { case .malformed(let offset): offset } }
    }

    private let bytes: UnsafeBufferPointer<UInt8>
    private var position = 0

    private init(_ bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    /// The vocabulary (`model.vocab` merged with `added_tokens`, indexed by id, holes left
    /// empty) and the raw JSON of the top-level members named in `metadataKeys`.
    ///
    /// One pass over the document; pieces are collected into a single byte buffer, so the whole
    /// vocabulary costs a few allocations instead of one `String` and dictionary entry per piece.
    static func scan(_ data: Data, metadataKeys: [String] = []) throws(TokenizerInfoError) -> (vocabulary: ByteStringTable, metadata: [String: Data]) {
        let result = data.withUnsafeBytes { raw -> Result<(ByteStringTable, [String: Range<Int>]), ScanError> in
            var scanner = Self(raw.bindMemory(to: UInt8.self))
            let keys = metadataKeys.map { Array($0.utf8) }
            return Result { () throws(ScanError) in try scanner.document(metadataKeys: keys) }
        }
        switch result {
        case .success(let (vocabulary, ranges)):
            var metadata: [String: Data] = [:]
            for (key, range) in ranges { metadata[key] = data.subdata(in: data.startIndex + range.lowerBound ..< data.startIndex + range.upperBound) }
            return (vocabulary, metadata)
        case .failure(let error): throw .invalidTokenizerJSON("malformed vocabulary at byte \(error.offset)")
        }
    }

    /// Pieces indexed by id (`model.vocab` merged with `added_tokens`), with holes left empty.
    static func pieces(in data: Data) throws(TokenizerInfoError) -> [String] {
        try scan(data).vocabulary.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Pieces in document order with their ids; later pieces for the same id win.
    private struct PieceCollector {
        var bytes: [UInt8] = []
        var ids: [Int32] = []
        var ends: [UInt32] = []

        mutating func add(_ id: Int, _ piece: [UInt8]) {
            guard id >= 0, id <= Int(Int32.max) else { return }
            bytes.append(contentsOf: piece)
            ids.append(Int32(id))
            ends.append(UInt32(truncatingIfNeeded: bytes.count))
        }

        func table() -> ByteStringTable {
            guard let maxID = ids.max() else { return ByteStringTable() }
            var latest = [Int32](repeating: -1, count: Int(maxID) + 1)
            for (index, id) in ids.enumerated() { latest[Int(id)] = Int32(index) }
            var table = ByteStringTable(capacity: latest.count, byteCapacity: bytes.count)
            bytes.withUnsafeBufferPointer { bytes in
                for index in latest {
                    if index < 0 { table.append(EmptyCollection()); continue }
                    let start = index == 0 ? 0 : Int(ends[Int(index) - 1])
                    table.append(UnsafeBufferPointer(rebasing: bytes[start ..< Int(ends[Int(index)])]))
                }
            }
            return table
        }
    }

    // MARK: Document walk

    private mutating func document(metadataKeys: [[UInt8]]) throws(ScanError) -> (ByteStringTable, [String: Range<Int>]) {
        var collector = PieceCollector()
        var metadata: [String: Range<Int>] = [:]
        var key: [UInt8] = []
        try expect(UInt8(ascii: "{"))
        try members { scanner throws(ScanError) in
            try scanner.string(into: &key)
            try scanner.expect(UInt8(ascii: ":"))
            switch key {
            case Array("model".utf8): try scanner.model(into: &collector)
            case Array("added_tokens".utf8): try scanner.addedTokens(into: &collector)
            default:
                scanner.skipWhitespace()
                let start = scanner.position
                try scanner.skipValue()
                if metadataKeys.contains(key) { metadata[String(decoding: key, as: UTF8.self)] = start ..< scanner.position }
            }
        }
        skipWhitespace()
        guard position == bytes.count else { throw malformed() }
        return (collector.table(), metadata)
    }

    private mutating func model(into collector: inout PieceCollector) throws(ScanError) {
        skipWhitespace()
        guard peek() == UInt8(ascii: "{") else { try skipValue(); return }
        position += 1
        var key: [UInt8] = []
        try members { scanner throws(ScanError) in
            try scanner.string(into: &key)
            try scanner.expect(UInt8(ascii: ":"))
            guard key == Array("vocab".utf8) else { try scanner.skipValue(); return }
            try scanner.vocab(into: &collector)
        }
    }

    /// `{"piece": id, ...}` for BPE/WordPiece, or `[["piece", score], ...]` for Unigram.
    private mutating func vocab(into collector: inout PieceCollector) throws(ScanError) {
        skipWhitespace()
        var piece: [UInt8] = []
        switch peek() {
        case UInt8(ascii: "{"):
            position += 1
            try members { scanner throws(ScanError) in
                try scanner.string(into: &piece)
                try scanner.expect(UInt8(ascii: ":"))
                collector.add(try scanner.integer(), piece)
            }
        case UInt8(ascii: "["):
            position += 1
            var id = 0
            try elements { scanner throws(ScanError) in
                scanner.skipWhitespace()
                guard scanner.peek() == UInt8(ascii: "[") else { try scanner.skipValue(); id += 1; return }
                scanner.position += 1
                var first = true
                try scanner.elements { scanner throws(ScanError) in
                    if first {
                        scanner.skipWhitespace()
                        if scanner.peek() == UInt8(ascii: "\"") {
                            try scanner.string(into: &piece)
                            collector.add(id, piece)
                        } else { try scanner.skipValue() }
                        first = false
                    } else { try scanner.skipValue() }
                }
                id += 1
            }
        default:
            try skipValue()
        }
    }

    /// `[{"id": 1, "content": "<s>", ...}, ...]`.
    private mutating func addedTokens(into collector: inout PieceCollector) throws(ScanError) {
        skipWhitespace()
        guard peek() == UInt8(ascii: "[") else { try skipValue(); return }
        position += 1
        var key: [UInt8] = []
        var content: [UInt8] = []
        try elements { scanner throws(ScanError) in
            scanner.skipWhitespace()
            guard scanner.peek() == UInt8(ascii: "{") else { try scanner.skipValue(); return }
            scanner.position += 1
            var id: Int? = nil
            var hasContent = false
            try scanner.members { scanner throws(ScanError) in
                try scanner.string(into: &key)
                try scanner.expect(UInt8(ascii: ":"))
                switch key {
                case Array("id".utf8): id = try scanner.integer()
                case Array("content".utf8):
                    scanner.skipWhitespace()
                    if scanner.peek() == UInt8(ascii: "\"") {
                        try scanner.string(into: &content)
                        hasContent = true
                    } else { try scanner.skipValue() }
                default: try scanner.skipValue()
                }
            }
            if let id, hasContent { collector.add(id, content) }
        }
    }

    // MARK: Structure

    /// Calls `body` for each member of an object whose `{` has been consumed; `body` must consume
    /// the key, the colon and the value. Consumes the closing `}`.
    private mutating func members(_ body: (inout Self) throws(ScanError) -> Void) throws(ScanError) {
        skipWhitespace()
        if peek() == UInt8(ascii: "}") { position += 1; return }
        while true {
            skipWhitespace()
            try body(&self)
            skipWhitespace()
            switch next() {
            case UInt8(ascii: ","): continue
            case UInt8(ascii: "}"): return
            default: throw malformed()
            }
        }
    }

    /// Calls `body` for each element of an array whose `[` has been consumed; `body` must
    /// consume the value. Consumes the closing `]`.
    private mutating func elements(_ body: (inout Self) throws(ScanError) -> Void) throws(ScanError) {
        skipWhitespace()
        if peek() == UInt8(ascii: "]") { position += 1; return }
        while true {
            try body(&self)
            skipWhitespace()
            switch next() {
            case UInt8(ascii: ","): continue
            case UInt8(ascii: "]"): return
            default: throw malformed()
            }
        }
    }

    private mutating func skipValue() throws(ScanError) {
        skipWhitespace()
        guard let first = peek() else { throw malformed() }
        switch first {
        case UInt8(ascii: "\""):
            try skipString()
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            // Containers are skipped without recursion: track nesting and skip strings whole.
            var depth = 0
            while let byte = peek() {
                switch byte {
                case UInt8(ascii: "\""): try skipString(); continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
                default: break
                }
                position += 1
                if depth == 0 { return }
            }
            throw malformed()
        default:
            // Number or literal: runs to the next structural character.
            while let byte = peek(), byte != UInt8(ascii: ","), byte != UInt8(ascii: "}"), byte != UInt8(ascii: "]"),
                  byte != UInt8(ascii: " "), byte != UInt8(ascii: "\n"), byte != UInt8(ascii: "\r"), byte != UInt8(ascii: "\t") {
                position += 1
            }
        }
    }

    // MARK: Scalars

    /// Reads a string literal, decoding escapes to UTF-8 bytes in `output`.
    private mutating func string(into output: inout [UInt8]) throws(ScanError) {
        skipWhitespace()
        try expect(UInt8(ascii: "\""))
        output.removeAll(keepingCapacity: true)
        while let byte = peek() {
            position += 1
            switch byte {
            case UInt8(ascii: "\""):
                return
            case UInt8(ascii: "\\"):
                guard let escape = next() else { throw malformed() }
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): output.append(escape)
                case UInt8(ascii: "b"): output.append(8)
                case UInt8(ascii: "f"): output.append(12)
                case UInt8(ascii: "n"): output.append(10)
                case UInt8(ascii: "r"): output.append(13)
                case UInt8(ascii: "t"): output.append(9)
                case UInt8(ascii: "u"):
                    var codepoint = try hex4()
                    if (0xD800 ... 0xDBFF).contains(codepoint) {
                        guard next() == UInt8(ascii: "\\"), next() == UInt8(ascii: "u") else { throw malformed() }
                        let low = try hex4()
                        guard (0xDC00 ... 0xDFFF).contains(low) else { throw malformed() }
                        codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00)
                    }
                    UTF8Codec.encode(Codepoint(codepoint), into: &output)
                default: throw malformed()
                }
            default:
                output.append(byte)
            }
        }
        throw malformed()
    }

    private mutating func skipString() throws(ScanError) {
        try expect(UInt8(ascii: "\""))
        while let byte = peek() {
            position += 1
            if byte == UInt8(ascii: "\\") { position += 1 } else if byte == UInt8(ascii: "\"") { return }
        }
        throw malformed()
    }

    private mutating func hex4() throws(ScanError) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0 ..< 4 {
            guard let byte = next() else { throw malformed() }
            let digit = EscapeCodec.hexValue(byte)
            guard digit >= 0 else { throw malformed() }
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    private mutating func integer() throws(ScanError) -> Int {
        skipWhitespace()
        var negative = false
        if peek() == UInt8(ascii: "-") { negative = true; position += 1 }
        guard let first = peek(), (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(first) else { throw malformed() }
        var value = 0
        while let byte = peek(), (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) {
            let (product, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = product.addingReportingOverflow(Int(byte &- UInt8(ascii: "0")))
            guard !overflow1, !overflow2 else { throw malformed() }
            value = sum
            position += 1
        }
        // A fractional or exponent part would make this a non-integer id.
        if let byte = peek(), byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") { throw malformed() }
        return negative ? -value : value
    }

    // MARK: Bytes

    @inline(__always)
    private func peek() -> UInt8? { position < bytes.count ? bytes[position] : nil }

    @inline(__always)
    private mutating func next() -> UInt8? {
        guard position < bytes.count else { return nil }
        defer { position += 1 }
        return bytes[position]
    }

    @inline(__always)
    private mutating func skipWhitespace() {
        while position < bytes.count {
            switch bytes[position] {
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"): position += 1
            default: return
            }
        }
    }

    private mutating func expect(_ byte: UInt8) throws(ScanError) {
        skipWhitespace()
        guard next() == byte else { throw malformed() }
    }

    private func malformed() -> ScanError { .malformed(offset: position) }
}
