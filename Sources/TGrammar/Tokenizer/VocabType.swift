// Vocabulary encodings and the decoders that turn a tokenizer's piece strings back into the raw
// bytes the model actually emits. Grammars are matched on those bytes, so decoding has to be exact:
// `<0x1B>` is the single byte 0x1B, `Ġ` is a space, `▁` is a space.

/// How a tokenizer spells its vocabulary.
public enum VocabType: Int32, Sendable, Hashable, CaseIterable, Codable, CustomStringConvertible {
    /// Pieces are kept verbatim (tiktoken-style tokenizers such as Phi-3-small or Qwen-7B-Chat).
    case raw = 0
    /// SentencePiece byte-fallback: `"\u{1B}"` is spelled `<0x1B>`, `" apple"` is `▁apple`
    /// (Llama 2, Mistral, Phi-3.5, Gemma).
    case byteFallback = 1
    /// GPT-2 byte-level BPE: every byte maps to a printable Unicode scalar, so `" apple"` is
    /// `Ġapple` (GPT-2, Llama 3, Qwen2, DeepSeek).
    case byteLevel = 2

    public var description: String {
        switch self {
        case .raw: "raw"
        case .byteFallback: "byteFallback"
        case .byteLevel: "byteLevel"
        }
    }
}

// MARK: - Byte-level alphabet

/// The GPT-2 `bytes_to_unicode` mapping and its inverse.
///
/// Printable Latin-1 bytes (`0x21...0x7E`, `0xA1...0xAC`, `0xAE...0xFF`) map to themselves; the
/// remaining 68 bytes are shifted to `U+0100...U+0143` in increasing byte order.
enum ByteLevelAlphabet {
    /// `byteToScalar[b]` is the scalar that spells byte `b`.
    static let byteToScalar: [Codepoint] = {
        var table = [Codepoint](repeating: 0, count: 256)
        var next: Codepoint = 256
        for byte in 0 ..< 256 {
            if isIdentityByte(byte) {
                table[byte] = Codepoint(byte)
            } else {
                table[byte] = next
                next += 1
            }
        }
        return table
    }()

    /// `scalarToByte[s]` is the byte spelled by scalar `s`, or `-1`. Covers `U+0000...U+0143`.
    static let scalarToByte: [Int16] = {
        var table = [Int16](repeating: -1, count: 0x144)
        for byte in 0 ..< 256 {
            table[Int(byteToScalar[byte])] = Int16(byte)
        }
        return table
    }()

    /// The 256 single-scalar strings of the alphabet.
    static let characters: Set<String> = Set(byteToScalar.map { String(UnicodeScalar(UInt32($0))!) })

    @inline(__always)
    static func isIdentityByte(_ byte: Int) -> Bool {
        (0x21 ... 0x7E).contains(byte) || (0xA1 ... 0xAC).contains(byte) || (0xAE ... 0xFF).contains(byte)
    }

    /// Byte spelled by `codepoint`, or `nil` when the scalar is outside the alphabet.
    @inline(__always)
    static func byte(for codepoint: Codepoint) -> UInt8? {
        guard codepoint >= 0, Int(codepoint) < scalarToByte.count else { return nil }
        let byte = scalarToByte[Int(codepoint)]
        return byte < 0 ? nil : UInt8(truncatingIfNeeded: byte)
    }

    /// Whether every scalar of `token` belongs to the alphabet.
    static func spells(_ token: String) -> Bool {
        token.unicodeScalars.allSatisfy { byte(for: Codepoint($0.value)) != nil }
    }
}

// MARK: - Detection from the vocabulary itself

