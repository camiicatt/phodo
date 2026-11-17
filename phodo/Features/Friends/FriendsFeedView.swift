import SwiftUI

/// Screen 2 — friends' posts from today in a masonry feed that ends.
struct FriendsFeedView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var saving: Post?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ScreenHeader(title: "friends", trailing: store.feed.isEmpty ? "" : "\(store.feed.count) new")

                if store.feed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("no one's posted yet").font(PhFont.bold(24))
                        Text("you go first ✌︎").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Masonry(items: store.feed, weight: { $0.aspect + 0.45 }) { post in
                        PostCard(post: post, showAuthor: true, onSave: { saving = post })
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        InkLine()
                        Text("that's everyone ✌︎").font(PhFont.bold(24)).padding(.top, 10)
                        Text("go touch grass").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                    }
                }
            }
            .foregroundStyle(theme.ink)
            .padding(.top, 12).padding(.bottom, 24)
        }
        .refreshable { await store.load() }
        .phodoPage()
        .sheet(item: $saving) { post in
            SaveToBoardSheet(post: post).environment(\.theme, theme).presentationDetents([.medium])
        }
    }
}

/// One card in a masonry grid (feed, profile pics, boards).
struct PostCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    let post: Post
    var showAuthor = false
    var showDate = false
    var onSave: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if post.hasPhoto {
                PhotoTile(image: post.image, url: post.thumbURL, tint: post.tint, aspect: post.aspect,
                          seed: post.id.hashValue)
            }
            if showAuthor || onSave != nil {
                HStack {
                    if showAuthor { Text(post.author.username).font(PhFont.bold(19)) }
                    Spacer()
                    if let onSave {
                        Button(action: onSave) {
                            Image(systemName: store.isSaved(post.id) ? "bookmark.fill" : "bookmark")
                                .font(.system(size: 18, weight: .light))
                                .frame(width: 44, height: 32, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("save to board")
                    }
                }
            }
            if !post.caption.isEmpty { Text(post.caption).font(PhFont.body(17)) }
            let meta = ([showDate ? post.day.short : nil] + post.tags.map { "#\($0)" }).compactMap { $0 }
            if !meta.isEmpty {
                Text(meta.joined(separator: showDate ? " · " : " ")).font(PhFont.mono(12)).foregroundStyle(theme.softInk)
            }
        }
        .foregroundStyle(theme.ink)
    }
}

struct SaveToBoardSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let post: Post
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("save to…").font(PhFont.title(32))
            FlowLayout(spacing: 10) {
                ForEach(store.boards) { board in
                    Button { store.toggle(post.id, in: board.id) } label: {
                        TagChip(text: "#\(board.name)", selected: board.postIDs.contains(post.id))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("new board", text: $newName).font(PhFont.mono(15)).textInputAutocapitalization(.never)
                Button("+ new") {
                    if let b = store.createBoard(named: newName) { store.toggle(post.id, in: b.id) }
                    newName = ""
                }
                .font(PhFont.mono(15))
            }
            InkLine()
            Button("done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
        .foregroundStyle(theme.ink)
        .padding(.top, 28)
        .phodoPage()
    }
}
