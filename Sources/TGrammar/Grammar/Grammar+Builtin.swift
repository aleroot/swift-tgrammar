// Built-in grammars.

extension Grammar {
    /// The EBNF source of ``builtinJSON``: JSON tuned for matcher speed (lookahead assertions on
    /// every string rule, explicit whitespace handling).
    public static let builtinJSONSource = #"""
    root ::= (
        "{" [ \n\r\t]* members_and_embrace |
        "[" [ \n\r\t]* elements_or_embrace
    )
    value_non_str ::= (
        "{" [ \n\r\t]* members_and_embrace |
        "[" [ \n\r\t]* elements_or_embrace |
        "0" fraction exponent |
        [1-9] [0-9]* fraction exponent |
        "-" [0-9] fraction exponent |
        "-" [1-9] [0-9]* fraction exponent |
        "true" |
        "false" |
        "null"
    ) (= [ \n\r\t]* member_suffix_suffix)
    members_and_embrace ::= ("\"" characters_and_colon [ \n\r\t]* members_suffix | "}") (= [ \n\r\t,}\]])
    members_suffix ::= (
        value_non_str [ \n\r\t]* member_suffix_suffix |
        "\"" characters_and_embrace |
        "\"" characters_and_comma [ \n\r\t]* "\"" characters_and_colon [ \n\r\t]* members_suffix
    ) (= [ \n\r\t,}\]])
    member_suffix_suffix ::= (
        "}" |
        "," [ \n\r\t]* "\"" characters_and_colon [ \n\r\t]* members_suffix
    ) (= [ \n\r\t,}\]])
    elements_or_embrace ::= (
        "{" [ \n\r\t]* members_and_embrace elements_rest [ \n\r\t]* "]" |
        "[" [ \n\r\t]* elements_or_embrace elements_rest [ \n\r\t]* "]" |
        "\"" characters_item elements_rest [ \n\r\t]* "]" |
        "0" fraction exponent elements_rest [ \n\r\t]* "]" |
        [1-9] [0-9]* fraction exponent elements_rest [ \n\r\t]* "]" |
        "-" "0" fraction exponent elements_rest [ \n\r\t]* "]" |
        "-" [1-9] [0-9]* fraction exponent elements_rest [ \n\r\t]* "]" |
        "true" elements_rest [ \n\r\t]* "]" |
        "false" elements_rest [ \n\r\t]* "]" |
        "null" elements_rest [ \n\r\t]* "]" |
        "]"
    )
    elements ::= (
        "{" [ \n\r\t]* members_and_embrace elements_rest |
        "[" [ \n\r\t]* elements_or_embrace elements_rest |
        "\"" characters_item elements_rest |
        "0" fraction exponent elements_rest |
        [1-9] [0-9]* fraction exponent elements_rest |
        "-" [0-9] fraction exponent elements_rest |
        "-" [1-9] [0-9]* fraction exponent elements_rest |
        "true" elements_rest |
        "false" elements_rest |
        "null" elements_rest
    )
    elements_rest ::= (
        "" |
        [ \n\r\t]* "," [ \n\r\t]* elements
    )
    characters_and_colon ::= (
        "\"" [ \n\r\t]* ":" |
        [^"\\\x00-\x1F] characters_and_colon |
        "\\" escape characters_and_colon
    ) (=[ \n\r\t]* [\"{[0-9tfn-])
    characters_and_comma ::= (
        "\"" [ \n\r\t]* "," |
        [^"\\\x00-\x1F] characters_and_comma |
        "\\" escape characters_and_comma
    ) (=[ \n\r\t]* "\"")
    characters_and_embrace ::= (
        "\"" [ \n\r\t]* "}" |
        [^"\\\x00-\x1F] characters_and_embrace |
        "\\" escape characters_and_embrace
    ) (=[ \n\r\t]* [},])
    characters_item ::= (
        "\"" |
        [^"\\\x00-\x1F] characters_item |
        "\\" escape characters_item
    ) (= [ \n\r\t]* [,\]])
    escape ::= ["\\/bfnrt] | "u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]
    fraction ::= "" | "." [0-9] [0-9]*
    exponent ::= "" |  "e" sign [0-9] [0-9]* | "E" sign [0-9] [0-9]*
    sign ::= "" | "+" | "-"

    """#

    /// A grammar accepting any JSON object or array.
    public static let builtinJSON: Grammar = {
        do {
            return try Grammar(ebnf: builtinJSONSource)
        } catch {
            preconditionFailure("The built-in JSON grammar failed to parse: \(error)")
        }
    }()
}
