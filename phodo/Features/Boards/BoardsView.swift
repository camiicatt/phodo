import SwiftUI

/// Screen 4 — saved collections, Pinterest-style.
struct BoardsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var selectedID: UUID?
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        let board = store.boards.first { $0.id == selectedID } ?? store.boards.first
        let posts = board?.postIDs.compactMap { store.post($0) } ?? []

        ScrollView {
            VStack(spacing: 22) {
                ScreenHeader(title: board?.name ?? "boards", trailing: "\(posts.count) saved")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.boards) { b in
                            Button { selectedID = b.id } label: { TagChip(text: "#\(b.name)", selected: b.id == board?.id) }
                                .buttonStyle(.plain)
                        }
                        Button { creating = true } label: { TagChip(text: "+ new", dashed: true) }.buttonStyle(.plain)
                    }
                    .padding(1)
                }

                if posts.isEmpty {
                    Text("nothing saved here yet — tap the bookmark on a post")
                        .font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Masonry(items: posts, weight: { $0.aspect + 0.2 }) { post in
                        VStack(alignment: .leading, spacing: 6) {
                            PhotoTile(image: post.image, url: post.thumbURL, tint: post.tint, aspect: post.aspect, seed: post.id.hashValue)
                            HStack(alignment: .firstTextBaseline) {
                                Text(post.caption).font(PhFont.bold(17)).lineLimit(1)
                                Spacer()
                                Text(post.author.id == store.me.id ? "me" : post.author.username)
                                    .font(PhFont.mono(12)).foregroundStyle(theme.softInk)
                            }
                        }
                    }
                }
            }
            .foregroundStyle(theme.ink)
            .padding(.top, 12).padding(.bottom, 24)
        }
        .phodoPage()
        .alert("new board", isPresented: $creating) {
            TextField("name", text: $newName).textInputAutocapitalization(.never)
            Button("make it") { selectedID = store.createBoard(named: newName)?.id; newName = "" }
            Button("cancel", role: .cancel) { newName = "" }
        }
    }
}
