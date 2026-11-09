// Token-level control markers, ported from XGrammar's `_bind_marker_tokens` (upstream #940).
// Built-in tool-call formats spell markers such as `<tool_call>` as text, which the grammar then
// also accepts when the model assembles them from ordinary sub-tokens. A parser that recognises
// markers by token id finds no call in that output, so binding the markers to their dedicated
// tokens closes the gap.

extension StructuralFormat {
    /// Matches the given marker strings as their dedicated tokens instead of as text.
    ///
    /// Markers in triggers, tag begins/ends and literals become token formats; the surrounding
    /// text is kept, so the accepted text does not change. Markers inside schema-driven content
    /// (such as GLM's `<arg_key>`) stay text. Free text under a token end becomes
    /// ``anyTokens(excluding:maxTokens:)`` (its excludes must be markers), and triggered free text
    /// whose triggers start with a marker becomes token-triggered, keeping only marker excludes.
    /// Free text may therefore contain a marker spelled from sub-tokens: use this only with
    /// parsers that recognise markers by token id, and compile against a vocabulary in which
    /// every marker is a single token.
    ///
    /// Markers under ``repeated(_:minimum:maximum:)`` stay text. A token end over a repetition or
    /// a dispatch, or over string-triggered tags, and a tag with several ends one of which ends
    /// in a marker, throw ``GrammarError/conversion(_:)``.
    public func bindingMarkerTokens(_ markers: [String]) throws(GrammarError) -> StructuralFormat {
        let unique = Set(markers.filter { !$0.isEmpty })
        if unique.isEmpty { return self }
        return try MarkerBinder(markers: unique).bind(self)
    }
}

/// Upstream's `_MarkerBinder`: rewrites one structural format bottom-up.
private struct MarkerBinder {
    /// Longest first, so a marker that extends another marker wins.
    let markers: [String]
    let markerSet: Set<String>

    init(markers: Set<String>) {
        self.markers = markers.sorted { $0.utf8.count != $1.utf8.count ? $0.utf8.count > $1.utf8.count : $0 < $1 }
        markerSet = markers
    }

    func bind(_ format: StructuralFormat) throws(GrammarError) -> StructuralFormat {
        switch format {
        case .literal(let text): return bindLiteral(text)
        case .tag(let tag): return .tag(try bindTag(tag))
        case .triggeredTags(let triggers, let tags, let atLeastOne, let stopAfterFirst, let excluding):
            return try bindTriggeredTags(triggers: triggers, tags: tags, atLeastOne: atLeastOne, stopAfterFirst: stopAfterFirst, excluding: excluding)
        case .tagsWithSeparator(let tags, let separator, let atLeastOne, let stopAfterFirst):
            return .tagsWithSeparator(try tags.map { tag throws(GrammarError) in try bindTag(tag) }, separator: separator,
                                      atLeastOne: atLeastOne, stopAfterFirst: stopAfterFirst)
        case .sequence(let elements): return .sequence(try elements.map { element throws(GrammarError) in try bind(element) })
        case .choice(let elements): return .choice(try elements.map { element throws(GrammarError) in try bind(element) })
        case .optional(let content): return .optional(try bind(content))
        case .oneOrMore(let content): return .oneOrMore(try bind(content))
        case .zeroOrMore(let content): return .zeroOrMore(try bind(content))
        // Swift-only wrappers are transparent.
        case .captured(let name, let content): return .captured(name, try bind(content))
        case .temperature(let value, let content): return .temperature(value, try bind(content))
        // Repetitions are left untouched (upstream does not resolve token formats beneath them),
        // and so is everything without text delimiters.
        default: return format
        }
    }

    private func leadingMarker(_ text: String) -> String? { markers.first { text.hasPrefix($0) } }
    private func trailingMarker(_ text: String) -> String? { markers.first { text.hasSuffix($0) } }

