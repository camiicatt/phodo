import SwiftUI

@main
struct PhodoApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .environment(store)
                .task {
                    PushDelegate.onToken = { token in Task { await store.savePushToken(token) } }
                    await store.start()
                }
                .onOpenURL { url in Task { await store.handleLink(url) } }
                .onChange(of: scenePhase) { _, phase in
                    // coming back to phodo: pick up new requests, friends' posts, likes
                    if phase == .active && store.phase == .ready { Task { await store.load() } }
                }
        }
    }
}

/// Builds the `Theme` from the user's color + light/dark mode and hands it to
/// every screen through the environment.
struct ThemedRoot: View {
    @Environment(AppStore.self) private var store
    @State private var intro = true      // the cat stretch plays once per launch

    var body: some View {
        let theme = Theme(preset: store.theme)
        Group {
            switch store.phase {
            case .loading:
                theme.bg.ignoresSafeArea()   // the cat intro covers this; no grey spinner
            case .signedOut: AuthView()
            case .needsProfile: OnboardingView()
            case .ready: RootTabView()
            }
        }
        .overlay {
            if intro {
                StretchIntro(ready: store.phase != .loading) {
                    withAnimation(.easeOut(duration: 0.15)) { intro = false }
                }
                    .transition(.opacity)
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

    /// What the tab bar says. "boards" are called scrapbooks in the app.
    var label: String { self == .boards ? "scrapbooks" : rawValue }
}

struct RootTabView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var tab: Tab = .today
    /// +1 when moving right in the bar, -1 when moving left, so pages slide the matching way.
    @State private var direction: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    switch tab {
                    case .explore: FriendsFeedView()
                    case .today: TodayView()
                    case .profile: ProfileView()
                    case .boards: BoardsView()
                    }
                }
                .id(tab)
                .transition(.pageSlide(direction))
            }
            .frame(maxHeight: .infinity)
            .clipped()
            if let problem = store.loadError {
                Text(problem).font(PhFont.mono(12)).foregroundStyle(theme.bg)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.ink)
            }
            TextTabBar(selection: Binding(get: { tab }, set: select))
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)   // keyboard covers the tab bar instead of pushing it up
        .background(theme.bg.ignoresSafeArea())
        .holdMenuHost()                               // hold a post → save / love / see bubbles
    }

    private func select(_ new: Tab) {
        guard new != tab else { return }
        let all = Tab.allCases
        direction = (all.firstIndex(of: new) ?? 0) > (all.firstIndex(of: tab) ?? 0) ? 1 : -1
        withAnimation(Motion.page) { tab = new }
    }
}

/// Shared motion so everything in phodo moves with the same soft bounce.
enum Motion {
    static let page = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let slide = Animation.spring(response: 0.38, dampingFraction: 0.72)   // pills: a little wobble
    static let press = Animation.spring(response: 0.25, dampingFraction: 0.6)
}

/// New page drifts in from the side it was tapped on; the old one drifts out the other way.
private struct PageSlide: ViewModifier {
    let offset: CGFloat
    let opacity: Double
    let scale: CGFloat
    func body(content: Content) -> some View {
        content.offset(x: offset).opacity(opacity).scaleEffect(scale, anchor: .bottom)
    }
}

extension AnyTransition {
    static func pageSlide(_ direction: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PageSlide(offset: 40 * direction, opacity: 0, scale: 0.98),
                                 identity: PageSlide(offset: 0, opacity: 1, scale: 1)),
            removal: .modifier(active: PageSlide(offset: -40 * direction, opacity: 0, scale: 0.98),
                               identity: PageSlide(offset: 0, opacity: 1, scale: 1)))
    }
}

/// The text-only bottom nav from the mockups. The selected tab sits in a soft
/// outlined pill that slides (with a little wobble) to whatever you tap.
struct TextTabBar: View {
    @Environment(\.theme) private var theme
    @Binding var selection: Tab
    @Namespace private var pill
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 10) {
            InkLine()
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    let on = selection == tab
                    Button { taps += 1; selection = tab } label: {
                        Text(tab.label)
                            .font(on ? PhFont.bold(19) : PhFont.body(19))
                            .foregroundStyle(on ? theme.ink : theme.softInk)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background {
                                if on {
                                    Capsule().fill(theme.chip)
                                        .overlay(Capsule().stroke(theme.ink, lineWidth: Metrics.line))
                                        .matchedGeometryEffect(id: "pill", in: pill)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SquishStyle())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .animation(Motion.slide, value: selection)
        }
        .padding(.horizontal, Metrics.margin - 8)
        .padding(.bottom, 4)
        .background(theme.bg)
        .sensoryFeedback(.selection, trigger: taps)
    }
}
