import PhotosUI
import SwiftUI

/// Tab 2: post a moment. At least one a day is the goal; more is fine,
/// and you can fill in days you missed.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    // which day this post is for
    @State private var forDate = Date()
    private var day: LocalDay { LocalDay(forDate) }

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
    @State private var visibility = 0               // 0 friends, 1 everyone, 2 just me
    @FocusState private var captionFocused: Bool

    @State private var isPosting = false
    @State private var errorText: String?
    @State private var justPosted = false

    private let visibilities: [PostVisibility] = [.friends, .everyone, .justMe]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ScreenHeader(title: day == .today ? "today" : day.short, trailing: day.header)
                status
                composer
                dayPosts
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

    // MARK: status + day picker

    private var status: some View {
        let count = store.myPosts.filter { $0.day == day }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if count == 0 {
                    Text(day == .today ? "nothing yet today. one is all you need ☾" : "you missed this one. fill it in?")
                } else {
                    Text("\(day == .today ? "today's" : "this day's") done ✓ · add more anytime")
                }
            }
            .font(PhFont.mono(13)).foregroundStyle(theme.softInk)

            HStack(spacing: 10) {
                Text("for").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                DatePicker("posting for", selection: $forDate, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                if day != .today {
                    Button { forDate = Date() } label: { TagChip(text: "back to today", dashed: true) }
                        .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: composer

    private var composer: some View {
        VStack(spacing: 22) {
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

            VStack(spacing: 10) {
                FieldLabel("who sees it")
                HStack {
                    PillToggle(options: visibilities.map(\.label), selection: $visibility)
                    Spacer(minLength: 0)
                }
                if visibilities[visibility] == .everyone {
                    Text("anyone on phodo can see this in explore")
                        .font(PhFont.mono(12)).foregroundStyle(theme.softInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let errorText {
                Text(errorText).font(PhFont.mono(13)).foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button { Task { await post() } } label: {
                if isPosting { ProgressView().tint(theme.bg) }
                else { Text(justPosted ? "posted ✓" : (day == .today ? "post it" : "post for \(day.short)")) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isPosting || (edited == nil && caption.trimmingCharacters(in: .whitespaces).isEmpty))
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
                Text(day == .today ? "drop today's pic" : "drop a pic from \(day.short)").font(PhFont.bold(24))
                Text("or skip it, words are fine").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                HStack(spacing: 10) {
                    if CameraPicker.isAvailable && day == .today {
                        Button { showCamera = true } label: { TagChip(text: "take one", selected: true) }
                            .buttonStyle(.plain)
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        TagChip(text: "pick one", selected: !(CameraPicker.isAvailable && day == .today))
                    }
                }
                .padding(.top, 6)
            }
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity, minHeight: 230)
            .background(RoundedRectangle(cornerRadius: Metrics.radius + 6, style: .continuous).fill(theme.sunken))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radius + 6, style: .continuous)
                .stroke(theme.ink, lineWidth: Metrics.line))
        }
    }

    /// Everything you've posted for the selected day, with real photos.
    @ViewBuilder
    private var dayPosts: some View {
        let posts = store.myPosts.filter { $0.day == day }
        if !posts.isEmpty {
            VStack(spacing: 14) {
                HStack {
                    Text(day == .today ? "today so far" : "\(day.short) so far").font(PhFont.bold(22))
                    Spacer()
                    Text("\(posts.count)").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                }
                InkLine()
                Masonry(items: posts, weight: { ($0.hasPhoto ? $0.aspect : 0.2) + 0.3 }) { post in
                    PostCard(post: post)
                }
            }
            .padding(.top, 8)
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
        captionFocused = false
        let photo = baseImage.flatMap { PhotoProcessor.process(PhotoEditor.render($0, edits)) }
        let draft = PostDraft(day: day, caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                              tags: selectedTags, visibility: visibilities[visibility], photo: photo)
        do {
            try await store.publish(draft)
            clearPhoto(); caption = ""; selectedTags = []; errorText = nil
            justPosted = true
            try? await Task.sleep(for: .seconds(2))
            justPosted = false
        } catch {
            errorText = error.localizedDescription.lowercased()
        }
    }
}
