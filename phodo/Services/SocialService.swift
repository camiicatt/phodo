import Supabase
import SwiftUI

/// Friends, boards, and safety (report / block).
@MainActor
protocol SocialService {
    // friends
    func connections() async throws -> [Connection]
    func search(_ query: String) async throws -> [Person]
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
        return zip(rows, persons).map { row, person in
            let status: FriendStatus = row.status == "accepted" ? .friends : (row.requester == me ? .outgoing : .incoming)
            return Connection(person: person, status: status)
        }
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

    func report(post: UUID?, user: UUID, reason: String) async throws {}
    func block(_ id: UUID) async throws { conns.removeAll { $0.id == id } }
}
