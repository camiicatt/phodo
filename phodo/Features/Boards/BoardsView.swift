import SwiftUI

/// Tab 4: saved collections, Pinterest-style. Saved to Supabase.
/// Save anything by long-pressing a post (or the bookmark on friends' posts).
struct BoardsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var selectedID: UUID?
    @State private var creating = false
    @State private var renaming: Board?
    @State private var deleting: Board?
    @State private var nameField = ""

    var body: some View {
        let board = store.boards.first { $0.id == selectedID } ?? store.boards.first
        let posts = board?.postIDs.compactMap { store.post($0) } ?? []

        ScrollView {
            VStack(spacing: 22) {
                ScreenHeader(title: board?.name ?? "boards",
                             trailing: board == nil ? "" : "\(board!.isPublic ? "public · " : "")\(posts.count) saved")

                if let board {
                    HStack {
                        Toggle(isOn: Binding(get: { board.isPublic },
                                             set: { on in Task { await store.setBoardPublic(board.id, on) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("public board").font(PhFont.body(17))
                                Text(board.isPublic ? "shows on your profile for anyone" : "only you can see it")
                                    .font(PhFont.mono(12)).foregroundStyle(theme.softInk)
                            }
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.boards) { b in
                            Button { selectedID = b.id } label: {
                                TagChip(text: "#\(b.name)\(b.isPublic ? " ◎" : "")", selected: b.id == board?.id)
                            }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { nameField = b.name; renaming = b } label: { Label("rename", systemImage: "pencil") }
                                    Button { Task { await store.setBoardPublic(b.id, !b.isPublic) } } label: {
                                        Label(b.isPublic ? "make private" : "make public",
                                              systemImage: b.isPublic ? "lock" : "globe")
                                    }
                                    Button(role: .destructive) { deleting = b } label: { Label("delete board", systemImage: "trash") }
                                }
                        }
                        Button { nameField = ""; creating = true } label: { TagChip(text: "+ new", dashed: true) }
                            .buttonStyle(.plain)
                    }
                    .padding(1)
                }

                if store.boards.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("no boards yet").font(PhFont.bold(24))
                        Text("hold any post to save it, or make a board with + new")
                            .font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if posts.isEmpty {
                    Text("nothing saved here yet. hold any post to save it")
                        .font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Masonry(items: posts, weight: { ($0.hasPhoto ? $0.aspect : 0.2) + 0.35 }) { post in
                        PostCard(post: post, showAuthor: true)
                    }
                }
            }
            .foregroundStyle(theme.ink)
            .padding(.top, 12).padding(.bottom, 24)
        }
        .refreshable { await Task { await store.load() }.value }   // own task: SwiftUI cancels refresh tasks when the screen updates mid-refresh
        .phodoPage()
        .alert("new board", isPresented: $creating) {
            TextField("name", text: $nameField).textInputAutocapitalization(.never)
            Button("make it") { Task { selectedID = await store.createBoard(named: nameField)?.id } }
            Button("cancel", role: .cancel) {}
        }
        .alert("rename board", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("name", text: $nameField).textInputAutocapitalization(.never)
            Button("save") { if let b = renaming { Task { await store.renameBoard(b.id, to: nameField) } } }
            Button("cancel", role: .cancel) {}
        }
        .confirmationDialog("delete #\(deleting?.name ?? "")?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("delete board", role: .destructive) {
                if let b = deleting { Task { await store.deleteBoard(b.id) } }
            }
        } message: { Text("the posts stay. only the board goes.") }
    }
}
