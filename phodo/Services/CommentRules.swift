import Foundation

/// Comments are tiny on purpose: "so cute", "awww", "love this".
/// 30 characters max, and cuss words / slurs / "kys"-type stuff gets stopped
/// before it posts.
///
/// The same patterns live in the database (supabase/migrations/0009_comments.sql,
/// `comment_flagged`), so a modified app can't get around them. Keep the two in sync.
enum CommentRules {
    static let maxLength = 30

    /// Quick taps above the text box.
    static let quickPicks = ["so cute", "awww", "love this", "obsessed", "the vibes", "need this", "core memory"]

    enum Problem: Error, Equatable {
        case empty, tooLong, notNice, slowDown

        var message: String {
            switch self {
            case .empty: "say something first"
            case .tooLong: "keep it under \(CommentRules.maxLength)"
            case .notNice: "keep it kind. that one can't be posted here"
            case .slowDown: "whoa, slow down a sec"
            }
        }
    }

    /// nil = good to post.
    static func problem(with text: String) -> Problem? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .empty }
        if t.count > maxLength { return .tooLong }
        if isFlagged(t) { return .notNice }
        return nil
    }

    // MARK: the filter

    /// Matched against the whole comment with spaces and symbols removed,
    /// so "n i g g" or "k.y.s" style spacing doesn't slip through.
    /// Only long, distinctive patterns go here (short ones would hit normal words).
    static let anywhere = [
        "n+i+g{2,}",
        "f+a+g+o+t",
        "t+r+a+n{2,}y",
        "k+i+l+(y+o+u+r*|u+r*)s+e+l+f",
        "m+o+t+h+e+r+f",
        "c+u+n+t",
    ]

    /// Matched against each word on its own (the whole word).
    static let words = [
        // cussing
        "f+u*c+k+.*", "f+u+k+.*", "f+c+u+k+.*", "p+h+u+c*k+.*",
        "s+h+i+t+.*", "b+i+t+c+h+.*", "b+a+s+t+a+r+d+.*",
        "w+h+o+r+e+s*", "s+l+u+t+.*",
        "a+s+s+(h+o+l+e+s*|e+s)?", "a+r+s+e+", "(j+a+c+k+|d+u+m+b+|s+m+a+r+t+)a+s+s+",
        "d+i+c+k+(h+e+a+d+)?s*", "c+o+c+k+s*", "p+u+s+s+y+",
        "p+i+s+s+(e+d+|i+n+g*)?",
        "w+t+f+", "s+t+f+u+", "k+y+s+",
        // slurs
        "f+a+g+s*", "r+e+t+a+r+d+.*",
        "(s+p+i+c+|c+h+i+n+k+|k+i+k+e+|g+o+o+k+|c+o+o+n+|d+y+k+e+|b+e+a+n+e+r+)s*",
        "(w+e+t+b+a+c+k+|r+a+g+h+e+a+d+|t+o+w+e+l+h+e+a+d+)s*",
    ]

    private static let anywhereRegex = try! NSRegularExpression(pattern: "(" + anywhere.joined(separator: "|") + ")")
    private static let wordRegex = try! NSRegularExpression(pattern: "^(" + words.joined(separator: "|") + ")$")

    static func isFlagged(_ text: String) -> Bool {
        let s = normalized(text)
        let squashed = s.filter { $0.isASCII && $0.isLetter }
        if matches(anywhereRegex, squashed) { return true }
        // spaced out ("k y s", "w t f") — the whole comment squashed is one bad word
        if matches(wordRegex, squashed) { return true }
        let tokens = s.split { !($0.isASCII && $0.isLetter) }.map(String.init)
        return tokens.contains { matches(wordRegex, $0) }
    }

    /// lowercase, no accents, and the usual number/symbol swaps undone (sh1t → shit, @ss → ass).
    static func normalized(_ text: String) -> String {
        let swaps: [Character: Character] = [
            "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b",
            "@": "a", "$": "s", "!": "i", "|": "i", "+": "t",
        ]
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        return String(folded.map { swaps[$0] ?? $0 })
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
