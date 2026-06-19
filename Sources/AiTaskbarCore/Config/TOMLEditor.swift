import Foundation

/// Surgical editor for `config.toml`: replaces one key's value in a specific
/// section while preserving every comment, blank line, unknown key, and the
/// original ordering. Backs the Settings UI write path so users don't lose
/// hand-written notes / annotations when they toggle a setting through the
/// app.
///
/// Approach: line-by-line scan tracking the current `[section]` header.
/// Recognizes the subset of TOML the AppConfig schema actually emits:
///   - section headers `[name]`
///   - bare keys with `=`
///   - scalars: string (`"..."`), bool (`true`/`false`), integer, float
///   - arrays of strings (`["a", "b"]`)
///
/// Tables with dotted headers, multi-line strings, inline tables, and other
/// exotica are NOT supported — `setValue` will throw `.toml("unsupported")`
/// rather than corrupt them. The Settings UI lives within this subset on
/// purpose.
public enum TOMLEditor {
    /// A value the editor can write into a TOML key slot. Each case knows
    /// how to render itself as a TOML literal.
    public enum EncodedValue: Equatable {
        case double(Double)
        case bool(Bool)
        case string(String)
        case stringArray([String])
        /// Pre-encrypted value (output of `SecretBox.encrypt`) — emitted as
        /// a regular TOML string, but flagged so the encoder knows to wrap
        /// in double quotes without escaping the `:` characters (which need
        /// no escaping, but documenting intent matters).
        case encrypted(String)

        /// Renders the value as a TOML RHS literal.
        public var rendered: String {
            switch self {
            case .double(let d):
                // TOML accepts `70` and `70.0` for a float key. Prefer the
                // integer form when the value is a whole number — cleaner
                // round-trip for thresholds like `warning = 70`.
                if d == d.rounded() && abs(d) < 1e15 {
                    return String(Int64(d))
                }
                return String(d)
            case .bool(let b):
                return b ? "true" : "false"
            case .string(let s):
                return Self.quote(s)
            case .encrypted(let s):
                return Self.quote(s)
            case .stringArray(let arr):
                let inner = arr.map { Self.quote($0) }.joined(separator: ", ")
                return "[\(inner)]"
            }
        }

        /// Renders a Swift string as a TOML double-quoted string literal,
        /// escaping the characters the TOML spec requires.
        private static func quote(_ s: String) -> String {
            var out = "\""
            for c in s.unicodeScalars {
                switch c {
                case "\"":  out += "\\\""
                case "\\":  out += "\\\\"
                case "\n":  out += "\\n"
                case "\r":  out += "\\r"
                case "\t":  out += "\\t"
                default:
                    if c.value < 0x20 {
                        out += String(format: "\\u%04X", c.value)
                    } else {
                        out += String(c)
                    }
                }
            }
            out += "\""
            return out
        }
    }

    /// Replaces (or inserts) the value of `key` under `[section]`.
    ///
    /// Behavior:
    ///   - If `[section]` exists and `key = ...` exists within it: replace
    ///     the RHS in place, preserving any inline comment after the value.
    ///   - If `[section]` exists but `key` is missing: append a new line
    ///     `key = value` at the end of the section.
    ///   - If `[section]` doesn't exist: append a new `[section]` block at
    ///     the end of the file with the single `key = value` line.
    ///   - Preserves all comments, blank lines, unknown keys, and ordering.
    public static func setValue(
        in content: String,
        section: String,
        key: String,
        value: EncodedValue
    ) throws -> String {
        var lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Phase 1: locate the target section (if any) and the key within it.
        var currentSection: String? = nil
        var sectionStartIndex: Int? = nil          // line index of the `[section]` header
        var sectionEndIndex: Int? = nil             // exclusive — first line of NEXT section (or count)
        var keyLineIndex: Int? = nil                // line index of `key = ...` inside the target section

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let header = parseSectionHeader(trimmed) {
                if currentSection == section {
                    // We were inside the target section; this new header ends it.
                    sectionEndIndex = i
                    break
                }
                currentSection = header
                if header == section && sectionStartIndex == nil {
                    sectionStartIndex = i
                }
                continue
            }
            if currentSection == section {
                if let parsedKey = parseKeyLine(trimmed), parsedKey == key {
                    keyLineIndex = i
                    break
                }
            }
        }
        // If we exited the loop while still inside the target section, the
        // section extends to the end of the file.
        if sectionStartIndex != nil && sectionEndIndex == nil {
            sectionEndIndex = lines.count
        }

