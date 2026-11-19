import SwiftUI

/// "12 ♥ · 4 saves · 6 friends" — totals only, never who.
struct StatsRow: View {
    @Environment(\.theme) private var theme
    let stats: ProfileStats

    var body: some View {
        HStack(spacing: 18) {
            stat("\(stats.likes)", "♥ loves")
            stat("\(stats.saves)", stats.saves == 1 ? "save" : "saves")
            stat("\(stats.friends)", stats.friends == 1 ? "friend" : "friends")
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(_ number: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(number).font(PhFont.bold(20)).foregroundStyle(theme.ink)
            Text(label).font(PhFont.mono(13)).foregroundStyle(theme.softInk)
        }
    }
}

/// Someone else's profile: what you're allowed to see of their posts,
/// their public boards, totals, and add / accept friend.
struct PersonProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let person: Person
    @State private var full: Person?
    @State private var posts: [Post] = []
    @State private var boards: [Board] = []
    @State private var boardPosts: [UUID: Post] = [:]
    @State private var stats = ProfileStats()
    @State private var mode = 0              // 0 pics, 1 boards
    @State private var selectedBoard: UUID?
    @State private var loading = true

    private var shown: Person { full ?? person }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Spacer()
                    Button("done") { dismiss() }.font(PhFont.bold(17))
                }
                HStack(spacing: 16) {
                    Avatar(person: shown, size: 76)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("@\(shown.username)").font(PhFont.title(30)).lineLimit(1).minimumScaleFactor(0.6)
                        if !shown.displayName.isEmpty { Text(shown.displayName).font(PhFont.body(18)) }
                        if !shown.location.isEmpty {
                            Text(shown.location).font(PhFont.mono(13)).foregroundStyle(theme.softInk)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if !shown.bio.isEmpty { Text(shown.bio).font(PhFont.body(19)) }
                StatsRow(stats: stats)

                HStack(spacing: 12) {
                    friendButton
                    if store.status(of: person.id) == .friends { BellButton(person: shown) }
                    PillToggle(options: ["pics", "scrapbooks"], selection: $mode)
                }
                if store.status(of: person.id) == .friends {
                    Text(store.hasBell(person.id)
                         ? "you'll get a ping when @\(shown.username) posts"
                         : "pings off for @\(shown.username). tap 🔔 to turn back on")
                        .font(PhFont.mono(12)).foregroundStyle(theme.softInk)
                }
                InkLine()

                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if mode == 0 {
                    if posts.isEmpty {
                        Text(store.status(of: person.id) == .friends
                             ? "nothing posted yet"
                             : "add @\(shown.username) to see their friends-only posts")
                            .font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                    } else {
                        Masonry(items: posts, weight: { ($0.hasPhoto ? $0.aspect : 0.2) + 0.35 }) { post in
                            PostCard(post: post, showDate: true)
                        }
                    }
                } else {
                    boardsSection
                }
            }
            .foregroundStyle(theme.ink)
            .padding(.top, 20).padding(.bottom, 24)
        }
        .phodoPage()
        .holdMenuHost()
        .task { await load() }
    }

    @ViewBuilder
    private var friendButton: some View {
        switch store.status(of: person.id) {
        case nil:
            Button("add friend") { Task { await store.addFriend(shown) } }.buttonStyle(PrimaryButtonStyle())
        case .outgoing:
            Button("requested") { Task { await store.removeConnection(person.id) } }.buttonStyle(OutlineButtonStyle())
        case .incoming:
            Button("accept") { Task { await store.accept(person.id); await load() } }.buttonStyle(PrimaryButtonStyle())
        case .friends:
            Menu {
                Button("remove friend", role: .destructive) { Task { await store.removeConnection(person.id) } }
            } label: { Text("friends ✓").frame(maxWidth: .infinity) }
            .buttonStyle(OutlineButtonStyle())
        }
    }

    @ViewBuilder
    private var boardsSection: some View {
        if boards.isEmpty {
            Text("no public scrapbooks").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
        } else {
            let board = boards.first { $0.id == selectedBoard } ?? boards[0]
            let items = board.postIDs.compactMap { boardPosts[$0] }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(boards) { b in
                        Button { selectedBoard = b.id } label: { TagChip(text: "#\(b.name)", selected: b.id == board.id) }
                            .buttonStyle(SquishStyle())
                    }
                }
                .padding(1)
            }
            if items.isEmpty {
                Text("nothing you can see in here yet").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
            } else {
                Masonry(items: items, weight: { ($0.hasPhoto ? $0.aspect : 0.2) + 0.4 }) { post in
                    PostCard(post: post, showAuthor: true)
                }
            }
        }
    }

    private func load() async {
        async let f = store.profile(of: person.id)
        async let p = store.posts(by: person.id)
        async let b = store.publicBoards(of: person.id)
        async let s = store.stats(for: person.id)
        full = await f
        posts = await p
        boards = await b
        stats = await s
        // posts inside their public boards (only the ones I'm allowed to see come back)
        let saved = await store.posts(ids: Array(Set(boards.flatMap(\.postIDs))))
        boardPosts = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        await store.noteLikes(for: posts + saved)
        loading = false
    }
}
