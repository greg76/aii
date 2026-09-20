import Foundation

enum AIIVersion {
    static let current = "0.9.0"
}

/// Config file format (SPEC-EXEC Section 6).
extension Allowlist {
    /// POSIX-style tokenizer: whitespace separates; single quotes are literal;
    /// double quotes honour backslash escapes for `" \ $ \``; a bare backslash
    /// escapes the next character. No variable or tilde expansion.
    /// Returns nil for unterminated quotes or a trailing backslash.
    static func tokenize(line: String) -> [String]? {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        var inToken = false
        var it = line.unicodeScalars.makeIterator()

        while let c = it.next() {
            switch c {
            case " ", "\t", "\r", "\n":
                if inToken {
                    tokens.append(String(current))
                    current = String.UnicodeScalarView()
                    inToken = false
                }
            case "'":
                inToken = true
                var closed = false
                while let d = it.next() {
                    if d == "'" { closed = true; break }
                    current.append(d)
                }
                if !closed { return nil }
            case "\"":
                inToken = true
                var closed = false
                while let d = it.next() {
                    if d == "\"" { closed = true; break }
                    if d == "\\" {
                        guard let e = it.next() else { return nil }
                        if "\"\\$`".unicodeScalars.contains(e) {
                            current.append(e)
                        } else {
                            current.append(d)
                            current.append(e)
                        }
                    } else {
                        current.append(d)
                    }
                }
                if !closed { return nil }
            case "\\":
                guard let e = it.next() else { return nil }
                inToken = true
                current.append(e)
            default:
                inToken = true
                current.append(c)
            }
        }
        if inToken { tokens.append(String(current)) }
        return tokens
    }

    /// Blank lines and `#` comments are ignored; malformed lines are reported by
    /// their 1-based line number.
    static func parseConfig(_ text: String) -> (rules: [Rule], skippedLines: [Int]) {
        var rules: [Rule] = []
        var skipped: [Int] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let tokens = tokenize(line: line), let first = tokens.first, !first.isEmpty else {
                skipped.append(index + 1)
                continue
            }
            rules.append(Rule(argv: tokens))
        }
        return (rules, skipped)
    }

    /// One config line for a rule (raw quoting; no display escaping).
    static func formatRule(_ rule: Rule) -> String {
        rule.argv.map(Rendering.quote).joined(separator: " ")
    }

    /// Content of a freshly seeded config file: header, all defaults, the new rule.
    static func seedText(adding rule: Rule) -> String {
        let header = [
            "# seeded from aii \(AIIVersion.current) built-in defaults",
            "# one rule per line: an argv prefix",
        ]
        let lines = header + AllowPolicy.defaults.map(formatRule) + [formatRule(rule)]
        return lines.joined(separator: "\n") + "\n"
    }
}
