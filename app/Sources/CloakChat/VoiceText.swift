import Foundation

/// Pure text utilities for on-device Local Voice dictation and read-aloud.
public enum VoiceText {
    /// Converts Markdown assistant replies into natural plain speech text
    /// suitable for macOS's offline `AVSpeechSynthesizer`.
    public static func spoken(from markdown: String) -> String {
        var text = markdown

        // Drop reasoning tags if present.
        text = replacing(#"(?s)<think>.*?</think>"#, in: text, with: " ")

        // Replace fenced code blocks with a brief spoken cue.
        text = replacing(#"(?s)```[^\n]*\n?.*?```"#, in: text, with: " Code block omitted. ")

        // Replace Markdown images ![alt](url) with alt text.
        text = replacing(#"!\[([^\]]*)\]\([^\)]+\)"#, in: text, with: "$1")

        // Replace Markdown links [label](url) with label text.
        text = replacing(#"\[([^\]]+)\]\([^\)]+\)"#, in: text, with: "$1")

        // Replace bare URLs with a short spoken cue.
        text = replacing(#"https?://\S+"#, in: text, with: "link")

        // Strip inline code backticks while keeping the identifier inside.
        text = replacing(#"`([^`]+)`"#, in: text, with: "$1")

        // Strip heading markers, blockquotes, and list bullets at line starts.
        text = replacing(#"(?m)^\s{0,3}#{1,6}\s+"#, in: text, with: "")
        text = replacing(#"(?m)^\s*>\s?"#, in: text, with: "")
        text = replacing(#"(?m)^\s*[-*+]\s+"#, in: text, with: "")

        // Strip horizontal rules.
        text = replacing(#"(?m)^\s*([-*_]){3,}\s*$"#, in: text, with: " ")

        // Strip emphasis markers (**bold**, __bold__, *italic*, _italic_, ~~strike~~).
        text = replacing(#"\*\*([^\*]+)\*\*"#, in: text, with: "$1")
        text = replacing(#"__([^_]+)__"#, in: text, with: "$1")
        text = replacing(#"~~([^~]+)~~"#, in: text, with: "$1")
        text = replacing(#"(?<!\w)\*([^\*\n]+)\*(?!\w)"#, in: text, with: "$1")
        text = replacing(#"(?<!\w)_([^_\n]+)_(?!\w)"#, in: text, with: "$1")

        // Collapse newlines and repeated whitespace cleanly.
        text = replacing(#"\s*\n+\s*"#, in: text, with: ". ")
        text = replacing(#"\.\s*\."#, in: text, with: ".")
        text = replacing(#"[ \t]{2,}"#, in: text, with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Merges an existing composer `prefix` with a live dictated `transcript`
    /// while preserving clean spacing.
    public static func merge(prefix: String, transcript: String) -> String {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return prefix }
        guard !prefix.isEmpty else { return cleaned }
        if prefix.last?.isWhitespace == true || prefix.last?.isNewline == true {
            return prefix + cleaned
        }
        return prefix + " " + cleaned
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
