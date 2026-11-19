import SwiftUI

/// Under the photo in the viewer: the latest couple of comments as little
/// bubbles, and a "say something nice" pill. Tap anywhere to open the sheet.
struct CommentsPreview: View {
    @Environment(\.theme) private var theme
    let comments: [Comment]
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(comments.suffix(2)) { c in
                    HStack(spacing: 6) {
                        Text("@\(c.author.username)").font(PhFont.bold(14))
                        Text(c.text).font(PhFont.body(16))
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(theme.card))
                    .overlay(Capsule().stroke(theme.ink, lineWidth: Metrics.line))
                }
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left").font(.system(size: 14, weight: .light))
                    Text("say something nice").font(PhFont.mono(14))
                    Spacer(minLength: 0)
                    if comments.count > 2 {
                        Text("all \(comments.count)").font(PhFont.mono(13))
                    }
                }
                .foregroundStyle(theme.softInk)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Capsule().stroke(theme.ink.opacity(0.5),
                                             style: StrokeStyle(lineWidth: Metrics.line, dash: [4, 3])))
            }
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SquishStyle())
        .accessibilityLabel(comments.isEmpty ? "add a comment" : "\(comments.count) comments")
    }
}

/// Every comment on a post, plus the little composer (30 characters max).
struct CommentsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    let post: Post
    @Binding var comments: [Comment]

    @State private var text = ""
    @State private var problem: CommentRules.Problem?
    @State private var sending = false
    @State private var failed = false
    @State private var sent = 0
    @State private var reported: Comment?
    @FocusState private var typing: Bool

    private var left: Int { CommentRules.maxLength - text.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("comments").font(PhFont.bold(22))
                if !comments.isEmpty {
                    Text("\(comments.count)").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                }
                Spacer()
            }
            .padding(.top, 22)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if comments.isEmpty {
                            Text("no comments yet. be the first ☾")
                                .font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                                .padding(.top, 8)
                        }
                        ForEach(comments) { c in row(c).id(c.id) }
                    }
                    .padding(.vertical, 4)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: comments.count) {
                    if let last = comments.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            composer
        }
        .foregroundStyle(theme.ink)
        .padding(.horizontal, Metrics.margin)
        .padding(.bottom, 10)
        .background(theme.bg.ignoresSafeArea())
        .sensoryFeedback(.success, trigger: sent)
        .sensoryFeedback(.error, trigger: problem) { _, new in new != nil }
        .confirmationDialog("report this comment?", isPresented: Binding(
            get: { reported != nil }, set: { if !$0 { reported = nil } }),
            titleVisibility: .visible, presenting: reported) { c in
            Button("report", role: .destructive) { Task { await store.reportComment(c) } }
        } message: { c in
            Text("\"\(c.text)\" from @\(c.author.username)")
        }
    }

    private func row(_ c: Comment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(person: c.author, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("@\(c.author.username)").font(PhFont.bold(15))
                    Text(Date().timeIntervalSince(c.createdAt) < 60 ? "now"
                         : c.createdAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                        .font(PhFont.mono(11)).foregroundStyle(theme.softInk)
                }
                Text(c.text).font(PhFont.body(18))
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if store.canDelete(c, on: post) {
                Button("delete", systemImage: "trash", role: .destructive) {
                    withAnimation { comments.removeAll { $0.id == c.id } }
                    Task { await store.deleteComment(c) }
                }
            }
            if c.author.id != store.me.id {
                Button("report", systemImage: "flag") { reported = c }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CommentRules.quickPicks, id: \.self) { pick in
                        Button { text = pick; problem = nil; typing = true } label: {
                            Text(pick).font(PhFont.mono(13))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(theme.chip))
                                .overlay(Capsule().stroke(theme.ink, lineWidth: Metrics.line))
                        }
                        .buttonStyle(SquishStyle())
                    }
                }
                .padding(1)
            }

            HStack(spacing: 10) {
                TextField("", text: $text,
                          prompt: Text("say something nice").foregroundStyle(theme.softInk.opacity(0.7)))
                    .font(PhFont.body(18))
                    .textInputAutocapitalization(.never)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .onChange(of: text) {
                        if text.count > CommentRules.maxLength { text = String(text.prefix(CommentRules.maxLength)) }
                        if problem != nil { problem = nil }
                        failed = false
                    }
                Text("\(left)")
                    .font(PhFont.mono(12))
                    .foregroundStyle(left <= 5 ? theme.ink : theme.softInk)
                    .monospacedDigit()
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.bg)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(theme.ink))
                }
                .buttonStyle(SquishStyle())
                .disabled(sending || text.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                .accessibilityLabel("send")
            }
            .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
            .background(Capsule().fill(theme.card))
            .overlay(Capsule().stroke(theme.ink, lineWidth: Metrics.line))

            if let message = problem?.message ?? (failed ? "couldn't post that. try again?" : nil) {
                Text(message).font(PhFont.mono(12)).foregroundStyle(theme.ink)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: problem)
    }

    private func send() {
        guard !sending else { return }
        sending = true
        let draft = text
        Task {
            defer { sending = false }
            do {
                let c = try await store.addComment(draft, on: post)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { comments.append(c) }
                text = ""
                sent += 1
            } catch let p as CommentRules.Problem {
                problem = p
            } catch {
                failed = true
            }
        }
    }
}

/// The comments sheet opened straight from a post in a grid (the speech-bubble button):
/// loads the comments itself.
struct PostComments: View {
    @Environment(AppStore.self) private var store
    let post: Post
    @State private var comments: [Comment] = []

    var body: some View {
        CommentsSheet(post: post, comments: $comments)
            .task { comments = await store.comments(on: post) }
    }
}
