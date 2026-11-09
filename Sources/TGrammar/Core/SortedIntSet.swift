// Set algebra over sorted, deduplicated `Int32` arrays (token indices). All operations are
// linear and allocate at most one buffer.

enum SortedIntSet {
    /// `lhs ∪ rhs`, both sorted.
    static func formUnion(_ lhs: inout [Int32], _ rhs: [Int32]) {
        if rhs.isEmpty { return }
        if lhs.isEmpty {
            lhs = rhs
            return
        }
        var result: [Int32] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var i = 0, j = 0
        while i < lhs.count, j < rhs.count {
            let a = lhs[i], b = rhs[j]
            if a < b {
                result.append(a)
                i += 1
            } else if a > b {
                result.append(b)
                j += 1
            } else {
                result.append(a)
                i += 1
                j += 1
            }
        }
        if i < lhs.count { result.append(contentsOf: lhs[i...]) }
        if j < rhs.count { result.append(contentsOf: rhs[j...]) }
        lhs = result
    }

    /// `lhs ∩ rhs`, both sorted. `[-1]` as `lhs` means the universal set (the result is `rhs`).
    static func formIntersection(_ lhs: inout [Int32], _ rhs: [Int32]) {
        if lhs.count == 1, lhs[0] == -1 {
            lhs = rhs
            return
        }
        var write = 0
        var i = 0, j = 0
        while i < lhs.count, j < rhs.count {
            let a = lhs[i], b = rhs[j]
            if a < b {
                i += 1
            } else if a > b {
                j += 1
            } else {
                lhs[write] = a
                write += 1
                i += 1
                j += 1
            }
        }
        lhs.removeLast(lhs.count - write)
    }

    /// `lhs \ rhs`, both sorted.
    static func subtract(_ lhs: inout [Int32], _ rhs: [Int32]) {
        if rhs.isEmpty || lhs.isEmpty { return }
        var write = 0
        var i = 0, j = 0
        while i < lhs.count, j < rhs.count {
            let a = lhs[i], b = rhs[j]
            if a < b {
                lhs[write] = a
                write += 1
                i += 1
            } else if a > b {
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        while i < lhs.count {
            lhs[write] = lhs[i]
            write += 1
            i += 1
        }
        lhs.removeLast(lhs.count - write)
    }

    /// `[0, n) \ excluded`, with `excluded` sorted.
    static func complement(count n: Int32, excluding excluded: [Int32]) -> [Int32] {
        var result: [Int32] = []
        result.reserveCapacity(Int(n) - excluded.count)
        var j = 0
        for value in 0 ..< n {
            if j < excluded.count, excluded[j] == value {
                j += 1
            } else {
                result.append(value)
            }
        }
        return result
    }

    /// `sort` + dedupe.
    /// Position of `value` in the sorted `values`, or `nil`.
    static func index(of value: Int32, in values: [Int32]) -> Int? {
        var low = 0, high = values.count
        while low < high {
            let mid = (low + high) >> 1
            if values[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low < values.count && values[low] == value ? low : nil
    }

    static func normalize(_ values: inout [Int32]) {
        values.sort()
        values.removeDuplicatesSorted()
    }
}
