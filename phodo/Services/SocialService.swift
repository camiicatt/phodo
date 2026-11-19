import Supabase
import SwiftUI

/// Friends, boards, and safety (report / block).
@MainActor
protocol SocialService {
    // friends
    func connections() async throws -> [Connection]
    func search(_ query: String) async throws -> [Person]
    /// Friends of my friends I'm not connected to yet, most mutual friends first.
    func suggestions() async throws -> [Suggestion]
    func request(_ id: UUID) async throws
    func accept(_ id: UUID) async throws
    /// Unfriend, cancel a request, or decline one.
    func remove(_ id: UUID) async throws

    // boards: yours (all), or someone else's (public ones only)
    func boards(of userID: UUID) async throws -> [Board]
    func setBoardPublic(_ id: UUID, _ isPublic: Bool) async throws
    func createBoard(named name: String) async throws -> Board
    func renameBoard(_ id: UUID, to name: String) async throws
    func deleteBoard(_ id: UUID) async throws
    func save(_ postID: UUID, to boardID: UUID) async throws
    func unsave(_ postID: UUID, from boardID: UUID) async throws

    // likes
    /// Which of these posts I've liked, and like counts on MY posts (others' likes only).
    func likes(on postIDs: [UUID]) async throws -> (mine: Set<UUID>, counts: [UUID: Int])
    func like(_ postID: UUID) async throws
    func unlike(_ postID: UUID) async throws
    func stats(for userID: UUID) async throws -> ProfileStats

    // comments (tiny ones — 30 characters, checked by CommentRules here and in the database)
    /// Oldest first. Only on posts I'm allowed to see; blocked people's are hidden.
    func comments(on postID: UUID) async throws -> [Comment]
    func addComment(_ comment: Comment) async throws
    /// Mine, or anyone's on my post.
    func deleteComment(_ id: UUID) async throws

    // notifications
    func savePushToken(_ token: String, sandbox: Bool) async throws
    /// Friends whose "posted" pings I turned off. Everyone else I'm friends with pings by default.
    func mutes() async throws -> Set<UUID>
    func setMuted(_ friendID: UUID, muted: Bool) async throws
    func setNotifyRequests(_ on: Bool) async throws
    /// Ask the server to send a push. kind: "post" (id = post), "request" / "accept" (id = person).
    func notify(_ kind: String, id: UUID) async

    // safety
    func report(post: UUID?, user: UUID, reason: String) async throws
    func block(_ id: UUID) async throws
}

// MARK: - Supabase

@MainActor
final class SupabaseSocialService: SocialService {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    private var me: UUID {
        get throws {
            guard let id = client.auth.currentUser?.id else { throw AccountError.notSignedIn }
            return id
        }
    }

    private typealias ProfileLite = SupabasePostService.AuthorRow
    private static let lite = "id, username, display_name, avatar_path"

    private func people(_ rows: [ProfileLite]) async throws -> [Person] {
        let urls = try await Signer.sign(client, bucket: "avatars", paths: rows.compactMap(\.avatar_path))
        return rows.map {
            var p = Person(id: $0.id, username: $0.username, displayName: $0.display_name)
            p.avatarPath = $0.avatar_path
            p.avatarURL = $0.avatar_path.flatMap { urls[$0] }
            return p
        }
    }

    // MARK: friends

    func connections() async throws -> [Connection] {
        struct Row: Decodable {
            let requester: UUID
            let addressee: UUID
            let status: String
            let r: ProfileLite
            let a: ProfileLite
        }
        let rows: [Row] = try await client.from("friendships").select(
            "requester, addressee, status, r:profiles!friendships_requester_fkey(\(Self.lite)), a:profiles!friendships_addressee_fkey(\(Self.lite))"
        ).execute().value
        let me = try me
        let others = rows.map { $0.requester == me ? $0.a : $0.r }
        let persons = try await people(others)
        let all = zip(rows, persons).map { row, person in
            let status: FriendStatus = row.status == "accepted" ? .friends : (row.requester == me ? .outgoing : .incoming)
            return Connection(person: person, status: status)
        }
        return Connection.merged(all)
    }

    func search(_ query: String) async throws -> [Person] {
        let q = Username.clean(query)
        guard !q.isEmpty else { return [] }
        let rows: [ProfileLite] = try await client.from("profiles").select(Self.lite)
            .ilike("username", pattern: "\(q)%")
            .neq("id", value: try me.lower)
            .order("username").limit(20)
            .execute().value
        return try await people(rows)
    }

