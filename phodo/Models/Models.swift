import SwiftUI

/// A calendar day in the poster's own time zone. "One post per day" is keyed on
/// this, never on a UTC timestamp, so 11pm in Texas is still today.
struct LocalDay: Hashable, Comparable, Codable {
    let year: Int, month: Int, day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    /// From a stored "2026-11-16".
    init?(key: String) {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    static var today: LocalDay { LocalDay(Date()) }

    var date: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func adding(days: Int) -> LocalDay {
        LocalDay(Calendar.current.date(byAdding: .day, value: days, to: date)!)
    }

    /// "2026-11-16" — the value stored in posts.local_date.
    var key: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// "nov 16"
    var short: String { date.formatted(.dateTime.month(.abbreviated).day()).lowercased() }

    /// "mon · 11.16"
    var header: String {
        let weekday = date.formatted(.dateTime.weekday(.abbreviated)).lowercased()
        return "\(weekday) · \(String(format: "%02d.%02d", month, day))"
    }

    static func < (a: LocalDay, b: LocalDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

struct Person: Identifiable, Hashable {
    let id: UUID
    var username: String
    var displayName: String
    var bio: String = ""
    var location: String = ""
    var theme: String = ThemePreset.lavender.id
}

enum PostVisibility: String, CaseIterable {
    case friends
    case justMe = "private"
}

struct Post: Identifiable {
    let id: UUID
    let author: Person
    let day: LocalDay
    var caption: String
    var tags: [String]
    var visibility: PostVisibility
    /// Local preview of the photo (real app: loaded from a signed URL).
    var image: UIImage?
    /// height / width, saved at upload so masonry can lay out before images load.
    var aspect: CGFloat
    /// Average color of the photo — used as the placeholder while it loads.
    var tint: Color?
    /// Temporary signed link to the thumbnail (real backend only).
    var thumbURL: URL? = nil
    /// Storage paths, so deleting the post can delete the files.
    var paths: [String] = []
    /// false for words-only posts.
    var hasPhoto: Bool = true
}

struct Board: Identifiable {
    let id: UUID
    var name: String
    var postIDs: [UUID]
}

/// What the "today" screen hands to the backend.
struct PostDraft {
    var caption: String
    var tags: [String]
    var visibility: PostVisibility
    var photo: ProcessedPhoto?

    var isEmpty: Bool { photo == nil && caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
