import SwiftUI

/// After the first sign-in: claim a username (+13+ check) → your color → daily nudge.
struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var step = 0
    @State private var username = ""
    @State private var displayName = ""
    @State private var birthday = Date()
    @State private var available: Bool?
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("phodo").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                Spacer()
                Text("\(step + 1)/3").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
            }
            .padding(.top, 12)

            ScrollView {
                Group {
                    switch step {
                    case 0: you
                    case 1: color
                    default: nudge
                    }
                }
                .transition(.opacity)
            }
            .scrollDismissesKeyboard(.interactively)

            if let errorText { Text(errorText).font(PhFont.mono(13)) }

            HStack(spacing: 14) {
                if step > 0 {
                    Button("skip") { Task { await next() } }.font(PhFont.mono(15)).frame(minWidth: 60, minHeight: 44)
                }
                Button { Task { await next() } } label: {
                    if busy { ProgressView().tint(theme.bg) } else { Text(step < 2 ? "next" : "let's go") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || (step == 0 && (!Username.isValid(Username.clean(username)) || available == false)))
            }
            .padding(.bottom, 12)
        }
        .foregroundStyle(theme.ink)
        .phodoPage()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .font(PhFont.bold(17))
            }
        }
    }

    // MARK: steps

    private var you: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("hi. who's\nthis?").font(PhFont.title(48))
            Text("one pic a day. just for your people.").font(PhFont.mono(14)).foregroundStyle(theme.softInk)

            VStack(spacing: 8) {
                FieldLabel("username")
                HStack {
                    Text("@").font(PhFont.body(22)).foregroundStyle(theme.softInk)
                    TextField("", text: $username).font(PhFont.body(22))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    availabilityBadge
                }
                InkLine()
            }
            .task(id: username) { await checkAvailability() }

            VStack(spacing: 8) {
                FieldLabel("name")
                TextField("", text: $displayName).font(PhFont.body(22))
                InkLine()
            }

            VStack(spacing: 8) {
                FieldLabel("birthday (we only keep whether you're 13+)")
                DatePicker("", selection: $birthday, in: ...Date(), displayedComponents: .date)
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var availabilityBadge: some View {
        let clean = Username.clean(username)
        if clean.isEmpty {
            EmptyView()
        } else if !Username.isValid(clean) {
            Text("2–24 chars").font(PhFont.mono(12)).foregroundStyle(theme.softInk)
        } else if let available {
            Text(available ? "✓ free" : "taken").font(PhFont.mono(12))
        }
    }

    private var color: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("pick your\ncolor").font(PhFont.title(48))
            Text("you can change it anytime").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
            ColorPresetPicker()
            MiniTodayPreview()
        }
    }

    private var nudge: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("daily\nnudge?").font(PhFont.title(48))
            Text("one gentle reminder. no streak guilt.").font(PhFont.mono(14)).foregroundStyle(theme.softInk)
            ReminderPicker()
        }
    }

    // MARK: actions

    private func checkAvailability() async {
        available = nil
        let clean = Username.clean(username)
        guard Username.isValid(clean) else { return }
        try? await Task.sleep(for: .milliseconds(350))   // wait until they stop typing
        guard !Task.isCancelled else { return }
        available = await store.isAvailable(clean)
    }

    private func next() async {
        errorText = nil
        if step == 0 {
            busy = true; defer { busy = false }
            do {
                try await store.claimProfile(username: username, displayName: displayName, birthday: birthday)
            } catch {
                errorText = error.localizedDescription.lowercased()
                return
            }
        }
        if step < 2 { withAnimation { step += 1 } } else { await store.finishOnboarding() }
    }
}

/// Swatches; tapping one recolors the whole app live.
struct ColorPresetPicker: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FieldLabel("light")
            grid(ThemePreset.light)
            FieldLabel("dark")
            grid(ThemePreset.darks)
        }
    }

    private func grid(_ presets: [ThemePreset]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(presets) { preset in
                let t = Theme(preset: preset)
                let selected = preset.id == store.themeID
                Button { store.setTheme(preset) } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 0) { t.bg; t.photoTint; t.ink }
                            .frame(height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(t.ink, lineWidth: selected ? 2.5 : 1))
                        Text(preset.name).font(PhFont.mono(13))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// A tiny "today" screen so people see what their color looks like.
private struct MiniTodayPreview: View {
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("today").font(PhFont.title(26))
            HStack(spacing: 10) {
                PhotoTile(image: nil, aspect: 1.1)
                VStack(alignment: .leading, spacing: 8) {
                    Text("iced latte walk").font(PhFont.body(15))
                    TagChip(text: "#coffee", selected: true)
                    TagChip(text: "#nap")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radius).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radius).stroke(theme.ink, lineWidth: Metrics.line))
    }
}

struct ReminderPicker: View {
    @Environment(AppStore.self) private var store
    @State private var on = false
    @State private var time = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $on) { Text("remind me").font(PhFont.body(20)) }
            if on {
                DatePicker("at", selection: $time, displayedComponents: .hourAndMinute)
                    .font(PhFont.mono(15))
            }
        }
        .onAppear {
            on = store.reminderTime != nil
            if let t = store.reminderTime { time = t }
        }
        .onChange(of: on) { _, isOn in Task { await store.setReminder(isOn ? time : nil) } }
        .onChange(of: time) { _, t in if on { Task { await store.setReminder(t) } } }
    }
}
