// Errors raised while constructing or using grammars.

/// An error produced while parsing, converting, compiling or matching a grammar.
public enum GrammarError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The EBNF lexer rejected the input at the given position.
    case lexer(message: String, line: Int, column: Int)
    /// The EBNF parser rejected the input at the given position.
    case parser(message: String, line: Int, column: Int)
    /// The Lark front end rejected the source at the given position.
    case lark(message: String, line: Int, column: Int)
    /// The grammar is structurally invalid (e.g. a missing root rule).
    case invalidGrammar(String)
    /// A JSON Schema, regex or structural tag could not be converted.
    case conversion(String)
    /// The construct is valid but not supported by this engine.
    case unsupported(String)
    /// The grammar could not be compiled (e.g. an automaton exceeded its size limit).
    case compilation(String)

    public var description: String {
        switch self {
        case let .lexer(message, line, column):
            "EBNF lexer error at line \(line), column \(column): \(message)"
        case let .parser(message, line, column):
            "EBNF parser error at line \(line), column \(column): \(message)"
        case let .lark(message, line, column):
            "Lark error at line \(line), column \(column): \(message)"
        case let .invalidGrammar(message), let .conversion(message), let .unsupported(message), let .compilation(message):
            message
        }
    }

    /// The human-readable message without the position prefix.
    public var message: String {
        switch self {
        case let .lexer(message, _, _), let .parser(message, _, _), let .lark(message, _, _): message
        case let .invalidGrammar(message), let .conversion(message), let .unsupported(message), let .compilation(message): message
        }
    }
}
