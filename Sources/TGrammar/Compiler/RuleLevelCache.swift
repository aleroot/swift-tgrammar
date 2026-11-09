// Token masks shared across grammars. Keyed by the canonical hash of a rule's automaton plus
// the canonical state id, so a new grammar whose rule matches one compiled earlier (the string,
// number and whitespace rules of every JSON schema, say) skips the vocabulary replay for that
// state. Sharded, since every compilation thread queries and inserts concurrently.

import Synchronization

struct RuleLevelCacheKey: Hashable, Sendable {
    var fsmHash: UInt64
    var canonicalState: Int32
    var stateCount: Int32
    var edgeCount: Int32
}

final class RuleLevelCache: Sendable {
    static let shardCount = 16

    /// Intrusive doubly linked LRU list stored in arrays; the dictionary maps keys to slots.
    private struct Shard {
        struct Node {
            var key: RuleLevelCacheKey
            var mask: AdaptiveTokenMask
            var bytes: Int
            var previous: Int32 = -1
            var next: Int32 = -1
        }

        var nodes: [Node] = []
        var free: [Int32] = []
        var slots: [RuleLevelCacheKey: Int32] = [:]
        var oldest: Int32 = -1
        var newest: Int32 = -1
        var bytes = 0

        mutating func unlink(_ slot: Int32) {
            let node = nodes[Int(slot)]
            if node.previous >= 0 { nodes[Int(node.previous)].next = node.next } else { oldest = node.next }
            if node.next >= 0 { nodes[Int(node.next)].previous = node.previous } else { newest = node.previous }
        }

        mutating func appendNewest(_ slot: Int32) {
            nodes[Int(slot)].previous = newest
            nodes[Int(slot)].next = -1
            if newest >= 0 { nodes[Int(newest)].next = slot } else { oldest = slot }
            newest = slot
        }

        mutating func removeOldest() {
            let slot = oldest
            unlink(slot)
            let node = nodes[Int(slot)]
            slots.removeValue(forKey: node.key)
            bytes -= node.bytes
            // Release the mask's storage while the slot waits on the free list.
            nodes[Int(slot)].mask = AdaptiveTokenMask(vocabSize: 0, sortedTokenIDs: [], accepted: [], uncertain: [])
            free.append(slot)
        }

        mutating func removeAll() {
            nodes.removeAll()
            free.removeAll()
            slots.removeAll()
            oldest = -1
            newest = -1
            bytes = 0
        }
    }

    /// `Mutex` is non-copyable, so each shard's lock lives in its own box.
    private final class ShardBox: Sendable {
        let lock = Mutex(Shard())
    }

    private let shards: [ShardBox]
    /// `nil` is unlimited.
    let maxBytes: Int?
    private let shardMaxBytes: Int?

    init(maxBytes: Int?) {
        self.maxBytes = maxBytes
        shardMaxBytes = maxBytes.map { $0 / Self.shardCount }
        shards = (0 ..< Self.shardCount).map { _ in ShardBox() }
    }

    @inline(__always)
    private func shard(for key: RuleLevelCacheKey) -> ShardBox {
        var seed: UInt64 = 0
        FSMHash.combine(&seed, key.fsmHash)
        FSMHash.combine(&seed, FSMHash.word(key.canonicalState))
        return shards[Int(seed % UInt64(Self.shardCount))]
    }

    /// The cached mask, marked most recently used.
    func mask(for key: RuleLevelCacheKey) -> AdaptiveTokenMask? {
        shard(for: key).lock.withLock { shard in
            guard let slot = shard.slots[key] else { return nil }
            shard.unlink(slot)
            shard.appendNewest(slot)
            return shard.nodes[Int(slot)].mask
        }
    }

    /// Stores `mask` unless the key is present or the mask exceeds the shard budget. Evicts the
    /// least recently used entries to make room.
    @discardableResult
    func insert(_ mask: AdaptiveTokenMask, for key: RuleLevelCacheKey) -> Bool {
        var mask = mask
        mask.compact()
        let bytes = mask.memorySize
        if let shardMaxBytes, bytes > shardMaxBytes { return false }
        return shard(for: key).lock.withLock { shard in
            if shard.slots[key] != nil { return false }
            if let shardMaxBytes {
                while shard.bytes > shardMaxBytes - bytes, shard.oldest >= 0 { shard.removeOldest() }
            }
            let slot: Int32
            if let reused = shard.free.popLast() {
                slot = reused
                shard.nodes[Int(slot)] = Shard.Node(key: key, mask: mask, bytes: bytes)
            } else {
                slot = Int32(shard.nodes.count)
                shard.nodes.append(Shard.Node(key: key, mask: mask, bytes: bytes))
            }
            shard.appendNewest(slot)
            shard.slots[key] = slot
            shard.bytes += bytes
            return true
        }
    }

    func removeAll() {
        for shard in shards { shard.lock.withLock { $0.removeAll() } }
    }

    var totalBytes: Int {
        shards.reduce(0) { $0 + $1.lock.withLock { $0.bytes } }
    }
}

extension AdaptiveTokenMask {
    /// Heap footprint (reserved capacity, not just the elements in use), used by the cache budgets.
    var memorySize: Int {
        var total = MemoryLayout<AdaptiveTokenMask>.stride
        total += acceptedIndices.storageBytes + rejectedIndices.storageBytes + uncertainIndices.storageBytes
        total += acceptedBitset.words.storageBytes
        total += repeatInteriorBitsets.storageBytes
        for bitset in repeatInteriorBitsets { total += bitset.words.storageBytes }
        total += repeatExitTokens.storageBytes + repeatInteriorTokens.storageBytes + repeatInteriorCharCounts.storageBytes
        return total
    }
}
