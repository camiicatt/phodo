import SwiftUI

/// Screen 3 — your profile, with a pics / journal toggle.
struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var mode = 0              // 0 pics, 1 journal
    @State private var showEdit = false
    @State private var showSettings = false
    @State private var openDay: Post?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !store.me.bio.isEmpty { Text(store.me.bio).font(PhFont.body(19)) }

                HStack(spacing: 12) {
                    Button("edit profile") { showEdit = true }.buttonStyle(OutlineButtonStyle())
                    PillToggle(options: ["pics", "journal"], selection: $mode)
                }
                InkLine()

                if mode == 0 {
                    Masonry(items: store.myPosts, weight: { $0.aspect + 0.3 }) { post in
                        PostCard(post: post, showDate: true).onTapGesture { openDay = post }
                    }
                } else {
                    JournalCalendar(posts: store.myPosts) { openDay = $0 }
                }
            }
            .foregroundStyle(theme.ink)
            .padding(.top, 12).padding(.bottom, 24)
        }
        .phodoPage()
        .sheet(isPresented: $showEdit) { EditProfileSheet().environment(\.theme, theme) }
        .sheet(isPresented: $showSettings) { SettingsSheet().environment(\.theme, theme) }
        .sheet(item: $openDay) { post in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScreenHeader(title: post.day.short)
                    PostCard(post: post)
                }
                .padding(.top, 24)
            }
            .phodoPage()
            .environment(\.theme, theme)
            .presentationDetents([.large])
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Circle().fill(theme.photoTint).frame(width: 76, height: 76)
                .overlay(Circle().stroke(theme.ink, lineWidth: Metrics.line))
                .overlay(Text(String(store.me.username.prefix(1))).font(PhFont.title(34)))
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(store.me.username)").font(PhFont.title(30)).lineLimit(1).minimumScaleFactor(0.6)
                Text(store.me.displayName).font(PhFont.body(18))
                Text("\(store.daysPosted) days posted" + (store.me.location.isEmpty ? "" : " · \(store.me.location)"))
                    .font(PhFont.mono(13)).foregroundStyle(theme.softInk)
            }
            Spacer(minLength: 0)
            Button { showSettings = true } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: 18, weight: .light))
                    .frame(width: 44, height: 44)
                    .overlay(Circle().stroke(theme.ink, lineWidth: Metrics.line))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("settings")
        }
    }
}

/// Month grid: posted days are filled, today has an accent ring.
struct JournalCalendar: View {
    @Environment(\.theme) private var theme
    let posts: [Post]
    let onOpen: (Post) -> Void
    @State private var monthOffset = 0

    var body: some View {
        let cal = Calendar.current
        let month = cal.date(byAdding: .month, value: monthOffset, to: LocalDay.today.date)!
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let days = cal.range(of: .day, in: .month, for: first)!.count
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let byDay = Dictionary(posts.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })

        VStack(spacing: 14) {
            HStack {
                Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                Spacer()
                Text(first.formatted(.dateTime.month(.wide).year()).lowercased()).font(PhFont.bold(20))
                Spacer()
                Button { monthOffset += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(monthOffset >= 0)
            }
            .buttonStyle(.plain)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                // ids must be unique across the whole grid: weekdays −1…−7, blanks −101…, days 1…31
                let symbols = cal.veryShortWeekdaySymbols
                ForEach((0..<7).map { -1 - $0 }, id: \.self) { key in
                    Text(symbols[(-1 - key + cal.firstWeekday - 1) % 7].lowercased())
                        .font(PhFont.mono(12)).foregroundStyle(theme.softInk)
                }
                ForEach((0..<lead).map { -101 - $0 }, id: \.self) { _ in Color.clear.frame(height: 44) }
                ForEach(1...days, id: \.self) { d in
                    let day = LocalDay(cal.date(byAdding: .day, value: d - 1, to: first)!)
                    let post = byDay[day]
                    Button { if let post { onOpen(post) } } label: {
                        Text("\(d)").font(PhFont.mono(14))
                            .foregroundStyle(post != nil ? theme.bg : theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(post != nil ? theme.ink : theme.sunken))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(day == .today ? theme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .disabled(post == nil)
                }
            }
        }
    }
}

struct EditProfileSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bio = ""
    @State private var location = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("edit profile").font(PhFont.title(34))
            field("name", $name)
            field("bio", $bio)
            field("where", $location)
            Spacer()
            Button("save") {
                store.me.displayName = name; store.me.bio = bio; store.me.location = location
                Task { await store.saveProfile() }
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .foregroundStyle(theme.ink)
        .padding(.top, 28)
        .phodoPage()
        .onAppear { name = store.me.displayName; bio = store.me.bio; location = store.me.location }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(spacing: 8) {
            FieldLabel(label)
            TextField("", text: text).font(PhFont.body(20))
            InkLine()
        }
    }
}

struct SettingsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("settings").font(PhFont.title(34))
            FieldLabel("your color")
            ColorPresetPicker()
            FieldLabel("daily nudge")
            ReminderPicker()
            InkLine()
            Button("sign out") { dismiss(); Task { await store.signOut() } }
                .font(PhFont.mono(15))
            Button("delete my account") { confirmDelete = true }
                .font(PhFont.mono(15)).foregroundStyle(theme.softInk)
            if let deleteError { Text(deleteError).font(PhFont.mono(13)) }
            Spacer()
        }
        .foregroundStyle(theme.ink)
        .padding(.top, 28)
        .phodoPage()
        .confirmationDialog("delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("delete everything", role: .destructive) {
                Task {
                    do { try await store.deleteAccount(); dismiss() }
                    catch { deleteError = error.localizedDescription.lowercased() }
                }
            }
        } message: {
            Text("all your posts, photos, friends and boards are deleted for good. this can't be undone.")
        }
    }

    @State private var confirmDelete = false
    @State private var deleteError: String?
}
