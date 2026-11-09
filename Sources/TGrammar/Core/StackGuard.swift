#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Recursive descent over user input (grammar sources, regexes, JSON, schemas, structural
/// tags) checks the remaining native stack before going one level deeper, so pathological
/// nesting raises a ``GrammarError`` instead of overflowing the stack.
///
/// A fixed depth limit cannot be both permissive and safe: the main thread has 8 MB of stack,
/// while Swift concurrency and secondary threads have 512 KB, and unoptimized builds use far
/// larger frames. Upstream bounds the same recursion with its global maximum recursion depth.
enum StackGuard {
    /// Stack left free for the work below the deepest checked level (the passes that later
    /// walk the parsed structure on the same thread) and for the caller.
    static let reserve = 192 * 1024

    static let message = "Maximum recursion depth exceeded: the input is nested deeper than the thread's stack allows"

    /// Whether at least ``reserve`` bytes of stack remain on the current thread.
    @inline(__always)
    static var hasRoom: Bool {
        #if canImport(Darwin)
        let thread = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let size = UInt(pthread_get_stacksize_np(thread))
        var marker: UInt8 = 0
        let current = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        return current &- (top &- size) > UInt(reserve)
        #else
        return true
        #endif
    }

    @inline(__always)
    static func check() throws(GrammarError) {
        guard hasRoom else { throw .unsupported(message) }
    }
}
