import SwiftUI

/// Fake people + posts so every screen has something in demo mode
/// (no Supabase keys). The real app never shows these.
enum SampleData {
    static let me = Person(id: UUID(), username: "yourname", displayName: "your name",
                           bio: "just documenting the little stuff ☾", location: "")

    static let friends: [Person] = ["maya", "jordan", "priya", "leo", "sam"].map {
        Person(id: UUID(), username: $0, displayName: $0)
    }

    /// People you're not friends with (explore + search in demo mode).
    static let strangers: [Person] = ["june", "ari", "noor", "theo"].map {
        Person(id: UUID(), username: $0, displayName: $0)
    }

    /// Suggested tags before you've used any of your own. Everyday life, not school.
    static let starterTags = ["coffee", "outside", "food", "friends", "sunset", "cozy", "pets", "music"]

    static func friendPosts(on day: LocalDay = .today) -> [Post] {
        let rows: [(String, String, [String], CGFloat)] = [
            ("maya", "parking garage sunset", ["sunset"], 1.2),
            ("leo", "rainy walk, no umbrella", ["outside"], 0.9),
            ("jordan", "made pasta from scratch (kind of)", ["food"], 0.72),
            ("sam", "pumpkin patch w the roomies", ["friends"], 1.15),
            ("priya", "abuela’s tamales pt 2", ["food"], 0.95),
        ]
        return rows.enumerated().map { i, row in
            var p = Post(id: UUID(), author: friends.first { $0.username == row.0 }!, day: day,
                         caption: row.1, tags: row.2, visibility: .friends,
                         image: nil, aspect: row.3, tint: nil)
            p.createdAt = Date().addingTimeInterval(TimeInterval(-i * 1800))
            return p
        }
    }

    static func explorePosts() -> [Post] {
        let rows: [(Int, String, [String], CGFloat)] = [
            (0, "first snow on the fire escape", ["outside"], 1.25),
            (1, "my cat refuses to leave this box", ["pets"], 0.85),
            (2, "record store finds", ["music"], 1.0),
            (3, "tiny breakfast, big day", ["food", "cozy"], 0.75),
        ]
        return rows.map { i, caption, tags, aspect in
            var p = Post(id: UUID(), author: strangers[i], day: .today, caption: caption, tags: tags,
                         visibility: .everyone, image: nil, aspect: aspect, tint: nil)
            p.createdAt = Date().addingTimeInterval(TimeInterval(-i * 2400))
            return p
        }
    }

    static func myPosts(_ me: Person) -> [Post] {
        let rows: [(Int, String, [String], CGFloat)] = [
            (1, "iced latte walk", ["coffee"], 1.15),
            (2, "found a good reading spot", ["cozy"], 0.85),
            (3, "nap > everything", ["cozy"], 0.78),
            (4, "pan dulce run", ["food"], 1.02),
            (6, "new hoodie", ["outside"], 0.8),
            (9, "first cold morning", ["outside"], 1.1),
        ]
        return rows.map { back, caption, tags, aspect in
            var p = Post(id: UUID(), author: me, day: LocalDay.today.adding(days: -back),
                         caption: caption, tags: tags, visibility: .friends,
                         image: nil, aspect: aspect, tint: nil)
            p.createdAt = LocalDay.today.adding(days: -back).date.addingTimeInterval(15 * 3600)
            return p
        }
    }
}
