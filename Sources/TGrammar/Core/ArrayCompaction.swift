// Long-lived results must not keep the spare capacity of the scratch buffers they were built in.
// Assigning a scratch array to a stored property shares its buffer, so a mask holding 40 indices
// could pin a buffer sized for the whole vocabulary (600 KB with 151k tokens).

extension Array {
    /// The array without significant spare capacity: `self` when its slack is within allocator
    /// rounding (64 bytes or an eighth), an exact-size copy otherwise.
    @inline(__always)
    func compacted() -> [Element] {
        let spare = (capacity - count) * MemoryLayout<Element>.stride
        if spare <= Swift.max(64, count * MemoryLayout<Element>.stride / 8) { return self }
        if isEmpty { return [] }
        return Array(unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = withUnsafeBufferPointer { buffer.initialize(fromContentsOf: $0) }
        }
    }

    /// Bytes of heap storage this array's buffer reserves for its elements.
    @inline(__always)
    var storageBytes: Int { capacity * MemoryLayout<Element>.stride }
}
