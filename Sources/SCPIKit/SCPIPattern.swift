import Foundation

/// Matches SCPI command headers against documented patterns such as
/// `[:SOURce]:CURRent[:LEVel][:IMMediate]`, honoring short/long forms and optional nodes.
///
/// Rules (IEEE 488.2 / SCPI-99): case-insensitive; each keyword accepts either its short form
/// (the uppercase letters) or its full long form; `[...]` nodes may be omitted.
public struct SCPIPattern: Sendable, Hashable {
    struct Node: Sendable, Hashable {
        let short: String   // uppercased short form, e.g. "CURR"
        let long: String    // uppercased long form, e.g. "CURRENT"
        let optional: Bool
        func matches(_ token: String) -> Bool {
            let t = token.uppercased()
            return t == short || t == long
        }
    }

    let nodes: [Node]
    public let isQuery: Bool
    public let text: String

    public init(_ pattern: String) {
        text = pattern
        var p = pattern.trimmingCharacters(in: .whitespaces)
        isQuery = p.hasSuffix("?")
        if isQuery { p.removeLast() }
        var result: [Node] = []
        var i = p.startIndex
        while i < p.endIndex {
            var optional = false
            if p[i] == "[" { optional = true; i = p.index(after: i) }
            if i < p.endIndex, p[i] == ":" { i = p.index(after: i) }
            var word = ""
            while i < p.endIndex, p[i] != ":", p[i] != "[", p[i] != "]" {
                word.append(p[i]); i = p.index(after: i)
            }
            if i < p.endIndex, p[i] == "]" { i = p.index(after: i) }
            word = word.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            let short: String
            if word.hasPrefix("*") || word.allSatisfy({ !$0.isLowercase }) {
                short = word.uppercased()
            } else {
                short = String(word.filter { $0.isUppercase || $0.isNumber }).uppercased()
            }
            result.append(Node(short: short, long: word.uppercased(), optional: optional))
        }
        nodes = result
    }

    /// Returns true if `header` (e.g. `:SOUR:CURR:LEV:IMM?`, `curr?`) matches this pattern.
    public func matches(header: String) -> Bool {
        var h = header.trimmingCharacters(in: .whitespaces)
        let q = h.hasSuffix("?")
        if q { h.removeLast() }
        guard q == isQuery else { return false }
        let tokens = h.split(separator: ":", omittingEmptySubsequences: true).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        return Self.match(nodes[...], tokens[...])
    }

    private static func match(_ nodes: ArraySlice<Node>, _ tokens: ArraySlice<String>) -> Bool {
        guard let n = nodes.first else { return tokens.isEmpty }
        if let t = tokens.first, n.matches(t), match(nodes.dropFirst(), tokens.dropFirst()) {
            return true
        }
        return n.optional && match(nodes.dropFirst(), tokens)
    }
}

/// A parsed program message unit: header plus comma-separated arguments.
public struct SCPIMessage: Sendable, Equatable {
    public let header: String
    public let arguments: [String]
    public var isQuery: Bool { header.hasSuffix("?") }

    /// Parses one unit, e.g. `:LIST:LEVel 3,4.5` → header `:LIST:LEVel`, args `["3","4.5"]`.
    /// Note the real SDL accepts stray spaces after colons (`:SOURce: OCP:FUNC`) — they are
    /// stripped here too.
    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Header ends at the first whitespace that is followed by a non-colon character.
        var headerEnd = trimmed.endIndex
        var i = trimmed.startIndex
        while i < trimmed.endIndex {
            if trimmed[i] == " " {
                var j = i
                while j < trimmed.endIndex, trimmed[j] == " " { j = trimmed.index(after: j) }
                if j < trimmed.endIndex, trimmed[j] != ":", trimmed[trimmed.index(before: i)] != ":" {
                    headerEnd = i; break
                }
            }
            i = trimmed.index(after: i)
        }
        header = trimmed[..<headerEnd].replacingOccurrences(of: " ", with: "")
        let rest = trimmed[headerEnd...].trimmingCharacters(in: .whitespaces)
        arguments = rest.isEmpty ? [] : rest.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Splits a full line on `;` into message units. A unit beginning with `:` is absolute;
    /// we do not implement the SCPI "current path" rule for relative units because the
    /// SDL apps only ever send absolute headers.
    public static func split(line: String) -> [SCPIMessage] {
        line.split(separator: ";").map { SCPIMessage(String($0)) }.filter { !$0.header.isEmpty }
    }
}
