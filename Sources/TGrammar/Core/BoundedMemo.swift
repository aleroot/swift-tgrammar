import Synchronization

/// A small thread-safe memo for pure, deterministic computations that recur across
/// compilations (regex automata, for one). When full it starts over rather than tracking
/// recency: entries are cheap to rebuild, and the working set of a process is small. Emptied on
/// memory pressure.
final class BoundedMemo<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private let entries = Mutex<[Key: Value]>([:])
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        _ = MemoryPressureRelief.shared.register { [weak self] in self?.removeAll() }
    }

    func value(for key: Key) -> Value? { entries.withLock { $0[key] } }

    func insert(_ value: Value, for key: Key) {
        entries.withLock { entries in
            if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
            entries[key] = value
        }
    }

    func removeAll() { entries.withLock { $0.removeAll() } }
}