    func suggestions() async throws -> [Suggestion] {
        struct Row: Decodable {
            let id: UUID; let username: String; let display_name: String
            let avatar_path: String?; let mutual: Int
        }
        let rows: [Row] = try await client.rpc("suggested_friends").execute().value
        let persons = try await people(rows.map {
            ProfileLite(id: $0.id, username: $0.username, display_name: $0.display_name, avatar_path: $0.avatar_path)
        })
        return zip(rows, persons).map { Suggestion(person: $1, mutual: $0.mutual) }
    }

    func request(_ id: UUID) async throws {
        struct New: Encodable { let requester: UUID; let addressee: UUID }
        do {
            try await client.from("friendships").insert(New(requester: try me, addressee: id)).execute()
        } catch where isUniqueViolation(error) {
            // already requested — fine
        }
    }

    func accept(_ id: UUID) async throws {
        try await client.from("friendships").update(["status": "accepted"])
            .eq("requester", value: id.lower).eq("addressee", value: try me.lower).execute()
    }

    func remove(_ id: UUID) async throws {
        let me = try me.lower, them = id.lower
        try await client.from("friendships").delete()
            .or("and(requester.eq.\(me),addressee.eq.\(them)),and(requester.eq.\(them),addressee.eq.\(me))")
            .execute()
    }

    // MARK: boards

    func boards(of userID: UUID) async throws -> [Board] {
        struct Item: Decodable { let post_id: UUID }
        struct Row: Decodable { let id: UUID; let name: String; let is_public: Bool; let board_items: [Item] }
        // RLS: for someone else this only returns their public boards
        let rows: [Row] = try await client.from("boards").select("id, name, is_public, board_items(post_id, added_at)")
            .eq("user_id", value: userID.lower)
            .order("created_at").execute().value
        return rows.map { Board(id: $0.id, name: $0.name, postIDs: $0.board_items.map(\.post_id), isPublic: $0.is_public) }
    }

    func setBoardPublic(_ id: UUID, _ isPublic: Bool) async throws {
        try await client.from("boards").update(["is_public": isPublic]).eq("id", value: id.lower).execute()
    }

    func createBoard(named name: String) async throws -> Board {
        struct New: Encodable { let id: UUID; let name: String }
        let board = Board(id: UUID(), name: name, postIDs: [])
        try await client.from("boards").insert(New(id: board.id, name: name)).execute()
        return board
    }

    func renameBoard(_ id: UUID, to name: String) async throws {
        try await client.from("boards").update(["name": name]).eq("id", value: id.lower).execute()
    }

    func deleteBoard(_ id: UUID) async throws {
        try await client.from("boards").delete().eq("id", value: id.lower).execute()
    }

    func save(_ postID: UUID, to boardID: UUID) async throws {
        struct New: Encodable { let board_id: UUID; let post_id: UUID }
        do {
            try await client.from("board_items").insert(New(board_id: boardID, post_id: postID)).execute()
        } catch where isUniqueViolation(error) {}
    }

    func unsave(_ postID: UUID, from boardID: UUID) async throws {
        try await client.from("board_items").delete()
            .eq("board_id", value: boardID.lower).eq("post_id", value: postID.lower).execute()
    }

    // MARK: likes

    func likes(on postIDs: [UUID]) async throws -> (mine: Set<UUID>, counts: [UUID: Int]) {
        guard !postIDs.isEmpty else { return ([], [:]) }
        struct Row: Decodable { let post_id: UUID; let user_id: UUID }
        // RLS returns: my likes + likes on my posts
        let rows: [Row] = try await client.from("likes").select("post_id, user_id")
            .in("post_id", values: postIDs.map(\.lower)).execute().value
        let me = try me
        let mine = Set(rows.filter { $0.user_id == me }.map(\.post_id))
        let counts = Dictionary(grouping: rows.filter { $0.user_id != me }, by: \.post_id).mapValues(\.count)
        return (mine, counts)
    }

    func like(_ postID: UUID) async throws {
        struct New: Encodable { let post_id: UUID }
        do { try await client.from("likes").insert(New(post_id: postID)).execute() }
        catch where isUniqueViolation(error) {}
    }