    /// Splits a literal into text and marker tokens, earliest marker first.
    private func split(_ text: String) -> [StructuralFormat] {
        var parts: [StructuralFormat] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            var best: (range: Range<Substring.Index>, marker: String)? = nil
            for marker in markers {
                if let range = rest.firstRange(of: marker), best.map({ range.lowerBound < $0.range.lowerBound }) ?? true {
                    best = (range, marker)
                }
            }
            guard let best else {
                parts.append(.literal(String(rest)))
                break
            }
            if best.range.lowerBound > rest.startIndex { parts.append(.literal(String(rest[..<best.range.lowerBound]))) }
            parts.append(.token(.piece(best.marker)))
            rest = rest[best.range.upperBound...]
        }
        return parts
    }

    private func bindLiteral(_ text: String) -> StructuralFormat {
        let parts = split(text)
        if parts.isEmpty { return .literal(text) }
        if parts.count == 1 { return parts[0] }
        return .sequence(parts)
    }

    /// Moves a leading begin marker and a trailing end marker onto tokens; the rest of the begin
    /// and end text is folded into the content, so the accepted text stays the same.
    private func bindTag(_ tag: StructuralTag, beginMarker: String? = nil, keepBegin: Bool = false) throws(GrammarError) -> StructuralTag {
        var begin = tag.begin
        var ends = tag.ends
        var lead: [StructuralFormat] = []
        var tail: [StructuralFormat] = []
        if case .text(let text) = tag.begin, !keepBegin, let marker = beginMarker ?? leadingMarker(text), text.hasPrefix(marker) {
            lead = split(String(text.dropFirst(marker.count)))
            begin = .token(.piece(marker))
        }
        var endMarker: String? = nil
        if ends.count > 1 {
            let bound = ends.compactMap { end -> String? in
                guard case .text(let text) = end, trailingMarker(text) != nil else { return nil }
                return text
            }
            if !bound.isEmpty {
                throw .conversion("Token markers cannot bind a tag whose `end` is a list of alternatives when one of them ends with a marker (got \(bound)); use a single end string or leave that tag unbound")
            }
        } else if ends.count == 1, case .text(let text) = ends[0], let marker = trailingMarker(text) {
            endMarker = marker
            tail = split(String(text.dropLast(marker.count)))
            ends = [.token(.piece(marker))]
        }
        var content = try bind(tag.content)
        // String-level free text does not see a token end; make it token-level so the end token
        // stops it.
        if endMarker != nil { content = try tokenLevel(content) }
        if !lead.isEmpty || !tail.isEmpty { content = .sequence(lead + [content] + tail) }
        return StructuralTag(begin: begin, content: content, ends: ends)
    }

    /// Dispatches on the marker token when every trigger and every tag begin starts with it.
    private func bindTriggeredTags(triggers: [String], tags: [StructuralTag], atLeastOne: Bool, stopAfterFirst: Bool,
                                   excluding: [String]) throws(GrammarError) -> StructuralFormat {
        let marker = markers.first { marker in
            triggers.allSatisfy { $0.hasPrefix(marker) } && tags.allSatisfy { tag in
                if case .text(let begin) = tag.begin { begin.hasPrefix(marker) } else { false }
            }
        }
        guard let marker else {
            // The trigger is ordinary text: keep string dispatch, still binding the markers
            // inside the tags.
            return .triggeredTags(triggers: triggers, tags: try tags.map { tag throws(GrammarError) in try bindTag(tag, keepBegin: true) },
                                  atLeastOne: atLeastOne, stopAfterFirst: stopAfterFirst, excluding: excluding)
        }
        // Only markers are known to be single tokens; other string excludes cannot be expressed
        // at the token level and are dropped.
        return .tokenTriggeredTags(triggers: [.piece(marker)],
                                   tags: try tags.map { tag throws(GrammarError) in try bindTag(tag, beginMarker: marker) },
                                   atLeastOne: atLeastOne, stopAfterFirst: stopAfterFirst,
                                   excluding: excluding.filter(markerSet.contains).map(GrammarToken.piece))
    }

    /// Turns the free text under a token end into token-level formats.
    private func tokenLevel(_ format: StructuralFormat) throws(GrammarError) -> StructuralFormat {
        switch format {
        case .anyText(let excluding, let maxTokens, let maxCharacters):
            guard maxCharacters == nil, excluding.allSatisfy(markerSet.contains) else {
                throw .conversion("Token markers need the free text under a token end to be token-level: its excludes must be markers and max_chars unset (got \(format))")
            }
            return .anyTokens(excluding: excluding.map(GrammarToken.piece), maxTokens: maxTokens)
        case .triggeredTags:
            throw .conversion("Token markers cannot keep string-triggered tags under a token end; their triggers must start with a marker")
        case .sequence(let elements): return .sequence(try elements.map { element throws(GrammarError) in try tokenLevel(element) })
        case .choice(let elements): return .choice(try elements.map { element throws(GrammarError) in try tokenLevel(element) })
        case .optional(let content): return .optional(try tokenLevel(content))
        case .oneOrMore(let content): return .oneOrMore(try tokenLevel(content))
        case .zeroOrMore(let content): return .zeroOrMore(try tokenLevel(content))
        case .captured(let name, let content): return .captured(name, try tokenLevel(content))
        case .temperature(let value, let content): return .temperature(value, try tokenLevel(content))
        case .repeated, .dispatch:
            throw .conversion("Token markers cannot put a token end over a Repeat or Dispatch format; the free text inside it would stay string-level")
        default: return format
        }
    }
}
