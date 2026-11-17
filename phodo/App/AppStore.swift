import SwiftUI
import UserNotifications

/// App-wide state. Screens read from here and call its methods; it talks to the
/// backend through `AccountService`, `PostService` and `SocialService`
/// (Supabase if configured, otherwise in-memory mocks).
@MainActor
@Observable
final class AppStore {
    enum Phase: Equatable {
        case loading       // checking for a saved session
        case signedOut     // → AuthView
        case needsProfile  // signed in, no username yet → OnboardingView
        case ready         // → tabs
    }

    var phase: Phase = .loading
    var me: Person
    var myPosts: [Post] = []
    var feed: [Post] = []          // friends, last 24h
    var explore: [Post] = []       // "everyone" posts
    var connections: [Connection] = []
    var boards: [Board] = []
    private var boardPosts: [UUID: Post] = [:]   // saved posts not already loaded elsewhere
    var loadError: String?

    private(set) var themeID: String
    private(set) var reminderTime: Date?

    let isLive: Bool
    private let account: AccountService
    private let service: PostService
    private let social: SocialService
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        me = SampleData.me
        if let client = Backend.client {
            isLive = true
            account = SupabaseAccountService(client: client)
            service = SupabasePostService(client: client)
            social = SupabaseSocialService(client: client)
        } else {
            isLive = false
            account = MockAccountService()
            service = MockPostService(me: SampleData.me)
            social = MockSocialService()
        }
        themeID = defaults.string(forKey: "themeID") ?? ThemePreset.lavender.id
        reminderTime = defaults.object(forKey: "reminderTime") as? Date
    }

    var theme: ThemePreset { ThemePreset.find(themeID) }
    var todaysPosts: [Post] { myPosts.filter { $0.day == .today } }
    var daysPosted: Int { Set(myPosts.map(\.day)).count }
    var friends: [Connection] { connections.filter { $0.status == .friends } }
    var incoming: [Connection] { connections.filter { $0.status == .incoming } }

    /// Your own tags (most recent first), topped up with everyday starters.
    var recentTags: [String] {
        var seen = Set<String>()
        return (myPosts.flatMap(\.tags) + SampleData.starterTags).filter { seen.insert($0).inserted }
    }

    func status(of id: UUID) -> FriendStatus? { connections.first { $0.id == id }?.status }

    // MARK: session

    /// Called once at launch.
    func start() async {
        guard let uid = await account.restore() else { phase = .signedOut; return }
        await enter(uid)
    }

    func sendCode(to email: String) async throws {
        try await account.sendCode(to: email.trimmingCharacters(in: .whitespaces).lowercased())
    }

    func verify(email: String, code: String) async throws {
        let uid = try await account.verify(email: email.trimmingCharacters(in: .whitespaces).lowercased(),
                                           code: code.filter(\.isNumber))
        await enter(uid)
    }

    /// Called when the email sign-in link opens the app.
    func handleLink(_ url: URL) async {
        guard phase == .signedOut || phase == .loading else { return }
        do {
            await enter(try await account.handle(link: url))
        } catch {
            loadError = "that link didn't work — it may have expired. send a new one"
            phase = .signedOut
        }
    }

    private func enter(_ uid: UUID) async {
        do {
            if let profile = try await account.profile(uid) {
                me = profile
                applyTheme(profile.theme)
                phase = .ready
                await load()
            } else {
                me = Person(id: uid, username: "", displayName: "")
                phase = .needsProfile
            }
        } catch {
            loadError = error.localizedDescription
            phase = .signedOut
        }
    }

    // MARK: profile

    func isAvailable(_ username: String) async -> Bool? {
        try? await account.isAvailable(username: username)
    }

    /// Onboarding step 1: reserve the username. Throws if taken / invalid / under 13.
    func claimProfile(username raw: String, displayName: String, birthday: Date) async throws {
        let username = Username.clean(raw)
        guard Username.isValid(username) else { throw AccountError.badUsername }
        guard Age.isAtLeast13(birthday: birthday) else { throw AccountError.tooYoung }
        var p = me
        p.username = username
        p.displayName = displayName.isEmpty ? username : displayName
        p.theme = themeID
        try await account.createProfile(p)
        me = p
    }

    func finishOnboarding() async {
        await saveProfile()
        phase = .ready
        await load()
    }

    func saveProfile() async {
        me.theme = themeID
        try? await account.updateProfile(me)
    }

    /// `jpeg` should already be square and small (see ProfileView).
    func setAvatar(_ jpeg: Data) async throws {
        me = try await account.setAvatar(jpeg, for: me)
    }

    func signOut() async {
        try? await account.signOut()
        reset()
    }

    func deleteAccount() async throws {
        try await account.deleteAccount()
        reset()
    }

    private func reset() {
        myPosts = []; feed = []; explore = []; connections = []; boards = []; boardPosts = [:]
        me = SampleData.me
        phase = .signedOut
    }

    // MARK: loading

    func load() async {
        do {
            async let mine = service.myPosts(me)
            async let conns = social.connections()
            async let bs = social.boards()
            myPosts = try await mine
            connections = try await conns
            boards = try await bs
            try await refreshFeeds()
            await loadBoardPosts()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func refreshFeeds() async throws {
        feed = try await service.feed(from: friends.map(\.id), since: Date().addingTimeInterval(-24 * 3600))
        explore = try await service.explore()
    }

    private func loadBoardPosts() async {
        let known = Set((myPosts + feed + explore).map(\.id)).union(boardPosts.keys)
        let missing = Array(Set(boards.flatMap(\.postIDs)).subtracting(known))
        guard !missing.isEmpty, let found = try? await service.posts(ids: missing) else { return }
        for p in found { boardPosts[p.id] = p }
    }

    // MARK: posts

    func publish(_ draft: PostDraft) async throws {
        let post = try await service.createPost(draft, by: me)
        myPosts.append(post)
        myPosts.sort { ($0.day, $0.createdAt) > ($1.day, $1.createdAt) }
    }

    func deletePost(_ post: Post) async {
        try? await service.deletePost(post.id)
        myPosts.removeAll { $0.id == post.id }
        for i in boards.indices { boards[i].postIDs.removeAll { $0 == post.id } }
    }

    func post(_ id: UUID) -> Post? {
        myPosts.first { $0.id == id } ?? feed.first { $0.id == id }
            ?? explore.first { $0.id == id } ?? boardPosts[id]
    }

    // MARK: friends

    func search(_ query: String) async -> [Person] {
        (try? await social.search(query)) ?? []
    }

    /// "add": accepts instead if they already asked you.
    func addFriend(_ person: Person) async {
        if status(of: person.id) == .incoming {
            await accept(person.id)
            return
        }
        try? await social.request(person.id)
        if status(of: person.id) == nil { connections.append(Connection(person: person, status: .outgoing)) }
    }

    func accept(_ id: UUID) async {
        try? await social.accept(id)
        if let i = connections.firstIndex(where: { $0.id == id }) { connections[i].status = .friends }
        try? await refreshFeeds()
    }

    func removeConnection(_ id: UUID) async {
        try? await social.remove(id)
        connections.removeAll { $0.id == id }
        feed.removeAll { $0.author.id == id }
    }

    // MARK: safety

    func report(_ post: Post, reason: String) async {
        try? await social.report(post: post.id, user: post.author.id, reason: reason)
    }

    func block(_ person: Person) async {
        try? await social.block(person.id)
        connections.removeAll { $0.id == person.id }
        feed.removeAll { $0.author.id == person.id }
        explore.removeAll { $0.author.id == person.id }
    }

    // MARK: boards

    func isSaved(_ postID: UUID) -> Bool { boards.contains { $0.postIDs.contains(postID) } }

    func toggle(_ postID: UUID, in boardID: UUID) async {
        guard let i = boards.firstIndex(where: { $0.id == boardID }) else { return }
        if let j = boards[i].postIDs.firstIndex(of: postID) {
            boards[i].postIDs.remove(at: j)
            try? await social.unsave(postID, from: boardID)
        } else {
            boards[i].postIDs.insert(postID, at: 0)
            try? await social.save(postID, to: boardID)
        }
    }

    @discardableResult
    func createBoard(named name: String) async -> Board? {
        let clean = name.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard !clean.isEmpty, let board = try? await social.createBoard(named: clean) else { return nil }
        boards.append(board)
        return board
    }

    func renameBoard(_ id: UUID, to name: String) async {
        let clean = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let i = boards.firstIndex(where: { $0.id == id }) else { return }
        boards[i].name = clean
        try? await social.renameBoard(id, to: clean)
    }

    func deleteBoard(_ id: UUID) async {
        boards.removeAll { $0.id == id }
        try? await social.deleteBoard(id)
    }

    // MARK: preferences

    func setTheme(_ preset: ThemePreset) {
        applyTheme(preset.id)
        if phase == .ready { Task { await saveProfile() } }
    }

    private func applyTheme(_ id: String) {
        themeID = ThemePreset.find(id).id
        defaults.set(themeID, forKey: "themeID")
    }

    /// Daily reminder = a local notification. No server needed.
    func setReminder(_ time: Date?) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["daily"])
        reminderTime = time
        defaults.set(time, forKey: "reminderTime")
        guard let time else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }

        let content = UNMutableNotificationContent()
        content.title = "phodo"
        content.body = "what's today's pic? (words are fine too)"
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: "daily", content: content, trigger: trigger))
    }
}