extension VocabType {
    /// Detects the vocabulary encoding from the pieces alone, or `nil` when the vocabulary clearly
    /// matches neither byte encoding (e.g. a WordPiece vocabulary).
    ///
    /// A byte-fallback vocabulary contains (most of) the 256 pieces `<0x00>`…`<0xFF>`. A
    /// byte-level vocabulary spells every token with the 256-scalar byte-to-unicode alphabet and
    /// contains most of that alphabet as single-scalar tokens. Both are properties of the
    /// vocabulary itself, so they remain valid when a serialized `tokenizer.json` does not describe
    /// the vocabulary faithfully; the byte pieces take precedence because a large multilingual
    /// byte-fallback vocabulary (e.g. Gemma) may contain the whole byte-level alphabet as ordinary
    /// pieces.
    public static func detect(fromVocab vocab: some Collection<String>) -> VocabType? {
        var pieces = Set<String>()
        pieces.reserveCapacity(vocab.count)
        for token in vocab { pieces.insert(token) }
        return detect(fromPieces: pieces)
    }

    /// See ``detect(fromVocab:)``.
    public static func detect(fromVocab vocab: [String: Int]) -> VocabType? {
        detect(fromPieces: Set(vocab.keys))
    }

    static func detect(fromPieces pieces: Set<String>) -> VocabType? {
        var bytePieces = 0
        for byte in 0 ..< 256 where pieces.contains(TokenDecoder.byteFallbackPiece(byte)) {
            bytePieces += 1
        }
        if bytePieces >= 128 { return .byteFallback }

        var singleScalars = 0
        for character in ByteLevelAlphabet.characters where pieces.contains(character) {
            singleScalars += 1
        }
        if singleScalars < 128 { return nil }

        // Added tokens (chat-template markers) may contain scalars outside the alphabet; tolerate
        // a small fraction of such tokens.
        var alphabetTokens = 0
        for token in pieces where ByteLevelAlphabet.spells(token) {
            alphabetTokens += 1
        }
        return Double(alphabetTokens) >= 0.99 * Double(pieces.count) ? .byteLevel : nil
    }
}

extension VocabType {
    /// ``detect(fromVocab:)`` over packed pieces, without materializing a `String` per piece.
    /// Pieces are counted with multiplicity rather than as a set; vocabularies have no duplicate
    /// pieces apart from empty holes, which are counted once, as in the set.
    static func detect(fromTable vocab: ByteStringTable) -> VocabType? {
        var bytePieces = ByteSet()
        var singleScalars = ByteSet()
        var pieces = 0
        var alphabetTokens = 0
        var sawEmpty = false
        vocab.withUnsafeStorage { bytes, offsets in
            for index in 0 ..< vocab.count {
                let piece = UnsafeBufferPointer(rebasing: bytes[Int(offsets[index]) ..< Int(offsets[index + 1])])
                if piece.isEmpty {
                    if !sawEmpty { sawEmpty = true; pieces += 1; alphabetTokens += 1 }
                    continue
                }
                pieces += 1
                // `<0xNN>` with upper-case digits, as ``TokenDecoder/byteFallbackPiece(_:)`` spells it.
                if let byte = TokenDecoder.byteFallbackByte(piece), !(0x61 ... 0x66).contains(piece[3]), !(0x61 ... 0x66).contains(piece[4]) {
                    bytePieces.insert(byte)
                }
                var spelled = true
                var scalars = 0
                var lastByte: UInt8 = 0
                var i = 0
                while i < piece.count {
                    let (codepoint, length) = UTF8Codec.decode(piece, at: i)
                    guard codepoint >= 0, let byte = ByteLevelAlphabet.byte(for: codepoint) else { spelled = false; break }
                    lastByte = byte
                    scalars += 1
                    i += length
                }
                if spelled {
                    alphabetTokens += 1
                    if scalars == 1 { singleScalars.insert(lastByte) }
                }
            }
        }
        if bytePieces.count >= 128 { return .byteFallback }
        if singleScalars.count < 128 { return nil }
        return Double(alphabetTokens) >= 0.99 * Double(pieces) ? .byteLevel : nil
    }
}

// MARK: - Token decoder

