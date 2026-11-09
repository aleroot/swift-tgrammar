import Foundation
import Testing
@testable import TGrammar

/// Deeply nested input must raise a `GrammarError`, not overflow the native stack, whatever
/// thread converts it. Swift concurrency and secondary threads have 512 KB of stack, so each
/// front end runs on such a thread with input far deeper than any fixed limit.
@Suite("Stack safety")
struct StackSafetyTests {
    private static func nested(_ open: String, _ inner: String, _ close: String, depth: Int = 20_000) -> String {
        String(repeating: open, count: depth) + inner + String(repeating: close, count: depth)
    }

    static let inputs: [(name: String, build: @Sendable () throws -> Void)] = [
        ("EBNF", { _ = try Grammar(ebnf: "root ::= " + nested("(", "\"a\"", ")")) }),
        ("regex", { _ = try Grammar(regex: nested("(", "a", ")")) }),
        ("Lark", { _ = try Grammar(lark: "start: " + nested("(", "\"a\"", ")")) }),
        ("JSON", { _ = try Grammar(jsonSchema: #"{"unused": "# + nested("[", "0", "]") + "}") }),
        ("schema", {
            _ = try Grammar(jsonSchema: nested(#"{"type":"array","items":"#, #"{"type":"integer"}"#, "}", depth: 400))
        }),
        ("structural tag", {
            _ = try Grammar(structuralTagJSON: nested(#"{"type":"optional","content":"#, #"{"type":"const_string","value":"x"}"#, "}", depth: 300))
        }),
        ("structural format", {
            var format = StructuralFormat.literal("x")
            for _ in 0 ..< 300 { format = .optional(format) }
            _ = try Grammar(structuralFormat: format)
        }),
    ]

    @Test(arguments: inputs.indices)
    func deepInputThrowsOnSmallStack(_ index: Int) {
        let input = Self.inputs[index]
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var thrown: (any Error)?
        let thread = Thread {
            do { try input.build() } catch { thrown = error }
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        let message = thrown.map { String(describing: $0) } ?? ""
        #expect(message.contains("nested deeper than"), "\(input.name): \(message)")
    }
}
