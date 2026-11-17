import SwiftUI

/// One post in any grid (friends, explore, profile, boards, today).
/// Long-press for: save to board · add friend · report · block · delete.
struct PostCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    let post: Post
    var showAuthor = false
    var showDate = false
    /// Use the full-size photo (single-column views) instead of the thumbnail.
    var large = false

    @State private var saving = false
    @State private var reporting = false
    @State private var confirmBlock = false
    @State private var confirmDelete = false

    private var isMine: Bool { post.author.id == store.me.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if post.hasPhoto {
                PhotoTile(image: post.image, url: large ? (post.fullURL ?? post.thumbURL) : post.thumbURL,
                          tint: post.tint, aspect: post.aspect, seed: post.id.hashValue)
            }
            if showAuthor {
                HStack(spacing: 8) {
                    Avatar(person: post.author, size: 24)
                    Text(post.author.username).font(PhFont.bold(17)).lineLimit(1)
                    Spacer(minLength: 0)
                    saveButton
                }
            }
            if !post.caption.isEmpty {
                Text(post.caption).font(PhFont.body(post.hasPhoto ? 17 : 21))
            }
            if !meta.isEmpty {
                Text(meta).font(PhFont.mono(12)).foregroundStyle(theme.softInk)
            }
        }
        .foregroundStyle(theme.ink)
        .padding(post.hasPhoto ? 0 : 14)
        .background {
            // words-only posts get a soft card so they still read as a post
            if !post.hasPhoto {
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).fill(theme.card)
                    .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                        .stroke(theme.ink, lineWidth: Metrics.line))
            }
        }
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .contextMenu { menu }
        .sheet(isPresented: $saving) {
            SaveToBoardSheet(post: post).environment(\.theme, theme).presentationDetents([.medium, .large])
        }
        .confirmationDialog("report this post?", isPresented: $reporting, titleVisibility: .visible) {
            ForEach(["spam", "mean or bullying", "nudity or sexual", "violence or danger", "something else"], id: \.self) { reason in
                Button(reason) { Task { await store.report(post, reason: reason) } }
            }
        } message: { Text("we'll review it. they won't know who reported.") }
        .confirmationDialog("block @\(post.author.username)?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("block", role: .destructive) { Task { await store.block(post.author) } }
        } message: { Text("you won't see each other's posts, and you'll stop being friends.") }
        .confirmationDialog("delete this post?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("delete", role: .destructive) { Task { await store.deletePost(post) } }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if showDate { parts.append(post.day.short) } else if post.day != .today { parts.append("for \(post.day.short)") }
        if post.visibility == .everyone && isMine { parts.append("everyone") }
        if post.visibility == .justMe { parts.append("just me") }
        let tags = post.tags.map { "#\($0)" }.joined(separator: " ")
        if !tags.isEmpty { parts.append(tags) }
        return parts.joined(separator: " · ")
    }

    private var saveButton: some View {
        Button { saving = true } label: {
            Image(systemName: store.isSaved(post.id) ? "bookmark.fill" : "bookmark")
                .font(.system(size: 18, weight: .light))
                .frame(width: 44, height: 32, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("save to board")
    }

    @ViewBuilder
    private var menu: some View {
        Button { saving = true } label: { Label("save to board", systemImage: "bookmark") }
        if isMine {
            Button(role: .destructive) { confirmDelete = true } label: { Label("delete", systemImage: "trash") }
        } else {
            if store.status(of: post.author.id) == nil {
                Button { Task { await store.addFriend(post.author) } } label: {
                    Label("add @\(post.author.username)", systemImage: "person.badge.plus")
                }
            }
            Button { reporting = true } label: { Label("report", systemImage: "flag") }
            Button(role: .destructive) { confirmBlock = true } label: {
                Label("block @\(post.author.username)", systemImage: "hand.raised")
            }
        }
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
            if store.boards.isEmpty {
                Text("no boards yet. make one below").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
            }
            FlowLayout(spacing: 10) {
                ForEach(store.boards) { board in
                    Button { Task { await store.toggle(post.id, in: board.id) } } label: {
                        TagChip(text: "#\(board.name)", selected: board.postIDs.contains(post.id))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("new board", text: $newName).font(PhFont.mono(15))
                    .textInputAutocapitalization(.never)
                Button("+ make it") {
                    Task {
                        if let b = await store.createBoard(named: newName) { await store.toggle(post.id, in: b.id) }
                        newName = ""
                    }
                }
                .font(PhFont.mono(15))
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            InkLine()
            Button("done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.ink)
        .padding(.top, 28)
        .phodoPage()
    }
}
