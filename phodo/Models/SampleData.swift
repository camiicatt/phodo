import SwiftUI

/// Fake friends + history so every screen has something to show before the
/// backend exists. Mirrors the mockup content.
enum SampleData {
    static let me = Person(id: UUID(), username: "yourname", displayName: "your name",
                           bio: "just documenting the little stuff ☾", location: "sa, tx")

    static let friends: [Person] = ["maya", "jordan", "priya", "leo", "sam"].map {
        Person(id: UUID(), username: $0, displayName: $0)
    }

    static func friendPosts(on day: LocalDay = .today) -> [Post] {
        let rows: [(String, String, [String], CGFloat)] = [
            ("maya", "parking garage sunset", ["sunset", "nofilter"], 1.2),
            ("leo", "rainy walk, no umbrella", ["campuswalk"], 0.9),
            ("jordan", "stats hw: defeated", ["studying"], 0.72),
            ("sam", "pumpkin patch w the roomies", ["fallvibes"], 1.15),
            ("priya", "abuela’s tamales pt 2", [], 0.95),
        ]
        return rows.map { name, caption, tags, aspect in
            Post(id: UUID(), author: friends.first { $0.username == name }!, day: day,
                 caption: caption, tags: tags, visibility: .friends,
                 image: nil, aspect: aspect, tint: nil)
        }
    }

    static func myPosts(_ me: Person) -> [Post] {
        let rows: [(Int, String, [String], CGFloat)] = [
            (1, "iced latte walk to class", ["coffee"], 1.15),
            (2, "library nook szn", ["studying"], 0.85),
            (3, "nap > everything", ["nap"], 0.78),
            (4, "pan dulce run", ["foodie"], 1.02),
            (6, "new hoodie", ["fallvibes"], 0.8),
            (9, "first cold morning", ["campuswalk"], 1.1),
        ]
        return rows.map { back, caption, tags, aspect in
            Post(id: UUID(), author: me, day: LocalDay.today.adding(days: -back),
                 caption: caption, tags: tags, visibility: .friends,
                 image: nil, aspect: aspect, tint: nil)
        }
    }

    static let recentTags = ["coffee", "campuswalk", "nap", "fallvibes", "foodie", "studying"]
}
