/// XGrammar's supported format languages. These are generation constraints, including upstream
/// approximations (for example, dates constrain numeric fields rather than the Gregorian calendar).
enum JSONSchemaFormats {
    private static let json = make(raw: false)
    private static let raw = make(raw: true)
    static func pattern(for format: String, raw: Bool) -> String? { (raw ? Self.raw : json)[format] }

    private static func make(raw: Bool) -> [String: String] {
        var m: [String: String] = [:]
        let atext = #"[\w!#$%&'*+/=?^`{|}~-]"#
        let dotString = "(" + atext + "+(\\." + atext + "+)*)"
        let quote = raw ? "\"" : #"\\\""#
        let quotedPair = raw ? #"\\[\x20-\x7E]"# : #"\\\\([\x20-\x21\x23-\x5B\x5D-\x7E]|\\\"|\\\\)"#
        let quotedString = quote + "(" + quotedPair + #"|[\x20\x21\x23-\x5B\x5D-\x7E])*"# + quote
        let domain = #"([A-Za-z0-9]([\-A-Za-z0-9]*[A-Za-z0-9])?)((\.[A-Za-z0-9][\-A-Za-z0-9]*[A-Za-z0-9])*)"#
        m["email"] = "^(" + dotString + "|" + quotedString + ")@" + domain + "$"
        m["date"] = #"^(\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[1-2]\d|3[01]))$"#
        m["time"] = #"^([01]\d|2[0-3]):[0-5]\d:([0-5]\d|60)(\.\d+)?(Z|[+-]([01]\d|2[0-3]):[0-5]\d)$"#
        m["date-time"] = #"^(\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[1-2]\d|3[01]))T([01]\d|2[0-3]):[0-5]\d:([0-5]\d|60)(\.\d+)?(Z|[+-]([01]\d|2[0-3]):[0-5]\d)$"#
        m["duration"] = #"^P((\d+D|\d+M(\d+D)?|\d+Y(\d+M(\d+D)?)?)(T(\d+S|\d+M(\d+S)?|\d+H(\d+M(\d+S)?)?))?|T(\d+S|\d+M(\d+S)?|\d+H(\d+M(\d+S)?)?)|\d+W)$"#
        let decbyte = #"(25[0-5]|2[0-4]\d|[0-1]?\d?\d)"#
        m["ipv4"] = "^(" + decbyte + "\\.){3}" + decbyte + "$"
        let hex = "[0-9a-fA-F]{1,4}"
        let v4 = #"((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])"#
        m["ipv6"] = "(" + [
            "(" + hex + ":){7,7}" + hex, "(" + hex + ":){1,7}:", "(" + hex + ":){1,6}:" + hex,
            "(" + hex + ":){1,5}(:" + hex + "){1,2}", "(" + hex + ":){1,4}(:" + hex + "){1,3}",
            "(" + hex + ":){1,3}(:" + hex + "){1,4}", "(" + hex + ":){1,2}(:" + hex + "){1,5}",
            hex + ":((:" + hex + "){1,6})", ":((:" + hex + "){1,7}|:)",
            "::(ffff(:0{1,4}){0,1}:){0,1}" + v4, "(" + hex + ":){1,4}:" + v4,
        ].joined(separator: "|") + ")"
        m["hostname"] = #"^([a-z0-9]([a-z0-9-]*[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$"#
        m["uuid"] = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
        let scheme = #"[a-zA-Z][a-zA-Z+\.-]*"#
        let pchar = #"([\w\.~!$&'()*+,;=:@-]|%[0-9A-Fa-f][0-9A-Fa-f])"#
        let queryFragment = #"([\w\.~!$&'()*+,;=:@/\?-]|%[0-9A-Fa-f][0-9A-Fa-f])*"#
        let query = "(\\?" + queryFragment + ")?", fragment = "(#" + queryFragment + ")?"
        let pathAbempty = "(/" + pchar + "*)*"
        let pathRootless = "/?(" + pchar + "+(/" + pchar + "*)*)?"
        let userinfo = #"([\w\.~!$&'()*+,;=:-]|%[0-9A-Fa-f][0-9A-Fa-f])*"#
        let host = #"([\w\.~!$&'()*+,;=-]|%[0-9A-Fa-f][0-9A-Fa-f])*"#
        let authority = "(" + userinfo + "@)?" + host + "(:\\d*)?"
        m["uri"] = "^" + scheme + ":(//" + authority + pathAbempty + "|" + pathRootless + ")" + query + fragment + "$"
        let pathAbsolute = "/(" + pchar + "+(/" + pchar + "*)*)?"
        let segment = #"([\w\.~!$&'()*+,;=@-]|%[0-9A-Fa-f][0-9A-Fa-f])+"#
        let pathNoScheme = segment + "(/" + pchar + "*)*"
        m["uri-reference"] = "^(//" + authority + pathAbempty + "|" + pathAbsolute + "|" + pathNoScheme + ")?" + query + fragment + "$"
        let literals = #"([\x21\x23-\x24\x26\x28-\x3B\x3D\x3F-\x5B\x5D\x5F\x61-\x7A\x7E]|%[0-9A-Fa-f][0-9A-Fa-f])"#
        let op = #"[+#\./;\?&=,!@|]"#, varchar = #"(\w|%[0-9A-Fa-f][0-9A-Fa-f])"#
        let varname = varchar + "(\\.?" + varchar + ")*"
        let varspec = varname + "(:[1-9]\\d?\\d?\\d?|\\*)?"
        let expression = "\\{(" + op + ")?" + varspec + "(," + varspec + ")*\\}"
        m["uri-template"] = "^(" + literals + "|" + expression + ")*$"
        let pointer = raw ? #"([\x00-\x2E]|[\x30-\x7D]|[\x7F-\U0010FFFF]|~[01])"#
            : #"([\x20-\x21\x23-\x2E]|[\x30-\x5B\x5D-\x7D]|[\x7F-\U0010FFFF]|\\[\"\\/bfnrt]|\\u00[01][0-9A-Fa-f]|~[01])"#
        m["json-pointer"] = "^(/" + pointer + "*)*$"
        m["relative-json-pointer"] = "^(0|[1-9][0-9]*)(#|(/" + pointer + "*)*)$"
        return m
    }
}
