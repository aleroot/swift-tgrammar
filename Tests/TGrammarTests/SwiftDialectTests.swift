import Testing
@testable import TGrammar

/// Tool-call formats and argument styles beyond XGrammar's registry, taken from the formats
/// mlx-swift-lm parses: Mistral V13, FunctionGemma, LFM2's Python calls and Muse Glimmer's Onyx
/// frames.
@Suite struct SwiftDialectTests {
    static let weather = ToolDefinition(name: "get_weather", parameters: .object(properties: [
        .init("city", .string(), required: true),
        .init("unit", .enumeration(["celsius", "fahrenheit"])),
    ]))
    static let time = ToolDefinition(name: "get_time", parameters: .object(properties: [.init("zone", .string())]))

    static func accepts(_ format: StructuralFormat, _ input: String) throws -> Bool {
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        var matcher = GrammarMatcher(try compiler.compile(structuralFormat: format), terminateWithoutStopToken: true)
        return matcher.acceptString(input) && matcher.isCompleted
    }

    static func accepts(_ model: ToolCallDialect, _ input: String, choice: ToolChoice = .automatic,
                        reasoning: ReasoningMode? = nil, parallelCalls: Bool = true) throws -> Bool {
        try accepts(.toolCalls([weather, time], model: model, choice: choice, reasoning: reasoning, parallelCalls: parallelCalls), input)
    }

