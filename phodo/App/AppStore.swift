import SwiftUI
import UserNotifications

/// App-wide state. Screens read from here and call its methods; it talks to the
/// backend through `AccountService` + `PostService` (Supabase if configured,
/// otherwise in-memory mocks).
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
    var feed: [Post] = []
    var boards: [Board] = []
    var recentTags: [String] = SampleData.recentTags
    var loadError: String?

    private(set) var themeID: String
    private(set) var reminderTime: Date?

    let isLive: Bool
    private let account: AccountService
    private let service: PostService
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        me = SampleData.me
        if let client = Backend.client {
            isLive = true
            account = SupabaseAccountService(client: client)
            service = SupabasePostService(client: client)
        } else {
            isLive = false
            account = MockAccountService()
            service = MockPostService(me: SampleData.me)
        }
        themeID = defaults.string(forKey: "themeID") ?? ThemePreset.lavender.id
        reminderTime = defaults.object(forKey: "reminderTime") as? Date
    }

    var theme: ThemePreset { ThemePreset.find(themeID) }
    var todaysPost: Post? { myPosts.first { $0.day == .today } }
    var daysPosted: Int { Set(myPosts.map(\.day)).count }

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

    func signOut() async {
        try? await account.signOut()
        reset()
    }

    func deleteAccount() async throws {
        try await account.deleteAccount()
        reset()
    }

    private func reset() {
        myPosts = []; feed = []; boards = []
        me = SampleData.me
        phase = .signedOut
    }

    // MARK: posts

    func load() async {
        do {
            myPosts = try await service.myPosts(me)
            feed = try await service.friendsFeed(on: .today)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        if boards.isEmpty {
            // Boards are still local-only (not in Supabase yet).
            let saved = isLive ? [] : Array(feed.prefix(3).map(\.id)) + Array(myPosts.prefix(3).map(\.id))
            boards = [Board(id: UUID(), name: "fall", postIDs: saved),
                      Board(id: UUID(), name: "food", postIDs: []),
                      Board(id: UUID(), name: "sunsets", postIDs: [])]
        }
    }

    func publish(_ draft: PostDraft) async throws {
        let post = try await service.createPost(draft, by: me, on: .today)
        myPosts.insert(post, at: 0)
        for tag in draft.tags where !recentTags.contains(tag) { recentTags.insert(tag, at: 0) }
    }

    func deletePost(_ post: Post) async {
        try? await service.deletePost(post.id)
        myPosts.removeAll { $0.id == post.id }
        for i in boards.indices { boards[i].postIDs.removeAll { $0 == post.id } }
    }

    // MARK: boards

    func post(_ id: UUID) -> Post? {
        myPosts.first { $0.id == id } ?? feed.first { $0.id == id }
    }

    func toggle(_ postID: UUID, in boardID: UUID) {
        guard let i = boards.firstIndex(where: { $0.id == boardID }) else { return }
        if let j = boards[i].postIDs.firstIndex(of: postID) {
            boards[i].postIDs.remove(at: j)
        } else {
            boards[i].postIDs.insert(postID, at: 0)
        }
    }

    func isSaved(_ postID: UUID) -> Bool { boards.contains { $0.postIDs.contains(postID) } }

    @discardableResult
    func createBoard(named name: String) -> Board? {
        let clean = name.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard !clean.isEmpty else { return nil }
        let board = Board(id: UUID(), name: clean, postIDs: [])
        boards.append(board)
        return board
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
