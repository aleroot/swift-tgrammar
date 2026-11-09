// A stack of variable-length rows stored contiguously (CSR layout). Rows are pushed and popped
// from the end; the last row can grow in place. Used for the parser histories so that rollback
// is a single truncation and iteration streams through one buffer.
//
// The buffers only grow: popping moves the logical end (`elementCount`, `offsetCount`) and later
// pushes overwrite the stale slots. Rollback runs after every token of the vocabulary walk, and
// `Array.removeLast(_:)` would go through a generic range replacement each time.

struct Rows<Element> {
    /// Live elements are `storage[0 ..< elementCount]`; the rest are stale.
    private var storage: [Element] = []
    private var elementCount = 0
    /// Start of each row; `offsets[0 ..< offsetCount]` is live and holds `count + 1` entries.
    private var offsets: [Int32] = [0]
    private var offsetCount = 1

    init() {}

    @inline(__always) var count: Int { offsetCount &- 1 }
    @inline(__always) var isEmpty: Bool { offsetCount == 1 }

    /// The live elements of every row, in order.
    var elements: ArraySlice<Element> { storage[0 ..< elementCount] }

    @inline(__always)
    subscript(row: Int) -> ArraySlice<Element> {
        storage[Int(offsets[row]) ..< Int(offsets[row &+ 1])]
    }

    @inline(__always)
    var last: ArraySlice<Element> { self[count &- 1] }

    /// Element indices of `row`. Iterating these instead of a row slice keeps the buffer
    /// uniquely referenced, so rows can be pushed during the iteration without a copy.
    @inline(__always)
    func indices(ofRow row: Int) -> Range<Int> { Int(offsets[row]) ..< Int(offsets[row &+ 1]) }

    @inline(__always)
    var lastRowIndices: Range<Int> { indices(ofRow: count &- 1) }

    @inline(__always)
    func element(at index: Int) -> Element { storage[index] }

    @inline(__always)
    private mutating func appendElement(_ element: Element) {
        if elementCount < storage.count {
            storage[elementCount] = element
        } else {
            storage.append(element)
        }
        elementCount &+= 1
    }

    @inline(__always)
    private mutating func appendOffset() {
        let offset = Int32(elementCount)
        if offsetCount < offsets.count {
            offsets[offsetCount] = offset
        } else {
            offsets.append(offset)
        }
        offsetCount &+= 1
    }

    mutating func pushRow(_ row: some Sequence<Element>) {
        for element in row { appendElement(element) }
        appendOffset()
    }

    /// Pushes a contiguous row with one buffer access when the stale slots can hold it,
    /// instead of one checked write per element.
    mutating func pushRow(_ row: UnsafeBufferPointer<Element>) {
        let start = elementCount
        if start &+ row.count <= storage.count {
            // Rows hold a few states: an element loop beats a `memmove` call.
            storage.withUnsafeMutableBufferPointer { buffer in
                for index in 0 ..< row.count { buffer[start &+ index] = row[index] }
            }
            elementCount &+= row.count
        } else {
            for element in row { appendElement(element) }
        }
        appendOffset()
    }

    mutating func pushEmptyRow() { appendOffset() }

    mutating func appendToLastRow(_ element: Element) {
        appendElement(element)
        offsets[offsetCount &- 1] = Int32(elementCount)
    }

    mutating func popRows(_ rowCount: Int = 1) {
        precondition(rowCount <= count)
        offsetCount &-= rowCount
        elementCount = Int(offsets[offsetCount &- 1])
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        elementCount = 0
        offsets.removeAll(keepingCapacity: true)
        offsets.append(0)
        offsetCount = 1
    }

    mutating func reserveCapacity(elements elementCapacity: Int, rows rowCapacity: Int) {
        storage.reserveCapacity(elementCapacity)
        offsets.reserveCapacity(rowCapacity &+ 1)
    }
}

extension Rows: Sendable where Element: Sendable {}

/// A stack whose pops only move the logical end, like ``Rows``: the parser pops several
/// positions on every vocabulary rollback, and `Array.removeLast(_:)` goes through a generic
/// range replacement.
struct TruncatingStack<Element> {
    private var storage: [Element] = []
    private(set) var count = 0

    @inline(__always)
    mutating func append(_ element: Element) {
        if count < storage.count { storage[count] = element } else { storage.append(element) }
        count &+= 1
    }

    @inline(__always)
    mutating func removeLast(_ n: Int = 1) {
        precondition(n <= count)
        count &-= n
    }

    @inline(__always)
    var last: Element {
        get { storage[count &- 1] }
        set { storage[count &- 1] = newValue }
    }

    mutating func removeAll() { count = 0 }
}

extension TruncatingStack: Sendable where Element: Sendable {}

extension Rows: Equatable where Element: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.offsets[0 ..< lhs.offsetCount] == rhs.offsets[0 ..< rhs.offsetCount] && lhs.elements == rhs.elements
    }
}

extension Rows: Hashable where Element: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(offsetCount)
        for offset in offsets[0 ..< offsetCount] { hasher.combine(offset) }
        for element in elements { hasher.combine(element) }
    }
}
