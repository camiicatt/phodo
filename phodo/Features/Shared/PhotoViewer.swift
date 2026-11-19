import SwiftUI

/// Full-screen photo: pinch to zoom, double-tap to zoom in/out,
/// swipe down (or tap ✕) to close.
struct PhotoViewer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let post: Post

    @State private var comments: [Comment] = []
    @State private var showComments = false

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// Not zoomed: how far the frame has been pulled (toss it away to close).
    @State private var toss: CGSize = .zero
    @State private var flying = false

    private var zoomed: Bool { scale > 1 }
    private var pulled: CGFloat { hypot(toss.width, toss.height) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // the normal page color; fades a little while you swipe it away
            theme.bg.opacity(1 - min(pulled / 500, 0.6)).ignoresSafeArea()

            VStack(spacing: 14) {
                Spacer(minLength: 56)

                // one frame, in the theme's color, around who posted it, the photo and the caption
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Avatar(person: post.author, size: 36)
                        Text("@\(post.author.username)").font(PhFont.bold(18)).lineLimit(1)
                        Text("· \(post.day.short)").font(PhFont.mono(13)).opacity(0.8)
                        Spacer(minLength: 0)
                    }
                    .opacity(zoomed ? 0 : 1)

                    photo
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.ink, lineWidth: Metrics.line))
                        .scaleEffect(scale)
                        .offset(x: offset.width, y: offset.height)
                        .zIndex(1)
                        .accessibilityLabel(post.caption.isEmpty ? "photo" : post.caption)

                    if !post.caption.isEmpty {
                        Text(post.caption).font(PhFont.body(19))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(zoomed ? 0 : 1)
                    }
                }
                .foregroundStyle(theme.ink)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.frame))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.ink, lineWidth: 1.5).opacity(zoomed ? 0 : 1))
                .zIndex(1)
                .contentShape(Rectangle())
                .gesture(zoom.simultaneously(with: pan))
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.3)) {
                        if zoomed { reset() } else { scale = 2.5; lastScale = 2.5 }
                    }
                }

                // little doodle row under the frame
                Doodles().frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .opacity(zoomed ? 0 : 1)

                CommentsPreview(comments: comments) { showComments = true }
                    .opacity(zoomed ? 0 : 1)

                Spacer(minLength: 24)
            }
            .padding(.horizontal, Metrics.margin)
            // the toss: follows your finger, leans the way you pull, shrinks a touch
            .scaleEffect(1 - min(pulled / 1600, 0.12))
            .rotationEffect(.degrees(Double(toss.width) / 18 + (flying ? Double(toss.width.sign == .minus ? -12 : 12) : 0)))
            .offset(toss)

            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.ink).frame(width: 44, height: 44)
                    .background(Circle().fill(theme.card))
                    .overlay(Circle().stroke(theme.ink, lineWidth: Metrics.line))
            }
            .buttonStyle(SquishStyle())
            .accessibilityLabel("close")
            .padding(.trailing, Metrics.margin).padding(.top, 8)
            .opacity(pulled > 0 ? 0 : 1)
        }
        .animation(.easeOut(duration: 0.15), value: zoomed)
        .animation(.easeOut(duration: 0.2), value: comments.count)
        .task { comments = await store.comments(on: post) }
        .sheet(isPresented: $showComments) {
            CommentsSheet(post: post, comments: $comments)
                .environment(\.theme, theme)
                .presentationDetents([.medium, .large])
                .presentationBackground(theme.bg)
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    @ViewBuilder
    private var photo: some View {
        if let image = post.image {
            Image(uiImage: image).resizable().scaledToFit()
        } else if let url = post.fullURL ?? post.thumbURL {
            // holds the photo's shape; the small version (already cached from the
            // feed) shows right away, then the full size fades in over it
            (post.tint ?? theme.photoTint)
                .aspectRatio(1 / post.aspect, contentMode: .fit)
                .overlay {
                    CachedImage(url: url) {
                        CachedImage(url: post.thumbURL)
                    }
                }
        } else {
            Rectangle().fill(post.tint ?? theme.photoTint).aspectRatio(1 / post.aspect, contentMode: .fit)
        }
    }

    private var zoom: some Gesture {
        MagnificationGesture()
            .onChanged { value in scale = max(1, min(lastScale * value, 5)) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.02 { withAnimation(.spring(response: 0.3)) { reset() } }
            }
    }

    /// Zoomed in: drag to look around. Not zoomed: pull the frame any way and toss it to close.
    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !flying else { return }
                if zoomed {
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                } else {
                    toss = value.translation
                }
            }
            .onEnded { value in
                guard !flying else { return }
                if zoomed { lastOffset = offset; return }
                let flick = value.predictedEndTranslation
                if hypot(value.translation.width, value.translation.height) > 140
                    || hypot(flick.width, flick.height) > 500 {
                    fly(towards: flick)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { toss = .zero }
                }
            }
    }

    /// Send the frame off-screen in the direction it was thrown, then close.
    private func fly(towards direction: CGSize) {
        let length = max(hypot(direction.width, direction.height), 1)
        let far: CGFloat = 1100
        withAnimation(.easeIn(duration: 0.22)) {
            flying = true          // adds a little extra spin on the way out
            toss = CGSize(width: direction.width / length * far, height: direction.height / length * far)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            var quiet = Transaction(); quiet.disablesAnimations = true   // no second slide-down from iOS
            withTransaction(quiet) { dismiss() }
        }
    }

    private func reset() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
    }
}

/// ☾ ✧ (=^･ω･^=) ✧ ☽ — line-art moons and stars around a little ascii cat.
private struct Doodles: View {
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon")
            Image(systemName: "sparkle").font(.system(size: 11, weight: .light))
            Image(systemName: "star").font(.system(size: 12, weight: .light))
            Text("=^･ω･^=").font(PhFont.mono(15))
            Image(systemName: "star").font(.system(size: 12, weight: .light))
            Image(systemName: "sparkle").font(.system(size: 11, weight: .light))
            Image(systemName: "moon").scaleEffect(x: -1)
        }
        .font(.system(size: 15, weight: .light))
        .foregroundStyle(theme.softInk)
        .accessibilityHidden(true)
    }
}