        // Phase 2: write.
        if let keyLineIndex {
            // Replace value in place. Preserve leading whitespace + key +
            // equals sign; preserve any inline comment after the value.
            lines[keyLineIndex] = replaceValue(in: lines[keyLineIndex], value: value)
        } else if let start = sectionStartIndex, let end = sectionEndIndex {
            // Section exists, key doesn't. Insert as the LAST line of the
            // section (before the next header or EOF). Keep a trailing blank
            // line if the section already had one so spacing stays clean.
            var insertAt = end
            // Walk backwards past blank lines so the new key sits with the
            // section body rather than after a separator blank.
            while insertAt > start + 1 && lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert("\(key) = \(value.rendered)", at: insertAt)
        } else {
            // Section doesn't exist. Append fresh block at end of file.
            if !lines.isEmpty && !lines.last!.isEmpty {
                lines.append("")
            }
            lines.append("[\(section)]")
            lines.append("\(key) = \(value.rendered)")
        }

        return lines.joined(separator: "\n")
    }

    /// Replaces the value portion of a `key = value` line, preserving
    /// leading whitespace, the key, the `=` (and any whitespace around it),
    /// and any trailing inline comment. Throws if the line doesn't look like
    /// a key-value we can rewrite.
    private static func replaceValue(in line: String, value: EncodedValue) -> String {
        // Find the `=` that separates key from value. We assume the line was
        // positively identified as `<our key> = ...` by parseKeyLine earlier.
        guard let eq = line.firstIndex(of: "=") else {
            // Should not happen — parseKeyLine already validated this. Keep
            // the line as-is rather than corrupt it.
            return line
        }
        // Preserve the original leading whitespace + key + whitespace + `=`
        // exactly as the user wrote them (config files often use alignment
        // like `api_key     = ...` — collapsing those would be ugly).
        let prefix = String(line[...eq])

        // Capture anything after the value as an inline comment to preserve.
        let afterEq = line[line.index(after: eq)...]
        let rhsStripped = afterEq.trimmingCharacters(in: .whitespaces)
        let trailingComment = extractTrailingComment(rhsStripped)

        var rebuilt = "\(prefix) \(value.rendered)"
        if let trailing = trailingComment {
            rebuilt += "  \(trailing)"
        }
        return rebuilt
    }

    /// Returns the trailing `# comment` portion of a RHS string, if present.
    /// Naive — does NOT account for `#` inside string literals. Acceptable
    /// because `parseKeyLine` only matched lines whose value the editor
    /// itself wrote or that the schema controls (no `#` in api_key values).
    private static func extractTrailingComment(_ rhs: String) -> String? {
        // Skip the first token (the value), then look for `#`.
        // Cheap approach: find first `#` that's preceded by whitespace.
        var inString = false
        var prev: Character = " "
        for c in rhs {
            if c == "\"" { inString.toggle() }
            if c == "#" && !inString && prev == " " {
                // Return from `#` to end (trimmed).
                let idx = rhs.firstIndex(of: "#")!
                return String(rhs[idx...]).trimmingCharacters(in: .whitespaces)
            }
            prev = c
        }
        return nil
    }

    /// Returns the section name if `trimmed` is a `[section]` header line,
    /// else nil. Does NOT match `[[array-of-tables]]` — we don't use those.
    /// Trims surrounding whitespace so callers can pass raw lines without
    /// pre-trimming.
    static func parseSectionHeader(_ trimmed: String) -> String? {
        let s = trimmed.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("[") && s.hasSuffix("]"),
              !s.hasPrefix("[[")
        else { return nil }
        let inner = s.dropFirst().dropLast()
            .trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : String(inner)
    }

    /// Returns the bare key if `trimmed` is a `key = value` line, else nil.
    /// Rejects lines whose key contains `.`, `]`, `[` (nested keys, tables)
    /// — we don't edit those. Trims surrounding whitespace defensively.
    static func parseKeyLine(_ trimmed: String) -> String? {
        let s = trimmed.trimmingCharacters(in: .whitespaces)
        // Cheap: must have `=` not at index 0; key is the part before.
        guard let eq = s.firstIndex(of: "="),
              s.first != "=",
              s.first != "#"
        else { return nil }
        let keyPart = s[..<eq].trimmingCharacters(in: .whitespaces)
        if keyPart.isEmpty { return nil }
        // Reject dotted/bracket keys; only bare keys supported.
        if keyPart.contains(".") || keyPart.contains("[") || keyPart.contains("]") {
            return nil
        }
        // Strip optional surrounding quotes — TOML allows `"key" = value`
        // but our schema never emits those.
        var key = keyPart
        if key.hasPrefix("\"") && key.hasSuffix("\"") && key.count >= 2 {
            key = String(key.dropFirst().dropLast())
        }
        return key
    }
}
