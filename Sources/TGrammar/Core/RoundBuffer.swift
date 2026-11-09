// A growable stack of trivially copyable elements for state that lives within one parser round
// (the processing queue, the pending scanable row, the visited states).
//
// The Earley parser touches these several times per scanned byte. As `Array`s, every write
// paid an out-of-line uniqueness check and every reset a generic range replacement. Here writes
// go straight through a cached pointer, and uniqueness is checked once per round in
// `beginRound()`. Because the contents never outlive a round, a buffer still shared with a copy
// of the parser is replaced by a fresh one rather than copied.

final class RoundBufferStorage<Element: BitwiseCopyable>: @unchecked Sendable {
    // Only ever mutated through a uniquely referenced `RoundBuffer`.
    fileprivate var base: UnsafeMutablePointer<Element>
    fileprivate var capacity: Int

    fileprivate init(capacity: Int) {
        base = .allocate(capacity: capacity)
        self.capacity = capacity
    }

    deinit { base.deallocate() }
}

struct RoundBuffer<Element: BitwiseCopyable>: @unchecked Sendable {
    private var storage: RoundBufferStorage<Element>
    /// `storage.base`, cached so element access never reads the class.
    private var base: UnsafeMutablePointer<Element>
    private var capacity: Int
    private(set) var count = 0

    init(capacity: Int = 64) {
        storage = RoundBufferStorage(capacity: capacity)
        base = storage.base
        self.capacity = capacity
    }

    @inline(__always) var isEmpty: Bool { count == 0 }

    @inline(__always)
    subscript(index: Int) -> Element {
        get {
            assert(index >= 0 && index < count)
            return base[index]
        }
        set {
            assert(index >= 0 && index < count)
            base[index] = newValue
        }
    }

    /// Resizes to exactly `newCount` elements, all `value`. For buffers used as fixed tables.
    mutating func fill(count newCount: Int, with value: Element) {
        if newCount > capacity {
            storage.base.deallocate()
            storage.base = .allocate(capacity: newCount)
            storage.capacity = newCount
            base = storage.base
            capacity = newCount
        }
        base.update(repeating: value, count: newCount)
        count = newCount
    }

    @inline(__always)
    var elements: UnsafeBufferPointer<Element> { UnsafeBufferPointer(start: base, count: count) }

    /// Starts a round: empties the buffer and makes it exclusively owned. Must precede the
    /// first write of every round.
    @inline(__always)
    mutating func beginRound() {
        count = 0
        if !isKnownUniquelyReferenced(&storage) { replaceStorage() }
    }

    /// Whether the storage is shared with a copy of the owner. Buffers that are always copied
    /// together have equal reference counts, so one check can stand for all of them.
    @inline(__always)
    mutating func isShared() -> Bool { !isKnownUniquelyReferenced(&storage) }

    /// Empties the buffer and gives it storage of its own, without a uniqueness check: for
    /// buffers whose sharing was established by ``isShared()`` on a sibling.
    @inline(__always)
    mutating func beginRound(shared: Bool) {
        count = 0
        if shared { replaceStorage() }
    }

    @inline(never)
    private mutating func replaceStorage() {
        storage = RoundBufferStorage(capacity: capacity)
        base = storage.base
    }

    /// Empties the buffer within a round that already began.
    @inline(__always)
    mutating func removeAll() { count = 0 }

    @inline(__always)
    mutating func removeLast(_ n: Int) {
        assert(n <= count)
        count &-= n
    }

    @inline(__always)
    var last: Element {
        assert(count > 0)
        return base[count &- 1]
    }

    @inline(__always)
    mutating func append(_ element: Element) {
        if count == capacity { grow() }
        base[count] = element
        count &+= 1
    }

    /// Drops the elements `shouldRemove` accepts, keeping the others in order.
    mutating func removeAll(where shouldRemove: (Element) -> Bool) {
        var kept = 0
        for index in 0 ..< count where !shouldRemove(base[index]) {
            base[kept] = base[index]
            kept &+= 1
        }
        count = kept
    }

    @inline(never)
    private mutating func grow() {
        resize(to: capacity * 2)
    }

    /// Makes room for `minimumCapacity` elements at once, without doubling past it.
    mutating func reserveCapacity(_ minimumCapacity: Int) {
        if minimumCapacity > capacity { resize(to: minimumCapacity) }
    }

    /// Returns storage beyond `maximumCapacity` elements, so a buffer that once held a
    /// vocabulary-sized list does not keep it for the rest of its owner's life. Only for an
    /// empty buffer.
    mutating func releaseCapacity(above maximumCapacity: Int) {
        assert(count == 0)
        if capacity > maximumCapacity { resize(to: maximumCapacity) }
    }

    private mutating func resize(to newCapacity: Int) {
        let newBase = UnsafeMutablePointer<Element>.allocate(capacity: newCapacity)
        newBase.update(from: base, count: count)
        storage.base.deallocate()
        storage.base = newBase
        storage.capacity = newCapacity
        base = newBase
        capacity = newCapacity
    }
}
