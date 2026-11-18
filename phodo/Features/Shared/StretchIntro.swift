import SwiftUI

/// Launch intro: the curled-up phodo cat wakes up — a little squash, a big
/// stretch up and forward, then settles — and the app fades in.
/// The stretch itself is 280 ms, after a 150 ms rest while iOS opens the app.
struct StretchIntro: View {
    @Environment(\.theme) private var theme
    /// True once phodo knows who you are (signed in or not). The cat stays until then.
    let ready: Bool
    let onFinish: () -> Void

    @State private var play = false
    @State private var stretched = false
    @State private var slow = false          // still waiting after the stretch → say so
    // `ready` copied into state: the .task closure keeps the value from when it started,
    // but @State always reads the latest
    @State private var isReady = false
    @State private var finished = false

    private struct Pose {
        var sx: CGFloat = 1      // width
        var sy: CGFloat = 1      // height (anchored at the bottom: paws stay on the floor)
        var lift: CGFloat = 0    // hop off the ground
        var tilt: Double = 0     // front end up
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            Image("CatLines")
                .renderingMode(.template)
                .resizable().scaledToFit()
                .foregroundStyle(theme.ink)
                .frame(width: 190)
                .keyframeAnimator(initialValue: Pose(), trigger: play) { cat, pose in
                    cat.scaleEffect(x: pose.sx, y: pose.sy, anchor: .bottom)
                        .rotationEffect(.degrees(pose.tilt), anchor: .bottomLeading)
                        .offset(y: -pose.lift)
                } keyframes: { _ in
                    // 0–70 ms: scrunch down (getting ready)
                    // 70–190 ms: up and stretch, chest forward
                    // 190–280 ms: settle back, a tiny bounce
                    KeyframeTrack(\.sx) {
                        CubicKeyframe(1.06, duration: 0.07)
                        SpringKeyframe(0.90, duration: 0.12)
                        SpringKeyframe(1.0, duration: 0.09, spring: .bouncy)
                    }
                    KeyframeTrack(\.sy) {
                        CubicKeyframe(0.88, duration: 0.07)
                        SpringKeyframe(1.22, duration: 0.12)
                        SpringKeyframe(1.0, duration: 0.09, spring: .bouncy)
                    }
                    KeyframeTrack(\.lift) {
                        CubicKeyframe(0, duration: 0.07)
                        SpringKeyframe(10, duration: 0.12)
                        SpringKeyframe(0, duration: 0.09)
                    }
                    KeyframeTrack(\.tilt) {
                        CubicKeyframe(1, duration: 0.07)
                        SpringKeyframe(-4, duration: 0.12)
                        SpringKeyframe(0, duration: 0.09)
                    }
                }
                .accessibilityHidden(true)

            if slow {
                Text("waking up…")
                    .font(PhFont.mono(14)).foregroundStyle(theme.softInk)
                    .offset(y: 120)
                    .transition(.opacity)
            }
        }
        .task {
            // stay curled while iOS finishes its app-opening zoom, so the stretch is actually seen
            try? await Task.sleep(for: .milliseconds(150))
            play = true
            try? await Task.sleep(for: .milliseconds(280))
            stretched = true
            if isReady { finish(); return }
            // slow connection: after a bit, a quiet note instead of a spinner
            try? await Task.sleep(for: .seconds(1.5))
            if !isReady { withAnimation(.easeIn(duration: 0.2)) { slow = true } }
        }
        .onChange(of: ready, initial: true) { _, now in
            isReady = now
            if now && stretched { finish() }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }
}
