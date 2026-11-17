import SwiftUI

@main
struct PhodoApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .environment(store)
                .task { await store.start() }
                .onOpenURL { url in Task { await store.handleLink(url) } }
        }
    }
}

/// Builds the `Theme` from the user's color + light/dark mode and hands it to
/// every screen through the environment.
struct ThemedRoot: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let theme = Theme(preset: store.theme)
        Group {
            switch store.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.bg.ignoresSafeArea())
            case .signedOut: AuthView()
            case .needsProfile: OnboardingView()
            case .ready: RootTabView()
            }
        }
        .environment(\.theme, theme)
        // The user's theme decides light/dark, so the keyboard, pickers and status bar match it.
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .animation(.easeInOut, value: store.themeID)
        .animation(.easeInOut, value: store.phase)
    }
}

enum Tab: String, CaseIterable {
    case explore, today, profile, boards   // explore holds the friends / everyone toggle
}

struct RootTabView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var tab: Tab = .today

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .explore: FriendsFeedView()
                case .today: TodayView()
                case .profile: ProfileView()
                case .boards: BoardsView()
                }
            }
            .frame(maxHeight: .infinity)
            if let problem = store.loadError {
                Text(problem).font(PhFont.mono(12)).foregroundStyle(theme.bg)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.ink)
            }
            TextTabBar(selection: $tab)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)   // keyboard covers the tab bar instead of pushing it up
        .background(theme.bg.ignoresSafeArea())
    }
}

/// The text-only bottom nav from the mockups.
struct TextTabBar: View {
    @Environment(\.theme) private var theme
    @Binding var selection: Tab

    var body: some View {
        VStack(spacing: 12) {
            InkLine()
            HStack {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button { selection = tab } label: {
                        VStack(spacing: 4) {
                            Text(tab.rawValue)
                                .font(selection == tab ? PhFont.bold(20) : PhFont.body(20))
                                .foregroundStyle(selection == tab ? theme.ink : theme.softInk)
                            Rectangle().fill(selection == tab ? theme.ink : .clear).frame(height: 2)
                        }
                        .fixedSize()
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                    if tab != Tab.allCases.last { Spacer() }
                }
            }
        }
        .padding(.horizontal, Metrics.margin)
        .padding(.bottom, 4)
        .background(theme.bg)
    }
}