    func unlike(_ postID: UUID) async throws {
        try await client.from("likes").delete()
            .eq("post_id", value: postID.lower).eq("user_id", value: try me.lower).execute()
    }

    func stats(for userID: UUID) async throws -> ProfileStats {
        struct Row: Decodable { let likes: Int; let saves: Int; let friends: Int }
        let rows: [Row] = try await client.rpc("profile_stats", params: ["target": userID.lower]).execute().value
        guard let r = rows.first else { return ProfileStats() }
        return ProfileStats(likes: r.likes, saves: r.saves, friends: r.friends)
    }

    // MARK: comments

    func comments(on postID: UUID) async throws -> [Comment] {
        struct Row: Decodable {
            let id: UUID; let post_id: UUID; let body: String; let created_at: Date
            let author: ProfileLite
        }
        let rows: [Row] = try await client.from("comments")
            .select("id, post_id, body, created_at, author:profiles(\(Self.lite))")
            .eq("post_id", value: postID.lower)
            .order("created_at").limit(200)
            .execute().value
        let authors = try await people(rows.map(\.author))
        return zip(rows, authors).map { row, person in
            Comment(id: row.id, postID: row.post_id, author: person, text: row.body, createdAt: row.created_at)
        }
    }

    func addComment(_ comment: Comment) async throws {
        struct New: Encodable { let id: UUID; let post_id: UUID; let body: String }
        do {
            try await client.from("comments")
                .insert(New(id: comment.id, post_id: comment.postID, body: comment.text)).execute()
        } catch let error as PostgrestError where error.message.contains("not_nice") {
            throw CommentRules.Problem.notNice     // the database's filter caught it
        } catch let error as PostgrestError where error.message.contains("slow_down") {
            throw CommentRules.Problem.slowDown
        }
    }

    func deleteComment(_ id: UUID) async throws {
        try await client.from("comments").delete().eq("id", value: id.lower).execute()
    }

    // MARK: notifications

    func savePushToken(_ token: String, sandbox: Bool) async throws {
        struct Row: Encodable { let token: String; let user_id: UUID; let sandbox: Bool; let updated_at: Date }
        try await client.from("push_tokens")
            .upsert(Row(token: token, user_id: try me, sandbox: sandbox, updated_at: Date()), onConflict: "token")
            .execute()
    }

    func mutes() async throws -> Set<UUID> {
        struct Row: Decodable { let friend_id: UUID }
        let rows: [Row] = try await client.from("post_mutes").select("friend_id").execute().value
        return Set(rows.map(\.friend_id))
    }

    func setMuted(_ friendID: UUID, muted: Bool) async throws {
        if muted {
            struct New: Encodable { let friend_id: UUID }
            do { try await client.from("post_mutes").insert(New(friend_id: friendID)).execute() }
            catch where isUniqueViolation(error) {}
        } else {
            try await client.from("post_mutes").delete().eq("friend_id", value: friendID.lower).execute()
        }
    }

    func setNotifyRequests(_ on: Bool) async throws {
        try await client.from("profiles").update(["notify_requests": on]).eq("id", value: try me.lower).execute()
    }

    func notify(_ kind: String, id: UUID) async {
        let key = kind == "post" ? "post_id" : (kind == "comment" ? "comment_id" : "to")
        do {
            try await client.functions.invoke("notify", options: FunctionInvokeOptions(body: ["type": kind, key: id.lower]))
        } catch {
            print("[phodo] notify \(kind) failed: \(error)")   // a missed push shouldn't break posting
        }
    }

    // MARK: safety

    func report(post: UUID?, user: UUID, reason: String) async throws {
        struct New: Encodable { let post_id: UUID?; let user_id: UUID; let reason: String }
        try await client.from("reports").insert(New(post_id: post, user_id: user, reason: reason)).execute()
    }

    func block(_ id: UUID) async throws {
        struct New: Encodable { let blocked: UUID }
        do {
            try await client.from("blocks").insert(New(blocked: id)).execute()
        } catch where isUniqueViolation(error) {}
    }
}

// MARK: - Mock (demo mode)

@MainActor
final class MockSocialService: SocialService {
    private var conns: [Connection]
    private var boardList: [Board] = []

    init(seed: Bool = true) {
        conns = seed ? SampleData.friends.map { Connection(person: $0, status: .friends) }
            + [Connection(person: SampleData.strangers[0], status: .incoming)] : []
    }

    func connections() async throws -> [Connection] { conns }

