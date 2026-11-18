import Supabase
import SwiftUI

enum AccountError: LocalizedError, Equatable {
    case usernameTaken
    case badUsername
    case tooYoung
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .usernameTaken: "that username's taken — try another"
        case .badUsername: "2–24 characters: letters, numbers, _ or ."
        case .tooYoung: "phodo is for ages 13 and up"
        case .notSignedIn: "you're signed out — sign in again"
        }
    }
}

enum Username {
    /// Lowercase and drop anything that isn't allowed.
    static func clean(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
            .filter { $0.isASCII }
    }
    static func isValid(_ name: String) -> Bool { (2...24).contains(name.count) && name == clean(name) }
}

enum Age {
    static func isAtLeast13(birthday: Date, now: Date = Date()) -> Bool {
        guard let years = Calendar.current.dateComponents([.year], from: birthday, to: now).year else { return false }
        return years >= 13
    }
}

/// Sign-in + profile. Same swap-in pattern as `PostService`.
@MainActor
protocol AccountService {
    /// The signed-in user from the saved session, if any.
    func restore() async -> UUID?
    func sendCode(to email: String) async throws
    func verify(email: String, code: String) async throws -> UUID
    /// Password sign-in. Only used for Apple's App Review account (they can't read our emails).
    func signIn(email: String, password: String) async throws -> UUID
    /// The sign-in link from the email opened phodo (phodo://login-callback?...).
    func handle(link: URL) async throws -> UUID
    /// nil = signed in but hasn't claimed a username yet.
    func profile(_ id: UUID) async throws -> Person?
    func isAvailable(username: String) async throws -> Bool
    func createProfile(_ person: Person) async throws
    func updateProfile(_ person: Person) async throws
    /// Uploads a square JPEG as the profile picture; returns the updated person.
    func setAvatar(_ jpeg: Data, for person: Person) async throws -> Person
    func signOut() async throws
    /// Deletes photos, then the account (posts, friends, boards cascade).
    func deleteAccount() async throws
}

// MARK: - Supabase

@MainActor
final class SupabaseAccountService: AccountService {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    private struct ProfileRow: Codable {
        let id: UUID
        var username: String
        var display_name: String
        var bio: String
        var location: String
        var theme: String
        var is_13_plus: Bool?
        var avatar_path: String?
        var notify_requests: Bool?
    }

    private struct IDRow: Decodable { let id: UUID }
    private struct PathRow: Decodable { let image_path: String?; let thumb_path: String? }

    func restore() async -> UUID? {
        try? await client.auth.session.user.id
    }

    static let redirect = URL(string: "phodo://login-callback")!

    /// Emails a sign-in link (and a code, once custom SMTP + templates are set up).
    func sendCode(to email: String) async throws {
        try await client.auth.signInWithOTP(email: email, redirectTo: Self.redirect, shouldCreateUser: true)
    }

    func verify(email: String, code: String) async throws -> UUID {
        try await client.auth.verifyOTP(email: email, token: code, type: .email).user.id
    }

    func handle(link: URL) async throws -> UUID {
        try await client.auth.session(from: link).user.id
    }

    func signIn(email: String, password: String) async throws -> UUID {
        try await client.auth.signIn(email: email, password: password).user.id
    }

    func profile(_ id: UUID) async throws -> Person? {
        let rows: [ProfileRow] = try await client.from("profiles").select().eq("id", value: id).execute().value
        guard let r = rows.first else { return nil }
        var p = Person(id: r.id, username: r.username, displayName: r.display_name,
                       bio: r.bio, location: r.location, theme: r.theme)
        p.avatarPath = r.avatar_path
        p.notifyRequests = r.notify_requests ?? true
        if let path = r.avatar_path {
            p.avatarURL = try? await Signer.sign(client, bucket: "avatars", paths: [path])[path]
        }
        return p
    }

