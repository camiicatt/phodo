import SwiftUI

/// One search for #tags and @people.
/// - empty: popular tags to tap
/// - "#sun" → tags only · "@ma" → people only · "sun" → both
/// - pick a tag → every post with it that you're allowed to see
struct SearchSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Open straight onto a tag (e.g. tapping #sunset on a post).
    var startTag: String? = nil

    @State private var query = ""
    @State private var tag: String?
    @State private var posts: [Post] = []
    @State private var people: [Person] = []
    @State private var loading = false
    @State private var viewing: Person?
    @FocusState private var typing: Bool

    private var wantsTags: Bool { !query.hasPrefix("@") }
    private var wantsPeople: Bool { !query.hasPrefix("#") }
    private var tagText: String { AppStore.cleanTag(query) }

    /// Popular tags that start with what you typed, plus exactly what you typed.
    private var tagMatches: [String] {
        guard !tagText.isEmpty else { return [] }
        let starts = store.popularTags.filter { $0.hasPrefix(tagText) && $0 != tagText }
        return [tagText] + starts.prefix(5)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("search").font(PhFont.title(34))
                    Spacer()
                    Button("done") { dismiss() }.font(PhFont.bold(17))
                }

                if let tag { tagResults(tag) } else { searchBox; suggestions }
            }
            .foregroundStyle(theme.ink)
            .padding(.top, 24).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .phodoPage()
        .holdMenuHost()
        .animation(.easeOut(duration: 0.18), value: tag)
        .sheet(item: $viewing) { PersonProfileView(person: $0).environment(\.theme, theme) }
        .task(id: query) { await findPeople() }
        .onAppear {
            if let startTag { open(startTag) } else { typing = true }
        }
    }

    // MARK: typing

    private var searchBox: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .light))
                    .foregroundStyle(theme.softInk)
                TextField("", text: $query, prompt: Text("#tags or @people").foregroundStyle(theme.softInk.opacity(0.7)))
                    .font(PhFont.body(20))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($typing)
                    .submitLabel(.search)
                    .onSubmit { if wantsTags && !tagText.isEmpty { open(tagText) } }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle").font(.system(size: 17, weight: .light))
                    }
                    .foregroundStyle(theme.softInk)
                    .accessibilityLabel("clear")
                }
            }
            InkLine()
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        if query.isEmpty {
            FieldLabel("popular tags")
            FlowLayout(spacing: 10) {
                ForEach(store.popularTags, id: \.self) { t in
                    Button { open(t) } label: { TagChip(text: "#\(t)") }.buttonStyle(SquishStyle())
                }
            }
            Text("tip: start with @ to find people, # for tags")
                .font(PhFont.mono(12)).foregroundStyle(theme.softInk)
        } else {
            if wantsTags && !tagMatches.isEmpty {
                FieldLabel("tags")
                FlowLayout(spacing: 10) {
                    ForEach(tagMatches, id: \.self) { t in
                        Button { open(t) } label: { TagChip(text: "#\(t)", selected: t == tagText) }
                            .buttonStyle(SquishStyle())
                    }
                }
            }
            if wantsPeople && !Username.clean(query).isEmpty {
                FieldLabel("people")
                if people.isEmpty && !loading {
                    Text("no one called @\(Username.clean(query)) yet")
                        .font(PhFont.mono(13)).foregroundStyle(theme.softInk)
                }
                ForEach(people) { p in PersonRow(person: p) { viewing = $0 } }
            }
        }
    }

    // MARK: a tag

    @ViewBuilder
    private func tagResults(_ tag: String) -> some View {
        HStack(spacing: 10) {
            TagChip(text: "#\(tag)", selected: true)
            Spacer()
            Button { self.tag = nil; posts = []; typing = true } label: {
                Text("← back").font(PhFont.mono(14))
            }
        }
        if loading {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
        } else if posts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("no #\(tag) yet").font(PhFont.bold(22))
                Text("be the first to use it ☾").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
            }
        } else {
            Text(posts.count == 1 ? "1 post" : "\(posts.count) posts")
                .font(PhFont.mono(13)).foregroundStyle(theme.softInk)
            Masonry(items: posts, weight: { ($0.hasPhoto ? $0.aspect : 0.2) + 0.45 }) { post in
                PostCard(post: post, showAuthor: true, showDate: true)
            }
        }
    }

    private func open(_ t: String) {
        let clean = AppStore.cleanTag(t)
        guard !clean.isEmpty else { return }
        typing = false
        tag = clean
        loading = true
        Task {
            let found = await store.posts(tagged: clean)
            if tag == clean { posts = found; loading = false }
        }
    }

    private func findPeople() async {
        let q = Username.clean(query)
        guard wantsPeople, !q.isEmpty else { people = []; return }
        try? await Task.sleep(for: .milliseconds(300))   // wait until they stop typing
        guard !Task.isCancelled else { return }
        loading = true
        people = await store.search(q)
        loading = false
    }
}
