import SwiftUI

enum PostError: LocalizedError, Equatable {
    case alreadyPostedToday
    case empty

    var errorDescription: String? {
        switch self {
        case .alreadyPostedToday: "you already posted today — see you tomorrow ☾"
        case .empty: "add a pic or a few words first"
        }
    }
}

/// The app talks to the backend only through this protocol.
/// `MockPostService` runs everything in memory today; a `SupabasePostService`
/// (see docs/ARCHITECTURE.md) slots in later without touching any screen.
@MainActor
protocol PostService {
    func myPosts(_ me: Person) async throws -> [Post]
    func friendsFeed(on day: LocalDay) async throws -> [Post]
    /// Upload photo (if any) → insert post row. Throws `.alreadyPostedToday`.
    func createPost(_ draft: PostDraft, by me: Person, on day: LocalDay) async throws -> Post
    func deletePost(_ id: UUID) async throws
}

@MainActor
final class MockPostService: PostService {
    private var mine: [Post] = []
    private var friends: [Post]

    init(me: Person, seed: Bool = true) {
        friends = seed ? SampleData.friendPosts() : []
        mine = seed ? SampleData.myPosts(me) : []
    }

    func myPosts(_ me: Person) async throws -> [Post] { mine.sorted { $0.day > $1.day } }

    func friendsFeed(on day: LocalDay) async throws -> [Post] {
        friends.filter { $0.day == day && $0.visibility == .friends }
    }

    func createPost(_ draft: PostDraft, by me: Person, on day: LocalDay) async throws -> Post {
        guard !draft.isEmpty else { throw PostError.empty }
        // In Supabase this is the UNIQUE(user_id, local_date) constraint.
        guard !mine.contains(where: { $0.day == day }) else { throw PostError.alreadyPostedToday }

        try await Task.sleep(for: .milliseconds(600))   // pretend upload

        let post = Post(id: UUID(), author: me, day: day,
                        caption: draft.caption, tags: draft.tags, visibility: draft.visibility,
                        image: draft.photo?.preview, aspect: draft.photo?.aspect ?? 0.6,
                        tint: draft.photo.map { Color(uiColor: $0.tint) })
        var saved = post
        saved.hasPhoto = draft.photo != nil
        mine.append(saved)
        return saved
    }

    func deletePost(_ id: UUID) async throws {
        mine.removeAll { $0.id == id }
    }
}