    static func acceptsArguments(_ schema: String, _ input: String, options: JSONSchemaOptions = .init(anyWhitespace: true, style: .pythonic)) throws -> Bool {
        let compiler = GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: [String]()))
        var matcher = GrammarMatcher(try compiler.compile(try Grammar(jsonSchema: schema, options: options)), terminateWithoutStopToken: true)
        return matcher.acceptString(input) && matcher.isCompleted
    }

    // MARK: Python keyword arguments

    static let pythonSchema = #"""
    {"type": "object", "properties": {
        "city": {"type": "string"}, "days": {"type": "integer"}, "metric": {"type": "boolean"},
        "tags": {"type": "array", "items": {"type": "string"}},
        "extra": {"type": "object", "properties": {"note": {"type": ["string", "null"]}, "flag": {"enum": [true, null, "x"]}}}
    }, "required": ["city"]}
    """#

    @Test(arguments: [
        (#"city="Tokyo""#, true),
        (#"city="Tokyo", days=3, metric=True"#, true),
        (#"city="Tokyo",days=3"#, true),
        (#"city="Tokyo", tags=["a", "b"], extra={"note": None, "flag": True}"#, true),
        (#"city="Tokyo", extra={"flag": "x"}"#, true),
        (#"city="a\nb\u00e9\"""#, true),
        (#"days=3"#, false),
        (#"city='Tokyo'"#, false),
        (#"city="Tokyo", metric=true"#, false),
        (#"city="Tokyo", extra={"note": null}"#, false),
        (#""city": "Tokyo""#, false),
        (#"city = "Tokyo""#, false),
        (#"city="a\/b""#, false),
        (#"city="\uD83D\uDE00""#, false),
        (#"city="Tokyo", other=1"#, false),
    ])
    func pythonKeywordArguments(_ input: String, _ accepted: Bool) throws {
        #expect(try Self.acceptsArguments(Self.pythonSchema, input) == accepted)
    }

    @Test func pythonUnconstrainedAndEmptyArguments() throws {
        #expect(try Self.acceptsArguments("{}", #"a=1, b_2="x", c=[True, None, {"k": False}]"#))
        #expect(try Self.acceptsArguments("{}", ""))
        #expect(try !Self.acceptsArguments("{}", #"1a=1"#))
        #expect(try Self.acceptsArguments(#"{"type": "object", "properties": {}}"#, ""))
        #expect(try Self.acceptsArguments(#"{"type": "object", "additionalProperties": {"type": "number"}, "properties": {"a": {"type": "string"}}}"#, #"a="x", b=2.5"#))
        #expect(try !Self.acceptsArguments(#"{"type": "object", "additionalProperties": {"type": "number"}, "properties": {"a": {"type": "string"}}}"#, #"a="x", a=2.5"#))
        #expect(try Self.acceptsArguments(#"{"const": {"mode": true, "n": null}}"#, #"mode=True, n=None"#))
    }

    @Test func pythonStringsRespectExclusions() throws {
        let options = JSONSchemaOptions(anyWhitespace: true, style: .pythonic, excludes: [")]"])
        #expect(try Self.acceptsArguments(#"{"type": "object", "properties": {"q": {"type": "string"}}}"#, #"q="a)b]""#, options: options))
        #expect(try !Self.acceptsArguments(#"{"type": "object", "properties": {"q": {"type": "string"}}}"#, #"q="a)]b""#, options: options))
    }

    // MARK: Mistral

    @Test func mistralCallsEndTheResponse() throws {
        let call = #"[TOOL_CALLS]get_weather[ARGS]{"city": "Tokyo"}"#
        #expect(try Self.accepts(.mistral, "Hello there"))
        #expect(try Self.accepts(.mistral, call))
        #expect(try Self.accepts(.mistral, "Let me check." + call))
        #expect(try Self.accepts(.mistral, call + #"[TOOL_CALLS]get_time[ARGS]{"zone": "JST"}"#))
        #expect(try Self.accepts(.mistral, "[THINK]Weather needed.[/THINK]" + call))
        #expect(try !Self.accepts(.mistral, call + " Done."))
        #expect(try !Self.accepts(.mistral, #"[TOOL_CALLS]get_weather[ARGS]{"town": "Tokyo"}"#))
        #expect(try !Self.accepts(.mistral, #"[TOOL_CALLS]unknown[ARGS]{}"#))
        #expect(try !Self.accepts(.mistral, call + call, parallelCalls: false))
        #expect(try !Self.accepts(.mistral, "Hello", choice: .required))
        #expect(try Self.accepts(.mistral, call, choice: .named("get_weather")))
        #expect(try !Self.accepts(.mistral, #"[TOOL_CALLS]get_time[ARGS]{}"#, choice: .named("get_weather")))
        #expect(try !Self.accepts(.mistral, "[THINK]x[/THINK]Hi", reasoning: .disabled))
    }

    // MARK: FunctionGemma

    @Test func functionGemmaEscapesStrings() throws {
        let call = "<start_function_call>call:get_weather{city:<escape>Tokyo, \"JP\"<escape>,unit:<escape>celsius<escape>}<end_function_call>"
        #expect(try Self.accepts(.functionGemma, "Sure."))
        #expect(try Self.accepts(.functionGemma, call))
        #expect(try Self.accepts(.functionGemma, "Checking. " + call + " Anything else?"))
        #expect(try !Self.accepts(.functionGemma, #"<start_function_call>call:get_weather{"city":"Tokyo"}<end_function_call>"#))
        #expect(try !Self.accepts(.functionGemma, "<start_function_call>call:get_weather{city:<|\"|>Tokyo<|\"|>}<end_function_call>"))
        #expect(try !Self.accepts(.functionGemma, "<start_function_call>call:get_weather{city:<escape>a<end_function_call>b<escape>}<end_function_call>"))
    }

    // MARK: LFM2

    @Test func lfm2PythonCallLists() throws {
        let call = #"<|tool_call_start|>[get_weather(city="Tokyo", unit="celsius")]<|tool_call_end|>"#
        #expect(try Self.accepts(.lfm2, "Hi!"))
        #expect(try Self.accepts(.lfm2, call))
        #expect(try Self.accepts(.lfm2, call + "Checking the weather."))
        #expect(try Self.accepts(.lfm2, #"<|tool_call_start|>[get_weather(city="Tokyo"), get_time(zone="JST")]<|tool_call_end|>"#))
        #expect(try Self.accepts(.lfm2, "<think>Need the weather.</think>" + call))
        #expect(try Self.accepts(.lfm2, #"<|tool_call_start|>[get_time()]<|tool_call_end|>"#))
        #expect(try !Self.accepts(.lfm2, #"<|tool_call_start|>[get_weather(city="Tokyo"), get_time()]<|tool_call_end|>"#, parallelCalls: false))
        #expect(try !Self.accepts(.lfm2, #"<|tool_call_start|>[get_weather(unit="celsius")]<|tool_call_end|>"#))
        #expect(try !Self.accepts(.lfm2, #"<|tool_call_start|>[get_weather({"city": "Tokyo"})]<|tool_call_end|>"#))
        #expect(try !Self.accepts(.lfm2, "Hi!", choice: .required))
        #expect(try Self.accepts(.lfm2, #"<|tool_call_start|>[get_time(zone="UTC")]<|tool_call_end|>"#, choice: .named("get_time")))
    }

    // MARK: Onyx (Muse Glimmer)

    static let onyxControls = ["<|start|>", "<|message|>", "<|eom|>", "<|eot|>"]
    /// One character per token plus Onyx's control tokens; `<|eot|>` ends the turn.
    static let onyxInfo: TokenizerInfo = {
        let pieces = ["\t", "\n"] + (0x20 ... 0x7E).map { String(UnicodeScalar($0)!) } + onyxControls
        return try! TokenizerInfo(encodedVocab: pieces, stopTokenIDs: [Int32(pieces.count - 1)])
    }()

    /// Control tokens as single ids, everything else one character per token. `spelled` writes
    /// the control tokens out character by character instead.
    static func onyxTokens(_ text: String, spelled: Bool = false) -> [Int32] {
        var tokens: [Int32] = [], rest = Substring(text)
        while !rest.isEmpty {
            if !spelled, let control = onyxControls.first(where: { rest.hasPrefix($0) }) {
                tokens.append(onyxInfo.tokenID(for: control)!)
                rest = rest.dropFirst(control.count)
            } else {
                tokens.append(onyxInfo.tokenID(for: String(rest.first!))!)
                rest = rest.dropFirst()
            }
        }
        return tokens
    }

    static func onyxAccepts(_ output: String, choice: ToolChoice = .automatic, reasoning: ReasoningMode? = nil,
                            parallelCalls: Bool = true, spelled: Bool = false) throws -> Bool {
        let compiler = GrammarCompiler(tokenizerInfo: onyxInfo)
        let grammar = try compiler.compile(toolCalls: [weather, time], model: .atem, choice: choice, reasoning: reasoning, parallelCalls: parallelCalls)
        var matcher = GrammarMatcher(grammar)
        return onyxTokens(output, spelled: spelled).allSatisfy { matcher.acceptToken($0) } && matcher.isCompleted
    }

    static let onyxCall = #" to=get_weather<|message|><atem:function_calls><atem:invoke name="get_weather"><atem:parameter name="city"> Tokyo, JP </atem:parameter></atem:invoke></atem:function_calls>"#

    @Test func onyxFrames() throws {
        #expect(try Self.onyxAccepts("<|message|>Sunny."))
        #expect(try Self.onyxAccepts(" to=user<|message|>Sunny."))
        #expect(try Self.onyxAccepts(Self.onyxCall))
        #expect(try Self.onyxAccepts(" to=self<|message|>Need weather.<|eom|><|start|>assistant" + Self.onyxCall))
        #expect(try Self.onyxAccepts(Self.onyxCall + #"<|eom|><|start|>assistant to=get_time<|message|><atem:function_calls>"#
                                     + "\n" + #"<atem:invoke name="get_time">"# + "\n" + #"<atem:parameter name="zone">JST</atem:parameter>"# + "\n"
                                     + "</atem:invoke>\n</atem:function_calls>"))
        // The invoke must name the frame's recipient, and a required parameter must be present.
        #expect(try !Self.onyxAccepts(Self.onyxCall.replacingOccurrences(of: #"invoke name="get_weather""#, with: #"invoke name="get_time""#)))
        #expect(try !Self.onyxAccepts(#" to=get_weather<|message|><atem:function_calls><atem:invoke name="get_weather"></atem:invoke></atem:function_calls>"#))
        #expect(try !Self.onyxAccepts(Self.onyxCall + "Done."))
        #expect(try !Self.onyxAccepts(" to=unknown<|message|>x"))
        // Control tokens spelled out character by character would not frame anything.
        #expect(try !Self.onyxAccepts("<|message|>Sunny.", spelled: true))
        #expect(try !Self.onyxAccepts("<|message|>a<|eom|>b"))
        #expect(try !Self.onyxAccepts(Self.onyxCall + "<|eom|><|start|>assistant" + Self.onyxCall, parallelCalls: false))
        #expect(try !Self.onyxAccepts("<|message|>Sunny.", choice: .required))
        #expect(try Self.onyxAccepts(Self.onyxCall, choice: .named("get_weather")))
        #expect(try !Self.onyxAccepts(" to=self<|message|>x<|eom|><|start|>assistant<|message|>y", reasoning: .disabled))
        #expect(try Self.onyxAccepts("Plan.<|eom|><|start|>assistant<|message|>Hi", reasoning: .continuation))
    }

    @Test func onyxNeedsItsControlTokens() {
        #expect(throws: GrammarError.self) {
            try GrammarCompiler(tokenizerInfo: try TokenizerInfo(encodedVocab: ["a"])).compile(toolCalls: [Self.weather], model: .atem)
        }
    }

    @Test(arguments: [ToolCallDialect.mistral, .functionGemma, .lfm2, .atem])
    func defaultReasoningFollowsTheFamily(_ model: ToolCallDialect) {
        #expect(model.defaultReasoning == (model == .functionGemma ? .enabled : .optional))
    }
}
