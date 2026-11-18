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
    var liked: Set<UUID> = []                    // posts I've ♥'d
    var likeCounts: [UUID: Int] = [:]            // ♥ from others, on MY posts only
    var myStats = ProfileStats()
    var muted: Set<UUID> = []                    // friends whose "posted" pushes I turned off (rest are on)
    /// When I last looked at the friends feed; only posts after this count as "new".
    var feedSeenAt: Date = (UserDefaults.standard.object(forKey: "feedSeenAt") as? Date) ?? .distantPast
    var loadError: String?
    private var started = false

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

    /// Exactly 5 suggestions: the tags you used most recently, topped up with
    /// everyday starters. It never grows past 5.
    var recentTags: [String] { Self.suggestedTags(from: myPosts) }

    static func suggestedTags(from posts: [Post], limit: Int = 5) -> [String] {
        let newestFirst = posts.sorted { $0.createdAt > $1.createdAt }
        var seen = Set<String>()
        return (newestFirst.flatMap(\.tags) + SampleData.starterTags)
            .filter { seen.insert($0).inserted }
            .prefix(limit).map { $0 }
    }

    func status(of id: UUID) -> FriendStatus? { connections.first { $0.id == id }?.status }

    // MARK: session

    /// Called once at launch.
    func start() async {
        guard !started else { return }   // SwiftUI can re-run .task; only start once
        started = true
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

    /// The one account that signs in with a password: Apple's App Review.
    static let reviewEmail = "review@phodo.app"

    func signInForReview(password: String) async throws {
        await enter(try await account.signIn(email: Self.reviewEmail, password: password))
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
        liked = []; likeCounts = [:]; myStats = ProfileStats(); muted = []
        me = SampleData.me
        phase = .signedOut
    }

    // MARK: loading

    /// Loads each part separately, so one failure can't blank out the rest.
    /// Failures are printed (visible in the Xcode / device console) and shown in the app.
    func load() async {
        var problems: [String] = []
        func attempt(_ what: String, _ work: () async throws -> Void) async {
            do { try await work() } catch {
                print("[phodo] loading \(what) failed: \(error)")
                problems.append(what)
            }
        }
        await attempt("your posts") { myPosts = try await service.myPosts(me) }
        await attempt("friends") { connections = try await social.connections() }
        await attempt("boards") { boards = try await social.boards(of: me.id) }
        await attempt("feeds") { try await refreshFeeds() }
        await loadBoardPosts()
        await attempt("likes") { try await refreshLikes() }
        await attempt("stats") { myStats = try await social.stats(for: me.id) }
        await attempt("bells") { muted = try await social.mutes() }
        // friends' posts ping by default, so ask once you have someone to hear from
        if !friends.isEmpty { _ = await PushDelegate.requestAndRegister() }
        await PushDelegate.registerIfAllowed()
        loadError = problems.isEmpty ? nil : "couldn't load \(problems.joined(separator: ", ")). pull down to retry"
        print("[phodo] loaded: \(myPosts.count) posts, \(connections.count) connections, \(boards.count) boards, feed \(feed.count), explore \(explore.count)")
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
        if post.visibility != .justMe { Task { await social.notify("post", id: post.id) } }
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

    // MARK: likes

    func refreshLikes() async throws {
        let ids = Array(Set((myPosts + feed + explore + Array(boardPosts.values)).map(\.id)))
        let info = try await social.likes(on: ids)
        liked = info.mine
        likeCounts = info.counts
    }

    func isLiked(_ id: UUID) -> Bool { liked.contains(id) }

    func toggleLike(_ post: Post) async {
        if liked.contains(post.id) {
            liked.remove(post.id)
            try? await social.unlike(post.id)
        } else {
            liked.insert(post.id)
            try? await social.like(post.id)
        }
    }

    // MARK: other people

    func profile(of id: UUID) async -> Person? { try? await account.profile(id) }
    func posts(by id: UUID) async -> [Post] { (try? await service.posts(by: id)) ?? [] }
    func publicBoards(of id: UUID) async -> [Board] { (try? await social.boards(of: id))?.filter(\.isPublic) ?? [] }
    func posts(ids: [UUID]) async -> [Post] { (try? await service.posts(ids: ids)) ?? [] }
    func stats(for id: UUID) async -> ProfileStats { (try? await social.stats(for: id)) ?? ProfileStats() }

    /// Likes on posts loaded outside the main lists (someone's profile, a public board).
    func noteLikes(for posts: [Post]) async {
        guard let info = try? await social.likes(on: posts.map(\.id)) else { return }
        liked.formUnion(info.mine)
    }

    // MARK: friends

    /// Re-fetch friends + requests (they change on other people's phones).
    func refreshConnections() async {
        guard phase == .ready, let fresh = try? await social.connections() else { return }
        let hadFriends = Set(friends.map(\.id))
        connections = fresh
        if Set(friends.map(\.id)) != hadFriends { try? await refreshFeeds() }
    }

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
        Task { await social.notify("request", id: person.id) }
        // the server may have turned this into "friends" (they'd already asked me), so re-check
        await refreshConnections()
        if status(of: person.id) == nil { connections.append(Connection(person: person, status: .outgoing)) }
    }

    func accept(_ id: UUID) async {
        try? await social.accept(id)
        Task { await social.notify("accept", id: id) }
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
            do { try await social.unsave(postID, from: boardID) } catch { report("removing from board", error) }
        } else {
            boards[i].postIDs.insert(postID, at: 0)
            do { try await social.save(postID, to: boardID) } catch { report("saving to board", error) }
        }
    }

    @discardableResult
    func createBoard(named name: String) async -> Board? {
        let clean = name.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard !clean.isEmpty else { return nil }
        do {
            let board = try await social.createBoard(named: clean)
            boards.append(board)
            return board
        } catch {
            report("making a board", error)
            return nil
        }
    }

    func renameBoard(_ id: UUID, to name: String) async {
        let clean = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let i = boards.firstIndex(where: { $0.id == id }) else { return }
        boards[i].name = clean
        try? await social.renameBoard(id, to: clean)
    }

    func setBoardPublic(_ id: UUID, _ isPublic: Bool) async {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return }
        boards[i].isPublic = isPublic
        try? await social.setBoardPublic(id, isPublic)
    }

    func deleteBoard(_ id: UUID) async {
        boards.removeAll { $0.id == id }
        try? await social.deleteBoard(id)
    }

    /// Print the full error (device console) and show a short version in the app banner.
    private func report(_ what: String, _ error: Error) {
        print("[phodo] \(what) failed: \(error)")
        loadError = "\(what) didn't work: \(error.localizedDescription.lowercased())"
    }

    // MARK: notifications

    /// Called with the phone's push address from Apple.
    func savePushToken(_ token: String) async {
        guard phase == .ready else { return }
        #if DEBUG
        let sandbox = true      // Xcode installs talk to Apple's sandbox push servers
        #else
        let sandbox = false     // TestFlight / App Store
        #endif
        do { try await social.savePushToken(token, sandbox: sandbox) } catch { report("turning on notifications", error) }
    }

    /// On for every friend unless I muted them from their profile.
    func hasBell(_ id: UUID) -> Bool { status(of: id) == .friends && !muted.contains(id) }

    /// 🔔 on/off for one friend (lives on their profile).
    func toggleBell(_ id: UUID) async {
        let on = muted.contains(id)          // currently muted → turning back on
        if on {
            guard await PushDelegate.requestAndRegister() else {
                loadError = "notifications are off for phodo. turn them on in settings → phodo → notifications"
                return
            }
            muted.remove(id)
        } else {
            muted.insert(id)
        }
        do { try await social.setMuted(id, muted: !on) } catch { report("changing the bell", error) }
    }

    /// Friend posts I haven't seen yet (shown as "3 new" on the friends feed).
    var newFeedCount: Int {
        feed.filter { $0.createdAt > feedSeenAt && $0.author.id != me.id }.count
    }

    /// Called when you leave the friends feed: everything there counts as seen.
    func markFeedSeen() {
        guard let newest = feed.map(\.createdAt).max(), newest > feedSeenAt else { return }
        feedSeenAt = newest
        UserDefaults.standard.set(newest, forKey: "feedSeenAt")
    }

    func setNotifyRequests(_ on: Bool) async {
        me.notifyRequests = on
        if on { _ = await PushDelegate.requestAndRegister() }
        do { try await social.setNotifyRequests(on) } catch { report("changing notifications", error) }
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
        await PushDelegate.registerIfAllowed()   // same permission covers friend pushes

        let content = UNMutableNotificationContent()
        content.title = "phodo"
        content.body = "what's today's pic? (words are fine too)"
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: "daily", content: content, trigger: trigger))
    }
}
