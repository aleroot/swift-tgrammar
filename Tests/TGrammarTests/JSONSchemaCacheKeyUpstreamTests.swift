import Testing
@testable import TGrammar

/// Ports of the acceptance checks in three upstream #985 cache-key tests
/// (`test_json_schema_converter.py`). Their printed-grammar equality assertions
/// check upstream's rule reuse, which keys rules by a filtered schema; here rules are keyed by the
/// whole schema value, so only the accepted language is compared. The other eight #985 tests are
/// covered by `Fixtures/GrammarLanguage.json`.
@Suite("JSON Schema cache keys (upstream)")
struct JSONSchemaCacheKeyUpstreamTests {
    static let info = try! TokenizerInfo(encodedVocab: (0x20 ... 0x7E).map { String(UnicodeScalar($0)!) } + ["</s>"])
    static let compiler = GrammarCompiler(tokenizerInfo: info, cacheEnabled: false)

    private static func accepts(_ schema: String, _ instance: String) throws -> Bool {
        var matcher = GrammarMatcher(try compiler.compile(jsonSchema: schema))
        return matcher.acceptString(instance) && matcher.isCompleted
    }

    /// Upstream `test_schema_cache_key_reuses_parent_with_nested_annotations`.
    @Test(arguments: ["items", "prefixItems"])
    func reusesParentWithNestedAnnotations(_ itemsKey: String) throws {
        for description in ["original", "changed"] {
            func parent(_ description: String) -> String {
                let item = #"{"type":"string","description":"\#(description)"}"#
                let items = itemsKey == "prefixItems" ? "[\(item)]" : item
                return #"{"type":"object","properties":{"values":{"type":"array","\#(itemsKey)":\#(items)}},"required":["values"],"additionalProperties":false}"#
            }
            let schema = ##"{"$defs":{"Parent":\##(parent("original"))},"type":"object","properties":{"seed":{"$ref":"#/$defs/Parent"},"candidate":\##(parent(description))},"required":["seed","candidate"],"additionalProperties":false}"##
            #expect(try Self.accepts(schema, #"{"seed": {"values": ["a"]}, "candidate": {"values": ["b"]}}"#))
        }
    }

    /// Upstream `test_schema_cache_key_reuses_parent_with_ignored_metadata`.
    @Test func reusesParentWithIgnoredMetadata() throws {
        let schema = ##"{"$defs":{"Parent":{"type":"integer","x-meta":{"default":{"const":"a"}}}},"type":"object","properties":{"seed":{"$ref":"#/$defs/Parent"},"candidate":{"type":"integer","x-meta":{"default":{"const":"b"}}}},"required":["seed","candidate"],"additionalProperties":false}"##
        #expect(try Self.accepts(schema, #"{"seed": 1, "candidate": 2}"#))
        #expect(try !Self.accepts(schema, #"{"seed": 1, "candidate": "b"}"#))

        // Parent reuse must not replace the original reference target with "a".
        let targeted = ##"{"$defs":{"Parent":{"type":"integer","x-meta":{"default":{"const":"a"}}}},"type":"object","properties":{"seed":{"$ref":"#/$defs/Parent"},"candidate":{"type":"integer","x-meta":{"default":{"const":"b"}}},"target":{"$ref":"#/properties/candidate/x-meta/default"}},"required":["seed","candidate","target"],"additionalProperties":false}"##
        #expect(try Self.accepts(targeted, #"{"seed": 1, "candidate": 2, "target": "b"}"#))
        #expect(try !Self.accepts(targeted, #"{"seed": 1, "candidate": 2, "target": "a"}"#))
    }

    /// Upstream `test_schema_cache_key_reuses_rules_when_default_type_is_ignored`.
    @Test(arguments: [
        #"{"const":"a"}"#,
        #"{"enum":["a","b"]}"#,
        ##"{"$ref":"#/$defs/Base"}"##,
        #"{"anyOf":[{"const":"a"},{"const":"b"}]}"#,
        #"{"oneOf":[{"const":"a"},{"const":"b"}]}"#,
        #"{"allOf":[{"const":"a"}]}"#,
    ])
    func reusesRulesWhenDefaultTypeIsIgnored(_ constraint: String) throws {
        let schema = ##"{"type":"object","$defs":{"Base":{"const":"a"},"Target":\##(constraint)},"properties":{"seed":{"$ref":"#/$defs/Target"},"candidate":{"type":"object","propertyNames":\##(constraint),"additionalProperties":true}},"required":["seed","candidate"],"additionalProperties":false}"##
        #expect(try Self.accepts(schema, #"{"seed": "a", "candidate": {"a": 1}}"#))
        #expect(try !Self.accepts(schema, #"{"seed": "a", "candidate": {"wrong": 1}}"#))
    }
}
