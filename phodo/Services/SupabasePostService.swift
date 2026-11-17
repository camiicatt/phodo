import Supabase
import SwiftUI

/// The real backend: photos → private storage bucket, posts → Postgres.
/// Who-can-see-what is enforced by row-level security (supabase/migrations).
@MainActor
final class SupabasePostService: PostService {
    private let client: SupabaseClient
    private let bucket = "posts"
    init(client: SupabaseClient) { self.client = client }

    struct AuthorRow: Decodable {
        let id: UUID
        let username: String
        let display_name: String
        let avatar_path: String?
    }

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
        let created_at: Date?
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

    /// Name the exact link (posts.user_id → profiles). Posts and profiles are also
    /// connected through reactions, comments and reports, so a bare `profiles(...)`
    /// is ambiguous and Supabase answers "300 multiple choices".
    private static let select = "*, author:profiles!posts_user_id_fkey(id, username, display_name, avatar_path)"
    private var myID: UUID? { client.auth.currentUser?.id }

    // MARK: reads

    func myPosts(_ me: Person) async throws -> [Post] {
        let rows: [PostRow] = try await client.from("posts").select(Self.select)
            .eq("user_id", value: me.id)
            .order("local_date", ascending: false).order("created_at", ascending: false)
            .execute().value
        return try await posts(from: rows)
    }

    func feed(from authors: [UUID], since: Date) async throws -> [Post] {
        guard !authors.isEmpty else { return [] }
        let rows: [PostRow] = try await client.from("posts").select(Self.select)
            .in("user_id", values: authors.map(\.lower))
            .gte("created_at", value: since.ISO8601Format())
            .order("created_at", ascending: false)
            .execute().value
        return try await posts(from: rows)
    }

    func explore() async throws -> [Post] {
        guard let myID else { return [] }
        let rows: [PostRow] = try await client.from("posts").select(Self.select)
            .eq("visibility", value: PostVisibility.everyone.rawValue)
            .neq("user_id", value: myID.lower)
            .order("created_at", ascending: false)
            .limit(60)
            .execute().value
        return try await posts(from: rows)
    }

    func posts(ids: [UUID]) async throws -> [Post] {
        guard !ids.isEmpty else { return [] }
        let rows: [PostRow] = try await client.from("posts").select(Self.select)
            .in("id", values: ids.map(\.lower)).execute().value
        return try await posts(from: rows)
    }

    func posts(by userID: UUID) async throws -> [Post] {
        let rows: [PostRow] = try await client.from("posts").select(Self.select)
            .eq("user_id", value: userID.lower)
            .order("local_date", ascending: false).order("created_at", ascending: false)
            .limit(200)
            .execute().value
        return try await posts(from: rows)
    }

    // MARK: writes

    func createPost(_ draft: PostDraft, by me: Person) async throws -> Post {
        try draft.validate()
        let id = UUID()
        var uploaded: [String] = []
        var thumbPath: String?, fullPath: String?

        // 1. upload the photo (thumb first so feeds can show it soonest)
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

        // 2. insert the row
        let row = NewPost(id: id, user_id: me.id, local_date: draft.day.key,
                          caption: draft.caption, tags: draft.tags,
                          image_path: fullPath, thumb_path: thumbPath,
                          width: draft.photo?.width, height: draft.photo?.height,
                          tint: draft.photo?.tint.hex, visibility: draft.visibility.rawValue)
        do {
            try await client.from("posts").insert(row).execute()
        } catch {
            // 3. undo the upload so no orphaned files are left behind
            if !uploaded.isEmpty { _ = try? await client.storage.from(bucket).remove(paths: uploaded) }
            throw error
        }

        var post = Post(id: id, author: me, day: draft.day, caption: draft.caption, tags: draft.tags,
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

    /// Rows → Posts, with temporary (1 hour) links for photos and avatars.
    private func posts(from rows: [PostRow]) async throws -> [Post] {
        let photoURLs = try await Signer.sign(client, bucket: bucket,
                                              paths: rows.flatMap { [$0.thumb_path, $0.image_path] }.compactMap { $0 })
        let avatarURLs = try await Signer.sign(client, bucket: "avatars",
                                               paths: rows.compactMap { $0.author?.avatar_path })
        return rows.compactMap { r in
            guard let day = LocalDay(key: r.local_date) else { return nil }
            var author = Person(id: r.user_id, username: r.author?.username ?? "someone",
                                displayName: r.author?.display_name ?? "")
            author.avatarPath = r.author?.avatar_path
            author.avatarURL = r.author?.avatar_path.flatMap { avatarURLs[$0] }
            var post = Post(id: r.id, author: author, day: day, caption: r.caption, tags: r.tags,
                            visibility: PostVisibility(rawValue: r.visibility) ?? .friends,
                            image: nil,
                            aspect: CGFloat(r.height ?? 3) / CGFloat(max(r.width ?? 5, 1)),
                            tint: Color(hex: r.tint))
            post.thumbURL = r.thumb_path.flatMap { photoURLs[$0] }
            post.fullURL = r.image_path.flatMap { photoURLs[$0] }
            post.paths = [r.thumb_path, r.image_path].compactMap { $0 }
            post.hasPhoto = r.thumb_path != nil
            post.createdAt = r.created_at ?? Date()
            return post
        }
    }
}

/// Batch-creates temporary links for private storage files.
enum Signer {
    static func sign(_ client: SupabaseClient, bucket: String, paths: [String]) async throws -> [String: URL] {
        let unique = Array(Set(paths))
        guard !unique.isEmpty else { return [:] }
        var urls: [String: URL] = [:]
        for result in try await client.storage.from(bucket).createSignedURLs(paths: unique, expiresIn: 3600) {
            if case let .success(path, url) = result { urls[path] = url }
        }
        return urls
    }
}