    func isAvailable(username: String) async throws -> Bool {
        let rows: [IDRow] = try await client.from("profiles").select("id")
            .eq("username", value: username).limit(1).execute().value
        return rows.isEmpty
    }

    func createProfile(_ p: Person) async throws {
        do {
            try await client.from("profiles").insert(row(p, adult: true)).execute()
        } catch where isUniqueViolation(error) {
            throw AccountError.usernameTaken
        }
    }

    func updateProfile(_ p: Person) async throws {
        try await client.from("profiles").update(row(p, adult: nil)).eq("id", value: p.id).execute()
    }

    func setAvatar(_ jpeg: Data, for person: Person) async throws -> Person {
        // New file name each time, so cached old pictures never show up.
        let path = "\(person.id.lower)/avatar-\(Int(Date().timeIntervalSince1970)).jpg"
        _ = try await client.storage.from("avatars").upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg"))
        var p = person
        let old = p.avatarPath
        p.avatarPath = path
        try await updateProfile(p)
        if let old { _ = try? await client.storage.from("avatars").remove(paths: [old]) }
        p.avatarURL = try await Signer.sign(client, bucket: "avatars", paths: [path])[path]
        return p
    }

    func signOut() async throws { try await client.auth.signOut() }

    func deleteAccount() async throws {
        guard let uid = try? await client.auth.session.user.id else { throw AccountError.notSignedIn }
        // 1. photos (storage files can't be removed from SQL)
        let rows: [PathRow] = try await client.from("posts").select("image_path, thumb_path")
            .eq("user_id", value: uid).execute().value
        let paths = rows.flatMap { [$0.image_path, $0.thumb_path] }.compactMap { $0 }
        if !paths.isEmpty { _ = try await client.storage.from("posts").remove(paths: paths) }
        let avatars = (try? await client.storage.from("avatars").list(path: uid.lower)) ?? []
        if !avatars.isEmpty {
            _ = try? await client.storage.from("avatars").remove(paths: avatars.map { "\(uid.lower)/\($0.name)" })
        }
        // 2. the account itself; profile/posts/friends/boards cascade
        try await client.rpc("delete_my_account").execute()
        try? await client.auth.signOut()
    }

    private func row(_ p: Person, adult: Bool?) -> ProfileRow {
        ProfileRow(id: p.id, username: p.username, display_name: p.displayName,
                   bio: p.bio, location: p.location, theme: p.theme, is_13_plus: adult, avatar_path: p.avatarPath)
    }
}

// MARK: - Mock (no backend configured)

/// Any email works, any 6-digit code works, and "maya"/"leo"/… are taken.
@MainActor
final class MockAccountService: AccountService {
    private var profiles: [UUID: Person] = [:]
    private var taken: Set<String> = Set(SampleData.friends.map(\.username))

    func restore() async -> UUID? { nil }
    func sendCode(to email: String) async throws { try await Task.sleep(for: .milliseconds(400)) }
    func verify(email: String, code: String) async throws -> UUID {
        try await Task.sleep(for: .milliseconds(400))
        return UUID()
    }
    func handle(link: URL) async throws -> UUID { UUID() }
    func signIn(email: String, password: String) async throws -> UUID { UUID() }
    func profile(_ id: UUID) async throws -> Person? { profiles[id] }
    func isAvailable(username: String) async throws -> Bool { !taken.contains(username) }
    func createProfile(_ p: Person) async throws {
        guard !taken.contains(p.username) else { throw AccountError.usernameTaken }
        taken.insert(p.username)
        profiles[p.id] = p
    }
    func updateProfile(_ p: Person) async throws { profiles[p.id] = p }
    func setAvatar(_ jpeg: Data, for person: Person) async throws -> Person {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-\(UUID().uuidString).jpg")
        try jpeg.write(to: url)
        var p = person
        p.avatarPath = url.lastPathComponent
        p.avatarURL = url
        profiles[p.id] = p
        return p
    }
    func signOut() async throws {}
    func deleteAccount() async throws {}
}
