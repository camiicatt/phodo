import SwiftUI

/// The "look good?" screen. Opens right after you take or pick a pic (and again
/// from "edit"). Filters with little previews, a few fixes, and framing:
/// pick a shape, then pinch to zoom and drag to place it.
struct PhotoEditView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let base: CGImage
    @Binding var settings: EditSettings
    /// true right after taking / picking: the left button tosses the pic instead of just cancelling.
    var isNew = false
    let onDone: () -> Void
    var onToss: () -> Void = {}

    @State private var draft = EditSettings()
    @State private var section = 0                    // 0 filters, 1 adjust, 2 crop
    @State private var preview: UIImage?              // filters + fixes, not framed (framing is live)
    @State private var previewBase: CGImage?
    @State private var thumbs: [EditSettings.Mood: UIImage] = [:]
    // gesture starting points
    @State private var zoomStart: CGFloat?
    @State private var panStart: CGPoint?
    @State private var picks = 0                      // tiny tick when choosing a filter / shape

    var body: some View {
        VStack(spacing: 16) {
            header
            framedPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PillToggle(options: ["filters", "adjust", "crop"], selection: $section)
            Group {
                switch section {
                case 0: filterStrip
                case 1: adjustPanel
                default: cropPanel
                }
            }
            .frame(height: 112, alignment: .top)
            .transition(.opacity)
        }
        .padding(.bottom, 8)
        .phodoPage()
        .sensoryFeedback(.selection, trigger: picks)
        .onAppear {
            draft = settings
            previewBase = PhotoProcessor.resize(base, maxPixel: 1080)   // small copy = smooth sliders
        }
        .task(id: unframedKey) { render() }
        .task(id: draft.quarterTurns) { makeThumbs() }
    }

    // MARK: pieces

    private var header: some View {
        HStack {
            Button(isNew ? "toss it" : "cancel") {
                if isNew { onToss() }
                dismiss()
            }
            .font(PhFont.mono(15))
            Spacer()
            Text(isNew ? "look good?" : "edit").font(PhFont.bold(22))
            Spacer()
            Button { settings = draft; onDone(); dismiss() } label: {
                Text("use it ✓").font(PhFont.bold(15)).foregroundStyle(theme.bg)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(theme.ink))
            }
            .buttonStyle(SquishStyle())
        }
        .foregroundStyle(theme.ink)
        .padding(.top, 8)
    }

    /// The photo inside its frame. Pinch to zoom, drag to slide — exactly what gets posted.
    private var framedPreview: some View {
        GeometryReader { geo in
            if let preview {
                let img = preview.size
                let ratio = PhotoEditor.frameRatio(draft, imageSize: img)
                // biggest frame of that shape that fits the space
                let fw = min(geo.size.width, geo.size.height / ratio)
                let fh = fw * ratio
                // photo fills the frame at zoom 1, then grows with the pinch
                let fill = max(fw / img.width, fh / img.height)
                let dw = img.width * fill * draft.zoom, dh = img.height * fill * draft.zoom
                let slack = CGSize(width: dw - fw, height: dh - fh)

                Image(uiImage: preview)
                    .resizable()
                    .frame(width: dw, height: dh)
                    .offset(x: -draft.pan.x * slack.width / 2, y: -draft.pan.y * slack.height / 2)
                    .frame(width: fw, height: fh)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                        .stroke(theme.ink, lineWidth: Metrics.line))
                    .overlay { if section == 2 { thirdsGrid.clipShape(RoundedRectangle(cornerRadius: Metrics.radius)) } }
                    .contentShape(Rectangle())
                    .gesture(pinch.simultaneously(with: drag(slack: slack)))
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.35)) { draft.zoom = 1; draft.pan = .zero }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: draft.aspect)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: draft.quarterTurns)
            } else {
                ProgressView().frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    /// Rule-of-thirds lines while cropping.
    private var thirdsGrid: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(theme.card.opacity(0.7), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(EditSettings.Mood.allCases, id: \.self) { m in
                    Button { draft.mood = m; picks += 1 } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let t = thumbs[m] { Image(uiImage: t).resizable().scaledToFill() }
                                else { theme.photoTint }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(theme.ink, lineWidth: draft.mood == m ? 2.5 : Metrics.line))
                            Text(m == .none ? "original" : m.rawValue)
                                .font(PhFont.mono(12))
                                .foregroundStyle(draft.mood == m ? theme.ink : theme.softInk)
                        }
                    }
                    .buttonStyle(SquishStyle())
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 3)
        }
    }

    private var adjustPanel: some View {
        VStack(spacing: 6) {
            slider("bright", $draft.bright, -0.3...0.3)
            slider("contrast", $draft.contrast, 0.7...1.3)
            slider("warm", $draft.warm, -1...1)
            Button("reset fixes") { draft.bright = 0; draft.contrast = 1; draft.warm = 0 }
                .font(PhFont.mono(12)).foregroundStyle(theme.softInk)
        }
    }

    private var cropPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { draft.quarterTurns += 1; draft.pan = .zero; picks += 1 } label: { TagChip(text: "↻ rotate") }
                        .buttonStyle(SquishStyle())
                    ForEach(EditSettings.Aspect.allCases, id: \.self) { a in
                        Button { draft.aspect = a; draft.pan = .zero; picks += 1 } label: {
                            TagChip(text: a.rawValue, selected: draft.aspect == a)
                        }
                        .buttonStyle(SquishStyle())
                    }
                }
                .padding(1)
            }
            HStack {
                Text("pinch to zoom · drag to frame").font(PhFont.mono(12)).foregroundStyle(theme.softInk)
                Spacer()
                if draft.isFramed || draft.quarterTurns % 4 != 0 {
                    Button("reset crop") {
                        withAnimation(.spring(response: 0.35)) {
                            draft.aspect = .original; draft.zoom = 1; draft.pan = .zero; draft.quarterTurns = 0
                        }
                    }
                    .font(PhFont.mono(12)).foregroundStyle(theme.softInk)
                }
            }
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(PhFont.mono(13)).foregroundStyle(theme.softInk).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range).tint(theme.ink)
        }
    }

    // MARK: gestures

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let start = zoomStart ?? draft.zoom
                zoomStart = start
                draft.zoom = min(3, max(1, start * v.magnification))   // past 3x the posted photo gets soft
            }
            .onEnded { _ in zoomStart = nil }
    }

    private func drag(slack: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let start = panStart ?? draft.pan
                panStart = start
                // drag the photo right → the frame looks further left
                let x = slack.width > 0.5 ? start.x - v.translation.width / (slack.width / 2) : 0
                let y = slack.height > 0.5 ? start.y - v.translation.height / (slack.height / 2) : 0
                draft.pan = CGPoint(x: min(1, max(-1, x)), y: min(1, max(-1, y)))
            }
            .onEnded { _ in panStart = nil }
    }

    // MARK: rendering

    /// Filters + fixes + rotation. Framing changes don't need a re-render.
    private var unframedKey: EditSettings {
        var k = draft
        k.aspect = .original; k.zoom = 1; k.pan = .zero
        return k
    }

    private func render() {
        guard let previewBase else { return }
        preview = UIImage(cgImage: PhotoEditor.renderUnframed(previewBase, draft))
    }

    private func makeThumbs() {
        let small = PhotoProcessor.resize(base, maxPixel: 200)
        var out: [EditSettings.Mood: UIImage] = [:]
        for m in EditSettings.Mood.allCases {
            out[m] = UIImage(cgImage: PhotoEditor.thumbnail(small, turns: draft.quarterTurns, mood: m))
        }
        thumbs = out
    }
}
