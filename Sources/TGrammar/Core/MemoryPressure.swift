// Apple devices reclaim memory from apps instead of paging it out: an iOS app that keeps growing
// under memory pressure is terminated. TGrammar's caches are all rebuildable, so they are dropped
// as soon as the system reports pressure.

import Dispatch
import Synchronization

/// Process-wide registry of cache purgers, run on the system's memory pressure warnings.
final class MemoryPressureRelief: Sendable {
    static let shared = MemoryPressureRelief()

    private let purgers = Mutex<[UInt64: @Sendable () -> Void]>([:])
    private let nextID = Atomic<UInt64>(0)
    #if canImport(Darwin)
    private let source: any DispatchSourceMemoryPressure
    #endif

    private init() {
        #if canImport(Darwin)
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { MemoryPressureRelief.shared.purgeAll() }
        source.activate()
        #endif
    }

    /// Registers `purge`; it runs on every memory pressure event until ``unregister(_:)``.
    func register(_ purge: @escaping @Sendable () -> Void) -> UInt64 {
        let id = nextID.add(1, ordering: .relaxed).newValue
        purgers.withLock { $0[id] = purge }
        return id
    }

    func unregister(_ id: UInt64) {
        _ = purgers.withLock { $0.removeValue(forKey: id) }
    }

    /// Runs every registered purger.
    func purgeAll() {
        let all = purgers.withLock { Array($0.values) }
        for purge in all { purge() }
    }
}
