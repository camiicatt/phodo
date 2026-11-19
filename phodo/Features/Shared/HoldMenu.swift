import SwiftUI

/// Hold a post → three thin-outlined bubbles fan out around your finger:
/// save · love · see @them (on your own posts: who sees it).
/// Slide onto one and let go. Let go anywhere else to cancel.
///
/// The bubbles draw in a layer above the whole screen (`holdMenuHost()`), so they
/// can spill over neighboring posts and screen edges.
@Observable
final class HoldMenu {
    enum Choice: Int, CaseIterable { case save, love, third }

    /// The post being held (nil = closed).
    private(set) var post: Post?
    /// Finger position, in screen coordinates.
    private(set) var origin: CGPoint = .zero
    private(set) var finger: CGPoint = .zero
    private(set) var hot: Choice?
    /// Bubble centers, in screen coordinates.
    private(set) var spots: [CGPoint] = []

    // what the host shows after a choice
    var note: String?
    var noteCanChange = false
    var boardPicker: Post?
    var profile: Person?
    var visibilityFor: Post?
    /// The post "change" on the note should open the board picker for.
    var lastSavedPost: Post?

    /// Bumped to drive haptics.
    private(set) var opens = 0
    private(set) var hovers = 0
    private(set) var picks = 0

    private var screen: CGSize = .zero
    static let radius: CGFloat = 84
    static let hitSize: CGFloat = 38

    func setScreen(_ size: CGSize) { screen = size }

    func open(_ post: Post, at point: CGPoint) {
        guard self.post == nil else { return }
        self.post = post
        origin = point; finger = point; hot = nil
        spots = Self.fan(around: point, in: screen)
        opens += 1
    }

    func move(to point: CGPoint) {
        guard post != nil else { return }
        finger = point
        let near = spots.enumerated()
            .map { ($0.offset, hypot($0.element.x - point.x, $0.element.y - point.y)) }
            .filter { $0.1 < Self.hitSize }
            .min { $0.1 < $1.1 }?.0
        let next = near.flatMap(Choice.init(rawValue:))
        if next != hot { hot = next; if next != nil { hovers += 1 } }
    }

    /// Finger lifted: returns what was picked (if anything) and closes.
    func release() -> (Choice, Post)? {
        defer { post = nil; hot = nil }
        guard let post, let hot else { return nil }
        picks += 1
        return (hot, post)
    }

    /// Closed without picking (the system cancelled the touch).
    @discardableResult
    func cancel() -> Bool {
        let wasOpen = post != nil
        post = nil; hot = nil
        return wasOpen
    }

    /// Three spots on an arc, pointing from the finger toward the middle of the
    /// screen, so they never fall off an edge.
    static func fan(around p: CGPoint, in size: CGSize) -> [CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var angle = atan2(center.y - p.y, center.x - p.x)
        // mostly upward unless you're near the top: flip a downward angle up
        // (so left side fans up-right, right side fans up-left), and keep it off flat
        if p.y > 220 {
            if angle > 0 { angle = -angle }
            angle = min(max(angle, -.pi + 0.45), -0.45)
        }
        let spread: CGFloat = 0.85        // ≈ 49° between bubbles
        return [-1, 0, 1].map { i in
            let a = angle + CGFloat(i) * spread
            return CGPoint(x: p.x + radius * cos(a), y: p.y + radius * sin(a))
        }
    }

    /// Do what the bubble says.
    @MainActor
    func perform(_ choice: Choice, on post: Post, store: AppStore) async {
        switch choice {
        case .save:
            lastSavedPost = post
            if let board = store.quickSaveBoard {
                if board.postIDs.contains(post.id) {
                    showNote("already in #\(board.name)", canChange: true)
                } else {
                    await store.toggle(post.id, in: board.id)
                    showNote("saved to #\(board.name)", canChange: true)
                }
            } else {
                boardPicker = post            // no boards yet → pick / make one
            }
        case .love:
            let was = store.isLiked(post.id)
            await store.toggleLike(post)
            if !was { showNote("loved it", canChange: false) }
        case .third:
            if post.author.id == store.me.id { visibilityFor = post } else { profile = post.author }
        }
    }

    func showNote(_ text: String, canChange: Bool) {
        note = text; noteCanChange = canChange
        let shown = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            if self.note == shown { withAnimation(.spring(response: 0.35)) { self.note = nil } }
        }
    }
}

extension EnvironmentValues {
    @Entry var holdMenu: HoldMenu? = nil
}

