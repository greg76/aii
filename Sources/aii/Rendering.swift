import Foundation

/// Display and config quoting (SPEC-EXEC 5.4). One rendering is used for the
/// approval prompt, the "always allow" text and log lines.
enum Rendering {
    private static let safe: Set<Unicode.Scalar> = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-".unicodeScalars)

    /// Scalars that could spoof or hide content: C0/C1 controls, DEL, format
    /// characters (bidi overrides, zero-width), line/paragraph separators.
    static func needsEscape(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 0x20 || (0x7F...0x9F).contains(v) { return true }
        switch s.properties.generalCategory {
        case .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// True if the string contains nothing that `escape` would alter.
    static func isPlain(_ s: String) -> Bool {
        !s.unicodeScalars.contains(where: needsEscape)
    }

    private static func escape(_ s: Unicode.Scalar) -> String {
        let v = s.value
        if v == 0x0A { return "\\n" }
        if v < 0x20 || (0x7F...0x9F).contains(v) { return String(format: "\\x%02X", v) }
        return String(format: "\\u{%04X}", v)
    }

    static func escape(_ text: String) -> String {
        text.unicodeScalars.map { needsEscape($0) ? escape($0) : String($0) }.joined()
    }

    /// POSIX single-quote a token if it contains anything outside a safe set.
    /// Raw: does not escape control characters (used for the config file).
    static func quote(_ token: String) -> String {
        if !token.isEmpty && token.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return token
        }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func renderToken(_ token: String) -> String {
        quote(escape(token))
    }

    /// The command in full, never abbreviated: escaped, then quoted where needed.
    static func render(_ argv: [String]) -> String {
        argv.map(renderToken).joined(separator: " ")
    }
}
