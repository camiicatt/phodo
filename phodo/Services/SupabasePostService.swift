import Supabase
import SwiftUI

/// The real backend: photos → private storage bucket, posts → Postgres.
/// Privacy is enforced by the row-level security in supabase/migrations.
@MainActor
final class SupabasePostService: PostService {
    private let client: SupabaseClient
    private let bucket = "posts"
    init(client: SupabaseClient) { self.client = client }

    private struct AuthorRow: Decodable { let id: UUID; let username: String; let display_name: String }

    private struct PostRow: Decodable {
        let id: UUID
        let user_id: UUID
        let local_date: String
        let caption: String
        let tags: [String]
        let image_path: String?
        let thumb_path: String?
        let width: Int?
        let height: Int?
        let tint: String?
        let visibility: String
        let author: AuthorRow?
    }

    private struct NewPost: Encodable {
        let id: UUID
        let user_id: UUID
        let local_date: String
        let caption: String
        let tags: [String]
        let image_path: String?
        let thumb_path: String?
        let width: Int?
        let height: Int?
        let tint: String?
        let visibility: String
    }

    private var myID: UUID? { client.auth.currentUser?.id }

    // MARK: reads

    func myPosts(_ me: Person) async throws -> [Post] {
        let rows: [PostRow] = try await client.from("posts").select()
            .eq("user_id", value: me.id).order("local_date", ascending: false).execute().value
        return try await posts(from: rows, fallbackAuthor: me)
    }

    func friendsFeed(on day: LocalDay) async throws -> [Post] {
        // RLS already limits this to: friends' "friends" posts (+ my own, filtered out below).
        let rows: [PostRow] = try await client.from("posts")
            .select("*, author:profiles(id, username, display_name)")
            .eq("local_date", value: day.key)
            .order("created_at", ascending: false)
            .execute().value
        return try await posts(from: rows.filter { $0.user_id != myID }, fallbackAuthor: nil)
    }

    // MARK: writes

    func createPost(_ draft: PostDraft, by me: Person, on day: LocalDay) async throws -> Post {
        guard !draft.isEmpty else { throw PostError.empty }
        let id = UUID()
        var uploaded: [String] = []
        var thumbPath: String?, fullPath: String?

        // 1. upload photo (thumb first so the feed can show it soonest)
        if let photo = draft.photo {
            let folder = "\(me.id.lower)/\(id.lower)"
            thumbPath = "\(folder)/thumb.jpg"
            fullPath = "\(folder)/full.jpg"
            let options = FileOptions(contentType: "image/jpeg")
            _ = try await client.storage.from(bucket).upload(thumbPath!, data: photo.thumbJPEG, options: options)
            uploaded.append(thumbPath!)
            _ = try await client.storage.from(bucket).upload(fullPath!, data: photo.fullJPEG, options: options)
            uploaded.append(fullPath!)
        }

        // 2. insert the row. UNIQUE(user_id, local_date) = one post a day.
        let row = NewPost(id: id, user_id: me.id, local_date: day.key,
                          caption: draft.caption, tags: draft.tags,
                          image_path: fullPath, thumb_path: thumbPath,
                          width: draft.photo?.width, height: draft.photo?.height,
                          tint: draft.photo?.tint.hex, visibility: draft.visibility.rawValue)
        do {
            try await client.from("posts").insert(row).execute()
        } catch {
            // 3. undo the upload so no orphaned files are left behind
            if !uploaded.isEmpty { _ = try? await client.storage.from(bucket).remove(paths: uploaded) }
            if isUniqueViolation(error) { throw PostError.alreadyPostedToday }
            throw error
        }

        var post = Post(id: id, author: me, day: day, caption: draft.caption, tags: draft.tags,
                        visibility: draft.visibility, image: draft.photo?.preview,
                        aspect: draft.photo?.aspect ?? 0.6,
                        tint: draft.photo.map { Color(uiColor: $0.tint) })
        post.paths = uploaded
        post.hasPhoto = draft.photo != nil
        return post
    }

    func deletePost(_ id: UUID) async throws {
        struct Paths: Decodable { let image_path: String?; let thumb_path: String? }
        let rows: [Paths] = try await client.from("posts").select("image_path, thumb_path")
            .eq("id", value: id).execute().value
        try await client.from("posts").delete().eq("id", value: id).execute()
        let paths = rows.flatMap { [$0.image_path, $0.thumb_path] }.compactMap { $0 }
        if !paths.isEmpty { _ = try? await client.storage.from(bucket).remove(paths: paths) }
    }

    // MARK: helpers

    /// Rows → Posts, with temporary (1 hour) links for the thumbnails.
    private func posts(from rows: [PostRow], fallbackAuthor: Person?) async throws -> [Post] {
        let thumbPaths = rows.compactMap(\.thumb_path)
        var urls: [String: URL] = [:]
        if !thumbPaths.isEmpty {
            for result in try await client.storage.from(bucket).createSignedURLs(paths: thumbPaths, expiresIn: 3600) {
                if case let .success(path, url) = result { urls[path] = url }
            }
        }
        return rows.compactMap { r in
            guard let day = LocalDay(key: r.local_date) else { return nil }
            let author = r.author.map { Person(id: $0.id, username: $0.username, displayName: $0.display_name) }
                ?? fallbackAuthor ?? Person(id: r.user_id, username: "someone", displayName: "")
            var post = Post(id: r.id, author: author, day: day, caption: r.caption, tags: r.tags,
                            visibility: PostVisibility(rawValue: r.visibility) ?? .friends,
                            image: nil,
                            aspect: CGFloat(r.height ?? 3) / CGFloat(max(r.width ?? 5, 1)),
                            tint: Color(hex: r.tint))
            post.thumbURL = r.thumb_path.flatMap { urls[$0] }
            post.paths = [r.thumb_path, r.image_path].compactMap { $0 }
            post.hasPhoto = r.thumb_path != nil
            return post
        }
    }
}