/// Converts encoded pieces to raw bytes according to a ``VocabType``.
enum TokenDecoder {
    /// The piece spelling byte `byte` in a byte-fallback vocabulary (`<0x0A>`).
    static func byteFallbackPiece(_ byte: Int) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        return "<0x\(UnicodeScalar(digits[byte >> 4]))\(UnicodeScalar(digits[byte & 0xF]))>"
    }

    /// Appends the conventional spelling of decoded token bytes: verbatim for raw vocabularies,
    /// the byte-to-unicode alphabet for byte-level ones, and `▁` for spaces (or `<0xNN>` for a
    /// single byte) for byte-fallback ones. Decoding the result gives `bytes` back.
    static func appendConventionalPiece(_ bytes: some Collection<UInt8>, as vocabType: VocabType, into output: inout [UInt8]) {
        switch vocabType {
        case .raw:
            output.append(contentsOf: bytes)
        case .byteLevel:
            for byte in bytes { UTF8Codec.encode(ByteLevelAlphabet.byteToScalar[Int(byte)], into: &output) }
        case .byteFallback:
            if bytes.count == 1, let byte = bytes.first {
                output.append(contentsOf: byteFallbackPiece(Int(byte)).utf8)
                return
            }
            for byte in bytes {
                if byte == UInt8(ascii: " ") { output.append(contentsOf: [0xE2, 0x96, 0x81]) } else { output.append(byte) }
            }
        }
    }

    /// Appends the decoded bytes of `piece` to `output`.
    static func decode(_ piece: UnsafeBufferPointer<UInt8>, as vocabType: VocabType, into output: inout [UInt8]) {
        switch vocabType {
        case .raw:
            output.append(contentsOf: piece)
        case .byteFallback:
            if let byte = byteFallbackByte(piece) {
                output.append(byte)
            } else {
                replaceSpaceMarkers(piece, into: &output)
            }
        case .byteLevel:
            decodeByteLevel(piece, into: &output)
        }
    }

    /// The byte spelled by a `<0xNN>` piece, or `nil`.
    @inline(__always)
    static func byteFallbackByte(_ piece: UnsafeBufferPointer<UInt8>) -> UInt8? {
        guard piece.count == 6,
              piece[0] == UInt8(ascii: "<"), piece[1] == UInt8(ascii: "0"), piece[2] == UInt8(ascii: "x"),
              piece[5] == UInt8(ascii: ">")
        else { return nil }
        let high = EscapeCodec.hexValue(piece[3]), low = EscapeCodec.hexValue(piece[4])
        guard high >= 0, low >= 0 else { return nil }
        return UInt8(high << 4 | low)
    }

    /// Replaces every `▁` (U+2581, bytes `E2 96 81`) with a space.
    static func replaceSpaceMarkers(_ piece: UnsafeBufferPointer<UInt8>, into output: inout [UInt8]) {
        var i = 0
        let n = piece.count
        while i < n {
            if i + 2 < n, piece[i] == 0xE2, piece[i + 1] == 0x96, piece[i + 2] == 0x81 {
                output.append(UInt8(ascii: " "))
                i += 3
            } else {
                output.append(piece[i])
                i += 1
            }
        }
    }

    /// Inverts the GPT-2 byte-to-unicode mapping. A piece that is not valid UTF-8, or that contains
    /// a scalar outside the alphabet, is kept verbatim.
    static func decodeByteLevel(_ piece: UnsafeBufferPointer<UInt8>, into output: inout [UInt8]) {
        let start = output.count
        var i = 0
        while i < piece.count {
            let (codepoint, length) = UTF8Codec.decode(piece, at: i)
            guard codepoint >= 0, let byte = ByteLevelAlphabet.byte(for: codepoint) else {
                output.removeSubrange(start...)
                output.append(contentsOf: piece)
                return
            }
            output.append(byte)
            i += length
        }
    }
}
