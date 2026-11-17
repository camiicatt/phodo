import SwiftUI

enum PostError: LocalizedError, Equatable {
    case empty
    case futureDay

    var errorDescription: String? {
        switch self {
        case .empty: "add a pic or a few words first"
        case .futureDay: "you can't post for a day that hasn't happened yet"
        }
    }
}

/// The app talks to the backend only through these protocols.
/// Mock versions run everything in memory (demo mode); Supabase versions are real.
@MainActor
protocol PostService {
    func myPosts(_ me: Person) async throws -> [Post]
    /// Posts from these people created in the last day (includes missed-day posts).
    func feed(from authors: [UUID], since: Date) async throws -> [Post]
    /// Recent "everyone" posts from people who aren't me.
    func explore() async throws -> [Post]
    func posts(ids: [UUID]) async throws -> [Post]
    func createPost(_ draft: PostDraft, by me: Person) async throws -> Post
    func deletePost(_ id: UUID) async throws
}

extension PostDraft {
    /// Shared rules for every backend.
    func validate() throws {
        guard !isEmpty else { throw PostError.empty }
        guard day <= LocalDay.today else { throw PostError.futureDay }
    }
}

@MainActor
final class MockPostService: PostService {
    private var all: [Post]

    init(me: Person, seed: Bool = true) {
        all = seed ? SampleData.friendPosts() + SampleData.myPosts(me) + SampleData.explorePosts() : []
    }

    func myPosts(_ me: Person) async throws -> [Post] {
        all.filter { $0.author.id == me.id }.sorted { ($0.day, $0.createdAt) > ($1.day, $1.createdAt) }
    }

    func feed(from authors: [UUID], since: Date) async throws -> [Post] {
        let ids = Set(authors)
        return all.filter { ids.contains($0.author.id) && $0.visibility != .justMe && $0.createdAt >= since }
    }

    func explore() async throws -> [Post] {
        all.filter { $0.visibility == .everyone && !SampleData.friends.map(\.id).contains($0.author.id) }
    }

    func posts(ids: [UUID]) async throws -> [Post] {
        all.filter { ids.contains($0.id) }
    }

    func createPost(_ draft: PostDraft, by me: Person) async throws -> Post {
        try draft.validate()
        try await Task.sleep(for: .milliseconds(500))   // pretend upload
        var post = Post(id: UUID(), author: me, day: draft.day,
                        caption: draft.caption, tags: draft.tags, visibility: draft.visibility,
                        image: draft.photo?.preview, aspect: draft.photo?.aspect ?? 0.6,
                        tint: draft.photo.map { Color(uiColor: $0.tint) })
        post.hasPhoto = draft.photo != nil
        all.append(post)
        return post
    }

    func deletePost(_ id: UUID) async throws {
        all.removeAll { $0.id == id }
    }
}
