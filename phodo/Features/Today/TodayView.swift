import PhotosUI
import SwiftUI

/// Screen 1 — post today's moment. One post per day.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    // photo
    @State private var pickerItem: PhotosPickerItem?
    @State private var baseImage: CGImage?          // downsampled original (≤2048px)
    @State private var edits = EditSettings()
    @State private var edited: UIImage?             // what the drop zone shows
    @State private var showCamera = false
    @State private var showEditor = false

    // text
    @State private var caption = ""
    @State private var selectedTags: [String] = []
    @State private var addingTag = false
    @State private var newTag = ""
    @State private var visibility = 0               // 0 friends, 1 just me
    @FocusState private var captionFocused: Bool

    @State private var isPosting = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ScreenHeader(title: "today", trailing: LocalDay.today.header)
                if let post = store.todaysPost {
                    PostedToday(post: post)
                } else {
                    composer
                }
            }
            .padding(.top, 12).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .phodoPage()
        .onChange(of: pickerItem) { _, item in Task { await load(item) } }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.95) { setBase(PhotoProcessor.downsample(data)) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showEditor) {
            if let baseImage {
                PhotoEditView(base: baseImage, settings: $edits) { renderEdits() }
                    .environment(\.theme, theme)
            }
        }
        .alert("new tag", isPresented: $addingTag) {
            TextField("#tag", text: $newTag).textInputAutocapitalization(.never)
            Button("add") { addTag() }
            Button("cancel", role: .cancel) { newTag = "" }
        }
    }

    // MARK: composer

    private var composer: some View {
        VStack(spacing: 24) {
            dropZone

            VStack(spacing: 10) {
                FieldLabel("caption")
                TextField("", text: $caption, prompt: Text("say whatever...").foregroundStyle(theme.softInk.opacity(0.7)),
                          axis: .vertical)
                    .font(PhFont.body(22)).foregroundStyle(theme.ink)
                    .lineLimit(1...4)
                    .focused($captionFocused)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("done") { captionFocused = false }.font(PhFont.bold(17))
                        }
                    }
                InkLine()
            }

            VStack(spacing: 12) {
                FieldLabel("tags")
                FlowLayout(spacing: 10) {
                    ForEach(tagOptions, id: \.self) { tag in
                        Button { toggleTag(tag) } label: {
                            TagChip(text: "#\(tag)", selected: selectedTags.contains(tag))
                        }
                        .buttonStyle(.plain)
                    }
                    Button { addingTag = true } label: { TagChip(text: "+ add", dashed: true) }
                        .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let errorText {
                Text(errorText).font(PhFont.mono(13)).foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 14) {
                PillToggle(options: ["friends", "just me"], selection: $visibility)
                Button { Task { await post() } } label: {
                    if isPosting { ProgressView().tint(theme.bg) } else { Text("post it") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isPosting || (edited == nil && caption.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
    }

    @ViewBuilder
    private var dropZone: some View {
        if let edited {
            VStack(spacing: 12) {
                PhotoTile(image: edited, aspect: edited.size.height / max(edited.size.width, 1))
                HStack(spacing: 10) {
                    Button { showEditor = true } label: { TagChip(text: "edit") }.buttonStyle(.plain)
                    PhotosPicker(selection: $pickerItem, matching: .images) { TagChip(text: "swap") }
                    Spacer()
                    Button { clearPhoto() } label: { TagChip(text: "remove", dashed: true) }.buttonStyle(.plain)
                }
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "plus.circle").font(.system(size: 40, weight: .thin))
                Text("drop today's pic").font(PhFont.bold(24))
                Text("or skip it, words are fine").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                HStack(spacing: 10) {
                    if CameraPicker.isAvailable {
                        Button { showCamera = true } label: { TagChip(text: "take one", selected: true) }
                            .buttonStyle(.plain)
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        TagChip(text: "pick one", selected: !CameraPicker.isAvailable)
                    }
                }
                .padding(.top, 6)
            }
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity, minHeight: 250)
            .background(RoundedRectangle(cornerRadius: Metrics.radius + 6, style: .continuous).fill(theme.sunken))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radius + 6, style: .continuous)
                .stroke(theme.ink, lineWidth: Metrics.line))
        }
    }

    private var tagOptions: [String] {
        var seen = Set<String>()
        return (selectedTags + store.recentTags).filter { seen.insert($0).inserted }.prefix(10).map { $0 }
    }

    // MARK: actions

    private func load(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        setBase(PhotoProcessor.downsample(data))
    }

    private func setBase(_ image: CGImage?) {
        guard let image else { errorText = "couldn't open that pic"; return }
        baseImage = image
        edits = EditSettings()
        edited = UIImage(cgImage: image)
        errorText = nil
    }

    private func renderEdits() {
        guard let baseImage else { return }
        edited = UIImage(cgImage: PhotoEditor.render(baseImage, edits))
    }

    private func clearPhoto() {
        baseImage = nil; edited = nil; pickerItem = nil; edits = EditSettings()
    }

    private func toggleTag(_ tag: String) {
        if let i = selectedTags.firstIndex(of: tag) { selectedTags.remove(at: i) } else { selectedTags.append(tag) }
    }

    private func addTag() {
        let tag = newTag.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        newTag = ""
        guard !tag.isEmpty else { return }
        if !selectedTags.contains(tag) { selectedTags.append(tag) }
    }

    private func post() async {
        isPosting = true
        defer { isPosting = false }
        let photo = baseImage.flatMap { PhotoProcessor.process(PhotoEditor.render($0, edits)) }
        let draft = PostDraft(caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                              tags: selectedTags, visibility: visibility == 0 ? .friends : .justMe, photo: photo)
        do {
            try await store.publish(draft)
            clearPhoto(); caption = ""; selectedTags = []; errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Shown after posting — the post button is gone until tomorrow.
private struct PostedToday: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    let post: Post
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if post.image != nil || post.tint != nil {
                PhotoTile(image: post.image, tint: post.tint, aspect: post.aspect)
            }
            if !post.caption.isEmpty { Text(post.caption).font(PhFont.body(22)) }
            if !post.tags.isEmpty {
                Text(post.tags.map { "#\($0)" }.joined(separator: " ")).font(PhFont.mono(14)).foregroundStyle(theme.softInk)
            }
            Text(post.visibility == .friends ? "shared with friends" : "just for you")
                .font(PhFont.mono(13)).foregroundStyle(theme.softInk)

            VStack(alignment: .leading, spacing: 6) {
                Text("that's today, done ✓").font(PhFont.bold(24))
                Text("see you tomorrow ☾").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
            }
            .padding(.top, 8)

            Button("delete today's post") { confirmDelete = true }
                .font(PhFont.mono(13)).foregroundStyle(theme.softInk)
                .confirmationDialog("delete today's post?", isPresented: $confirmDelete) {
                    Button("delete", role: .destructive) { Task { await store.deletePost(post) } }
                }
        }
        .foregroundStyle(theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
