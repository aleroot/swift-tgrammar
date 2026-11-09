// Packed, immutable-after-construction table of byte strings. All strings are stored back to back
// in one buffer with an offsets table, so a vocabulary of 150k tokens costs two allocations instead
// of 150k, and iterating it in order touches memory sequentially — which is exactly what the token
// mask computation does for every grammar state.

/// A dense collection of byte strings stored contiguously.
///
/// Elements are exposed as `ArraySlice<UInt8>` views into the shared storage: no copy is made on
/// access. The table is a value type with copy-on-write storage and is safe to share across
/// concurrency domains once built.
public struct ByteStringTable: Sendable {
    @usableFromInline var bytes: [UInt8]
    /// `count + 1` entries; element `i` occupies `bytes[offsets[i] ..< offsets[i + 1]]`.
    @usableFromInline var offsets: [UInt32]

    /// Creates an empty table.
    public init() {
        bytes = []
        offsets = [0]
    }

    /// Creates an empty table with room for `elementCount` strings totalling `byteCount` bytes.
    public init(capacity elementCount: Int, byteCapacity byteCount: Int) {
        bytes = []
        bytes.reserveCapacity(byteCount)
        offsets = []
        offsets.reserveCapacity(elementCount + 1)
        offsets.append(0)
    }

    /// Creates a table holding the UTF-8 bytes of each string, in order.
    public init(_ strings: [String]) {
        var byteCount = 0
        for string in strings { byteCount += string.utf8.count }
        self.init(capacity: strings.count, byteCapacity: byteCount)
        for string in strings { append(string.utf8) }
    }

    /// Creates a table holding each byte sequence, in order.
    public init<Element: Collection<UInt8>>(_ elements: [Element]) {
        var byteCount = 0
        for element in elements { byteCount += element.count }
        self.init(capacity: elements.count, byteCapacity: byteCount)
        for element in elements { append(element) }
    }

    /// Appends one byte string.
    @inlinable
    public mutating func append(_ element: some Sequence<UInt8>) {
        bytes.append(contentsOf: element)
        offsets.append(UInt32(truncatingIfNeeded: bytes.count))
    }

    /// Appends one byte string written directly into the storage by `body`, avoiding an
    /// intermediate buffer. `body` must only append to the array it is given.
    @inlinable
    public mutating func append(building body: (inout [UInt8]) throws -> Void) rethrows {
        try body(&bytes)
        offsets.append(UInt32(truncatingIfNeeded: bytes.count))
    }

    /// Releases spare capacity left by appends, once the table is complete.
    public mutating func compact() {
        bytes = bytes.compacted()
        offsets = offsets.compacted()
    }

    /// Total number of bytes stored across all elements.
    @inlinable
    public var byteCount: Int { bytes.count }

    /// Length of the longest common prefix of elements `lhs` and `rhs`.
    @inlinable
    public func commonPrefixLength(_ lhs: Int, _ rhs: Int) -> Int {
        let lstart = Int(offsets[lhs]), llen = Int(offsets[lhs + 1]) - lstart
        let rstart = Int(offsets[rhs]), rlen = Int(offsets[rhs + 1]) - rstart
        let common = Swift.min(llen, rlen)
        return bytes.withUnsafeBufferPointer { buffer in
            var i = 0
            while i < common, buffer[lstart + i] == buffer[rstart + i] { i += 1 }
            return i
        }
    }

    /// Calls `body` with a raw view of element `index`.
    @inlinable
    public func withUnsafeBytes<R>(
        of index: Int, _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        let start = Int(offsets[index]), end = Int(offsets[index + 1])
        return try bytes.withUnsafeBufferPointer { buffer in
            try body(UnsafeBufferPointer(rebasing: buffer[start ..< end]))
        }
    }

    /// Calls `body` with raw views of the whole storage and the offsets table, for tight loops.
    @inlinable
    public func withUnsafeStorage<R>(
        _ body: (_ bytes: UnsafeBufferPointer<UInt8>, _ offsets: UnsafeBufferPointer<UInt32>) throws -> R
    ) rethrows -> R {
        try bytes.withUnsafeBufferPointer { bytes in
            try offsets.withUnsafeBufferPointer { offsets in
                try body(bytes, offsets)
            }
        }
    }
}

extension ByteStringTable: RandomAccessCollection {
    public typealias Element = ArraySlice<UInt8>
    public typealias Index = Int

    @inlinable public var startIndex: Int { 0 }
    @inlinable public var endIndex: Int { offsets.count - 1 }

    @inlinable
    public subscript(index: Int) -> ArraySlice<UInt8> {
        bytes[Int(offsets[index]) ..< Int(offsets[index + 1])]
    }

    /// Byte length of element `index`, without materializing a view.
    @inlinable
    public func length(at index: Int) -> Int {
        Int(offsets[index + 1] - offsets[index])
    }
}

extension ByteStringTable: Equatable {
    public static func == (lhs: ByteStringTable, rhs: ByteStringTable) -> Bool {
        lhs.offsets == rhs.offsets && lhs.bytes == rhs.bytes
    }
}

extension ByteStringTable: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(offsets)
        hasher.combine(bytes)
    }
}

extension ByteStringTable: CustomDebugStringConvertible {
    public var debugDescription: String {
        "ByteStringTable(\(count) strings, \(byteCount) bytes)"
    }
}
