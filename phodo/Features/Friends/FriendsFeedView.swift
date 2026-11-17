import SwiftUI

/// Tab 1: your friends' posts from the last day, or explore (posts shared with "everyone").
struct FriendsFeedView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @AppStorage("feedMode") private var mode = 0   // 0 friends, 1 explore
    @State private var showFriends = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ScreenHeader(title: mode == 0 ? "friends" : "explore",
                             trailing: mode == 0 && !store.feed.isEmpty ? "\(store.feed.count) new" : "")

                HStack(spacing: 10) {
                    PillToggle(options: ["friends", "explore"], selection: $mode)
                    Spacer(minLength: 0)
                    Button { showFriends = true } label: {
                        TagChip(text: store.incoming.isEmpty ? "+ add" : "\(store.incoming.count) new ✦",
                                selected: !store.incoming.isEmpty)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(store.incoming.isEmpty ? "find friends" : "\(store.incoming.count) friend requests")
                }

                if mode == 0 { friendsFeed } else { exploreFeed }
            }
            .foregroundStyle(theme.ink)
            .padding(.top, 12).padding(.bottom, 24)
        }
        .refreshable { await Task { await store.load() }.value }   // own task: SwiftUI cancels refresh tasks when the screen updates mid-refresh
        .phodoPage()
        .sheet(isPresented: $showFriends) {
            FriendFinder().environment(\.theme, theme).presentationDetents([.large])
        }
    }

    @ViewBuilder
    private var friendsFeed: some View {
        if store.friends.isEmpty {
            emptyState(title: "it's quiet in here", note: "phodo is better with your people",
                       button: "find friends") { showFriends = true }
        } else if store.feed.isEmpty {
            emptyState(title: "no one's posted yet", note: "you go first ✌︎", button: nil) {}
        } else {
            Masonry(items: store.feed, weight: { ($0.hasPhoto ? $0.aspect : 0.2) + 0.45 }) { post in
                PostCard(post: post, showAuthor: true)
            }
            endNote("that's everyone ✌︎", "go touch grass")
        }
    }

    @ViewBuilder
    private var exploreFeed: some View {
        if store.explore.isEmpty {
            emptyState(title: "nothing to explore yet",
                       note: "posts people share with \"everyone\" show up here", button: nil) {}
        } else {
            Masonry(items: store.explore, weight: { ($0.hasPhoto ? $0.aspect : 0.2) + 0.45 }) { post in
                PostCard(post: post, showAuthor: true)
            }
            endNote("that's all for now", "hold a post to save it or add someone")
        }
    }

    private func emptyState(title: String, note: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(PhFont.bold(24))
            Text(note).font(PhFont.mono(14)).foregroundStyle(theme.softInk)
            if let button {
                Button(button, action: action).buttonStyle(PrimaryButtonStyle()).padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func endNote(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            InkLine()
            Text(title).font(PhFont.bold(24)).padding(.top, 10)
            Text(note).font(PhFont.mono(14)).foregroundStyle(theme.softInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Search by @username, answer requests, see your friends, invite people.
struct FriendFinder: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Person] = []
    @State private var searching = false
    @State private var viewing: Person?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("your people").font(PhFont.title(34))
                    Spacer()
                    Button("done") { dismiss() }.font(PhFont.bold(17))
                }

                VStack(spacing: 8) {
                    HStack {
                        Text("@").font(PhFont.body(20)).foregroundStyle(theme.softInk)
                        TextField("", text: $query, prompt: Text("find by username").foregroundStyle(theme.softInk.opacity(0.7)))
                            .font(PhFont.body(20)).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if searching { ProgressView() }
                    }
                    InkLine()
                }
                .task(id: query) { await runSearch() }

                if !query.isEmpty {
                    if results.isEmpty && !searching {
                        Text("no one called @\(Username.clean(query)) yet").font(PhFont.mono(13)).foregroundStyle(theme.softInk)
                    }
                    ForEach(results) { person in row(person) }
                }

                if !store.incoming.isEmpty {
                    FieldLabel("asked to be friends")
                    ForEach(store.incoming) { c in row(c.person) }
                }

                FieldLabel("friends · \(store.friends.count)")
                if store.friends.isEmpty {
                    Text("no friends yet. search above or send an invite")
                        .font(PhFont.mono(13)).foregroundStyle(theme.softInk)
                }
                ForEach(store.friends) { c in row(c.person) }

                let waiting = store.connections.filter { $0.status == .outgoing }
                if !waiting.isEmpty {
                    FieldLabel("waiting on them")
                    ForEach(waiting) { c in row(c.person) }
                }

                InkLine()
                ShareLink(item: URL(string: "https://phodo.app")!,
                          message: Text("add me on phodo, i'm @\(store.me.username) 🐈 one pic a day, just for your people")) {
                    Text("invite people to phodo").frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlineButtonStyle())
            }
            .foregroundStyle(theme.ink)
            .padding(.top, 24).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .phodoPage()
        .sheet(item: $viewing) { PersonProfileView(person: $0).environment(\.theme, theme) }
    }

    private func row(_ person: Person) -> some View {
        HStack(spacing: 12) {
            Button { viewing = person } label: {
                HStack(spacing: 12) {
                    Avatar(person: person, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("@\(person.username)").font(PhFont.bold(17))
                        if !person.displayName.isEmpty && person.displayName != person.username {
                            Text(person.displayName).font(PhFont.mono(13)).foregroundStyle(theme.softInk)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            action(for: person)
        }
    }

    @ViewBuilder
    private func action(for person: Person) -> some View {
        switch store.status(of: person.id) {
        case nil:
            Button { Task { await store.addFriend(person) } } label: { TagChip(text: "add", selected: true) }
                .buttonStyle(.plain)
        case .outgoing:
            Button { Task { await store.removeConnection(person.id) } } label: { TagChip(text: "requested") }
                .buttonStyle(.plain).accessibilityHint("cancels the request")
        case .incoming:
            HStack(spacing: 6) {
                Button { Task { await store.accept(person.id) } } label: { TagChip(text: "accept", selected: true) }
                Button { Task { await store.removeConnection(person.id) } } label: { TagChip(text: "✕", dashed: true) }
                    .accessibilityLabel("decline")
            }
            .buttonStyle(.plain)
        case .friends:
            Menu {
                Button("remove friend", role: .destructive) { Task { await store.removeConnection(person.id) } }
            } label: { TagChip(text: "friends ✓") }
        }
    }

    private func runSearch() async {
        let q = Username.clean(query)
        guard !q.isEmpty else { results = []; return }
        try? await Task.sleep(for: .milliseconds(300))   // wait until they stop typing
        guard !Task.isCancelled else { return }
        searching = true
        results = await store.search(q)
        searching = false
    }
}