extension View {
    /// Draws the hold-to-save bubbles above this whole view. Put it on each screen
    /// root that shows posts (the tab view, and sheets like someone's profile).
    func holdMenuHost() -> some View { modifier(HoldMenuHost()) }
}

private struct HoldMenuHost: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var menu = HoldMenu()

    func body(content: Content) -> some View {
        content
            .environment(\.holdMenu, menu)
            .scrollDisabled(menu.post != nil)   // while the bubbles are open, sliding picks instead of scrolling
            .overlay {
                GeometryReader { geo in
                    let frame = geo.frame(in: .global)
                    ZStack {
                        if menu.post != nil {
                            theme.ink.opacity(0.22).ignoresSafeArea()
                                .transition(.opacity)
                                .allowsHitTesting(false)
                            bubbles(offset: frame.origin)
                        }
                        if let note = menu.note {
                            noteBar(note)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                                .padding(.bottom, 96)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .onAppear { menu.setScreen(UIScreen.main.bounds.size) }
                }
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.15), value: menu.post?.id)
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: menu.opens)
            .sensoryFeedback(.selection, trigger: menu.hovers)
            .sensoryFeedback(.success, trigger: menu.picks)
            .sheet(item: $menu.boardPicker) { post in
                SaveToBoardSheet(post: post).environment(\.theme, theme).presentationDetents([.medium, .large])
            }
            .sheet(item: $menu.profile) { person in
                PersonProfileView(person: person).environment(\.theme, theme)
            }
            .confirmationDialog("who sees it?", isPresented: Binding(
                get: { menu.visibilityFor != nil }, set: { if !$0 { menu.visibilityFor = nil } }),
                titleVisibility: .visible, presenting: menu.visibilityFor) { post in
                ForEach([PostVisibility.friends, .everyone, .justMe], id: \.self) { v in
                    Button(v.label) { Task { await store.setVisibility(post, to: v) } }
                }
            }
    }

    /// The three bubbles + their labels, positioned in this layer's coordinates.
    @ViewBuilder
    private func bubbles(offset: CGPoint) -> some View {
        if let post = menu.post {
            let mine = post.author.id == store.me.id
            let liked = store.isLiked(post.id)
            let saved = store.isSaved(post.id)
            let items: [(icon: String, label: String)] = [
                (saved ? "bookmark.fill" : "bookmark", "save"),
                (liked ? "heart.fill" : "heart", liked ? "unlove" : "love"),
                mine ? ("eye", "who sees it") : ("person", "see @\(post.author.username)"),
            ]
            // where your finger went down
            Circle().stroke(theme.card, lineWidth: 1.5)
                .frame(width: 34, height: 34)
                .position(x: menu.origin.x - offset.x, y: menu.origin.y - offset.y)
            ForEach(Array(menu.spots.enumerated()), id: \.offset) { i, spot in
                let on = menu.hot?.rawValue == i
                Bubble(icon: items[i].icon, label: items[i].label, on: on, delay: Double(i) * 0.035)
                    .position(x: spot.x - offset.x, y: spot.y - offset.y)
            }
        }
    }

    private func noteBar(_ text: String) -> some View {
        HStack {
            Text(text).font(PhFont.body(15))
            Spacer()
            if menu.noteCanChange, let post = menu.lastSavedPost {
                Button("change") { menu.note = nil; menu.boardPicker = post }
                    .font(PhFont.mono(13))
            }
        }
        .foregroundStyle(theme.bg)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Capsule().fill(theme.ink))
        .padding(.horizontal, Metrics.margin)
    }
}

private struct Bubble: View {
    @Environment(\.theme) private var theme
    let icon: String
    let label: String
    let on: Bool
    let delay: Double
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle().fill(on ? theme.ink : theme.card)
            Circle().stroke(theme.ink, lineWidth: Metrics.line)
            Image(systemName: icon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(on ? theme.card : theme.ink)
        }
        .frame(width: 52, height: 52)
        .overlay(alignment: .top) {
            Text(label)
                .font(PhFont.mono(12))
                .foregroundStyle(theme.bg)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(theme.ink))
                .fixedSize()
                .offset(y: -34)
                .opacity(on ? 1 : 0)
        }
        .scaleEffect(shown ? (on ? 1.2 : 1) : 0.2)
        .opacity(shown ? 1 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.62), value: on)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.6).delay(delay)) { shown = true }
        }
        .accessibilityHidden(true)
    }
}
