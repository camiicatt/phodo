import SwiftUI

/// One post in any grid (explore, today, profiles, boards).
/// - double-tap the photo or tap ♡ to love it
/// - tap the name to see their profile
/// - hold it: save · love · see @them bubbles fan out (slide onto one, let go)
/// - tap ⋯ for everything else: add friend · report · block · delete
struct PostCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.holdMenu) private var hold
    let post: Post
    var showAuthor = false
    var showDate = false
    /// Use the full-size photo (single-column views) instead of the thumbnail.
    var large = false

    @State private var saving = false
    @State private var reporting = false
    @State private var confirmBlock = false
    @State private var confirmDelete = false
    @State private var viewing: Person?
    @State private var heartPop = false
    @State private var expanded = false   // full-screen photo
    @State private var browsingTag: TagRequest?
    @State private var commenting = false
    @State private var likeTaps = 0      // drives the vibration: only on your taps, never on load

    private var isMine: Bool { post.author.id == store.me.id }
    private var liked: Bool { store.isLiked(post.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if post.hasPhoto {
                PhotoTile(image: post.image, url: large ? (post.fullURL ?? post.thumbURL) : post.thumbURL,
                          tint: post.tint, aspect: post.aspect, seed: post.id.hashValue)
                    .overlay {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 64)).foregroundStyle(theme.card)
                            .shadow(color: theme.ink.opacity(0.25), radius: 8)
                            .scaleEffect(heartPop ? 1 : 0.4).opacity(heartPop ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                    .onTapGesture(count: 2) { doubleTapLike() }
                    .onTapGesture { expanded = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("tap to open, double-tap to love")
            }
            if showAuthor {
                HStack(spacing: 8) {
                    Button { viewing = post.author } label: {
                        HStack(spacing: 8) {
                            Avatar(person: post.author, size: 24)
                            Text(post.author.username).font(PhFont.bold(17)).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("opens their profile")
                    Spacer(minLength: 0)
                }
            }
            if !post.caption.isEmpty {
                Text(post.caption).font(PhFont.body(post.hasPhoto ? 17 : 21))
            }
            if !meta.characters.isEmpty {
                // each #tag is tappable → every post with that tag
                Text(meta).font(PhFont.mono(12)).foregroundStyle(theme.softInk).tint(theme.softInk)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "phodo-tag", let t = url.host() else { return .systemAction }
                        browsingTag = TagRequest(tag: t)
                        return .handled
                    })
            }
            actions
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
        .scaleEffect(hold?.post?.id == post.id ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hold?.post?.id == post.id)
        .contentShape(Rectangle())
        .modifier(HoldToPick(post: post, fallback: { saving = true }))
        .sensoryFeedback(.impact(weight: .light), trigger: likeTaps)
        .sheet(isPresented: $saving) {
            SaveToBoardSheet(post: post).environment(\.theme, theme).presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $expanded) {
            PhotoViewer(post: post).environment(\.theme, theme)
        }
        .sheet(item: $viewing) { person in
            PersonProfileView(person: person).environment(\.theme, theme)
        }
        .sheet(isPresented: $commenting) {
            PostComments(post: post)
                .environment(\.theme, theme)
                .presentationDetents([.medium, .large])
                .presentationBackground(theme.bg)
        }
        .sheet(item: $browsingTag) { req in
            SearchSheet(startTag: req.tag).environment(\.theme, theme.shaded)
                .presentationBackground(theme.shade)
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
        } message: { Text("the photo is deleted for good.") }
    }

    /// ♡ · 🔖 · ⋯ row. On your own posts, ♥ shows how many people loved it (only you see this).
    private var actions: some View {
        HStack(spacing: 2) {
            Button { like() } label: {
                HStack(spacing: 4) {
                    Image(systemName: liked ? "heart.fill" : "heart")
                    if isMine, let n = store.likeCounts[post.id], n > 0 {
                        Text("\(n)").font(PhFont.mono(12))
                    }
                }
                .frame(minWidth: 36, minHeight: 32, alignment: .leading)
            }
            .accessibilityLabel(liked ? "unlove" : "love")

            Button { commenting = true } label: {
                Image(systemName: "bubble.left")
                    .frame(width: 36, height: 32, alignment: .leading)
            }
            .accessibilityLabel("comments")

            Button { saving = true } label: {
                Image(systemName: store.isSaved(post.id) ? "bookmark.fill" : "bookmark")
                    .frame(width: 36, height: 32, alignment: .leading)
            }
            .accessibilityLabel("save to a scrapbook")

            Spacer(minLength: 0)

            Menu { menu } label: {
                Image(systemName: "ellipsis").frame(width: 36, height: 32, alignment: .trailing)
            }
            .accessibilityLabel("more")
        }
        .font(.system(size: 17, weight: .light))
        .buttonStyle(.plain)
    }

    /// The latest visibility (the store updates it right away when you change it).
    private var current: PostVisibility { store.post(post.id)?.visibility ?? post.visibility }

    private var meta: AttributedString {
        var parts: [String] = []
        if showDate { parts.append(post.day.short) } else if post.day != .today { parts.append("for \(post.day.short)") }
        if current == .everyone && isMine { parts.append("everyone") }
        if current == .justMe { parts.append("just me") }
        var out = AttributedString(parts.joined(separator: " · "))
        for (i, t) in post.tags.enumerated() {
            if i == 0 { if !parts.isEmpty { out += AttributedString(" · ") } } else { out += AttributedString(" ") }
            var chip = AttributedString("#\(t)")
            chip.link = URL(string: "phodo-tag://\(t)")
            out += chip
        }
        return out
    }

    private func like() {
        likeTaps += 1
        Task { await store.toggleLike(post) }
    }

    private func doubleTapLike() {
        if !liked { like() }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { heartPop = true }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.25)) { heartPop = false }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button { saving = true } label: { Label("save to a scrapbook", systemImage: "bookmark") }
        Button { like() } label: {
            Label(liked ? "unlove" : "love", systemImage: liked ? "heart.slash" : "heart")
        }
        if isMine {
            Menu {
                ForEach([PostVisibility.friends, .everyone, .justMe], id: \.self) { v in
                    Button { Task { await store.setVisibility(post, to: v) } } label: {
                        if current == v { Label(v.label, systemImage: "checkmark") } else { Text(v.label) }
                    }
                }
            } label: {
                Label("who sees it: \(current.label)", systemImage: "eye")
            }
            Button(role: .destructive) { confirmDelete = true } label: { Label("delete post", systemImage: "trash") }
        } else {
            Button { viewing = post.author } label: { Label("see @\(post.author.username)", systemImage: "person") }
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
    @State private var saves = 0         // vibration on each save/unsave tap

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("save to…").font(PhFont.title(32))
            if store.boards.isEmpty {
                Text("no scrapbooks yet. make one below").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
            }
            FlowLayout(spacing: 10) {
                ForEach(store.boards) { board in
                    Button { saves += 1; Task { await store.toggle(post.id, in: board.id) } } label: {
                        TagChip(text: "#\(board.name)\(board.isPublic ? " ◎" : "")", selected: board.postIDs.contains(post.id))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("new scrapbook", text: $newName).font(PhFont.mono(15))
                    .textInputAutocapitalization(.never)
                Button("+ make it") {
                    Task {
                        if let b = await store.createBoard(named: newName) { saves += 1; await store.toggle(post.id, in: b.id) }
                        newName = ""
                    }
                }
                .font(PhFont.mono(15))
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("◎ = public scrapbook, shows on your profile").font(PhFont.mono(12)).foregroundStyle(theme.softInk)
            InkLine()
            Button("done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.ink)
        .padding(.top, 28)
        .phodoPage()
        .sensoryFeedback(.success, trigger: saves)
    }
}

/// Hold a post, then slide onto a bubble. Uses UIKit's long-press recognizer
/// (iOS 18+) because it shares nicely with scrolling and keeps reporting where
/// your finger is; SwiftUI's own drag gesture blocks the feed from scrolling.
private struct HoldToPick: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.holdMenu) private var hold
    let post: Post
    let fallback: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let hold {
            content.gesture(HoldRecognizer { phase, point in
                switch phase {
                case .began: hold.open(post, at: point)
                case .moved: hold.move(to: point)
                case .ended:
                    if let (choice, held) = hold.release() {
                        Task { await hold.perform(choice, on: held, store: store) }
                    }
                case .cancelled: _ = hold.cancel()
                }
            })
        } else {
            // older iOS: hold just opens the board picker
            content.onLongPressGesture(minimumDuration: 0.35) { fallback() }
        }
    }
}

@available(iOS 18.0, *)
private struct HoldRecognizer: UIGestureRecognizerRepresentable {
    enum Phase { case began, moved, ended, cancelled }
    let onChange: (Phase, CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let r = UILongPressGestureRecognizer()
        r.minimumPressDuration = 0.35
        r.allowableMovement = 10          // moving sooner than that = you meant to scroll
        return r
    }

    func handleUIGestureRecognizerAction(_ r: UILongPressGestureRecognizer, context: Context) {
        let point = r.location(in: nil)   // window = screen coordinates
        switch r.state {
        case .began: onChange(.began, point)
        case .changed: onChange(.moved, point)
        case .ended: onChange(.ended, point)
        case .cancelled, .failed: onChange(.cancelled, point)
        default: break
        }
    }
}

/// Which #tag a post's tag link asked to open.
struct TagRequest: Identifiable {
    let tag: String
    var id: String { tag }
}