    func search(_ query: String) async throws -> [Person] {
        let q = Username.clean(query)
        guard !q.isEmpty else { return [] }
        return (SampleData.friends + SampleData.strangers).filter { $0.username.hasPrefix(q) }
    }

    func suggestions() async throws -> [Suggestion] {
        let taken = Set(conns.map(\.id))
        return SampleData.strangers.enumerated()
            .filter { !taken.contains($0.element.id) }
            .map { Suggestion(person: $0.element, mutual: max(1, 3 - $0.offset)) }
    }

    func request(_ id: UUID) async throws {
        guard !conns.contains(where: { $0.id == id }),
              let p = (SampleData.friends + SampleData.strangers).first(where: { $0.id == id }) else { return }
        conns.append(Connection(person: p, status: .outgoing))
    }

    func accept(_ id: UUID) async throws {
        if let i = conns.firstIndex(where: { $0.id == id }) { conns[i].status = .friends }
    }

    func remove(_ id: UUID) async throws { conns.removeAll { $0.id == id } }

    private var liked: Set<UUID> = []

    func boards(of userID: UUID) async throws -> [Board] { boardList }

    func setBoardPublic(_ id: UUID, _ isPublic: Bool) async throws {
        if let i = boardList.firstIndex(where: { $0.id == id }) { boardList[i].isPublic = isPublic }
    }

    func likes(on postIDs: [UUID]) async throws -> (mine: Set<UUID>, counts: [UUID: Int]) {
        (liked.intersection(postIDs), [:])
    }
    func like(_ postID: UUID) async throws { liked.insert(postID) }
    func unlike(_ postID: UUID) async throws { liked.remove(postID) }
    func stats(for userID: UUID) async throws -> ProfileStats {
        ProfileStats(likes: 12, saves: 4, friends: conns.filter { $0.status == .friends }.count)
    }

    func createBoard(named name: String) async throws -> Board {
        let b = Board(id: UUID(), name: name, postIDs: [])
        boardList.append(b)
        return b
    }

    func renameBoard(_ id: UUID, to name: String) async throws {
        if let i = boardList.firstIndex(where: { $0.id == id }) { boardList[i].name = name }
    }

    func deleteBoard(_ id: UUID) async throws { boardList.removeAll { $0.id == id } }

    func save(_ postID: UUID, to boardID: UUID) async throws {
        if let i = boardList.firstIndex(where: { $0.id == boardID }), !boardList[i].postIDs.contains(postID) {
            boardList[i].postIDs.insert(postID, at: 0)
        }
    }

    func unsave(_ postID: UUID, from boardID: UUID) async throws {
        if let i = boardList.firstIndex(where: { $0.id == boardID }) { boardList[i].postIDs.removeAll { $0 == postID } }
    }

    private var commentsByPost: [UUID: [Comment]] = [:]
    func comments(on postID: UUID) async throws -> [Comment] {
        if let c = commentsByPost[postID] { return c }
        // a little something on demo posts so the sheet isn't empty
        let seeded = [Comment(id: UUID(), postID: postID, author: SampleData.friends[0], text: "awww so cute",
                              createdAt: Date().addingTimeInterval(-3600)),
                      Comment(id: UUID(), postID: postID, author: SampleData.friends[3], text: "the vibes!!",
                              createdAt: Date().addingTimeInterval(-600))]
        commentsByPost[postID] = seeded
        return seeded
    }
    func addComment(_ comment: Comment) async throws {
        if CommentRules.isFlagged(comment.text) { throw CommentRules.Problem.notNice }
        commentsByPost[comment.postID, default: []].append(comment)
    }
    func deleteComment(_ id: UUID) async throws {
        for k in commentsByPost.keys { commentsByPost[k]?.removeAll { $0.id == id } }
    }

    private var muted: Set<UUID> = []
    func savePushToken(_ token: String, sandbox: Bool) async throws {}
    func mutes() async throws -> Set<UUID> { muted }
    func setMuted(_ friendID: UUID, muted on: Bool) async throws {
        if on { muted.insert(friendID) } else { muted.remove(friendID) }
    }
    func setNotifyRequests(_ on: Bool) async throws {}
    func notify(_ kind: String, id: UUID) async {}

    func report(post: UUID?, user: UUID, reason: String) async throws {}
    func block(_ id: UUID) async throws { conns.removeAll { $0.id == id } }
}
