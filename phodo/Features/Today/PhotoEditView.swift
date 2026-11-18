import SwiftUI

/// Light editing: crop, rotate, bright / contrast / warm, and a few moods.
struct PhotoEditView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let base: CGImage
    @Binding var settings: EditSettings
    let onDone: () -> Void

    @State private var draft = EditSettings()
    @State private var preview: UIImage?
    @State private var previewBase: CGImage?

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button("cancel") { dismiss() }.font(PhFont.mono(15))
                Spacer()
                Text("edit").font(PhFont.bold(22))
                Spacer()
                Button("done") { settings = draft; onDone(); dismiss() }.font(PhFont.bold(17))
            }
            .foregroundStyle(theme.ink)
            .padding(.top, 8)

            Group {
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                            .stroke(theme.ink, lineWidth: Metrics.line))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { draft.quarterTurns += 1 } label: { TagChip(text: "↻ rotate") }.buttonStyle(SquishStyle())
                    ForEach(EditSettings.Aspect.allCases, id: \.self) { a in
                        Button { draft.aspect = a } label: { TagChip(text: a.rawValue, selected: draft.aspect == a) }
                            .buttonStyle(SquishStyle())
                    }
                }
            }

            HStack(spacing: 8) {
                ForEach(EditSettings.Mood.allCases, id: \.self) { m in
                    Button { draft.mood = m } label: { TagChip(text: m.rawValue, selected: draft.mood == m) }
                        .buttonStyle(SquishStyle())
                }
                Spacer(minLength: 0)
            }

            VStack(spacing: 6) {
                slider("bright", $draft.bright, -0.3...0.3)
                slider("contrast", $draft.contrast, 0.7...1.3)
                slider("warm", $draft.warm, -1...1)
            }

            Button("reset") { draft = EditSettings() }
                .font(PhFont.mono(13)).foregroundStyle(theme.softInk)
        }
        .phodoPage()
        .onAppear {
            draft = settings
            previewBase = PhotoProcessor.resize(base, maxPixel: 1080)   // small copy = smooth sliders
        }
        .task(id: draft) { render() }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(PhFont.mono(13)).foregroundStyle(theme.softInk).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range).tint(theme.ink)
        }
    }

    private func render() {
        guard let previewBase else { return }
        preview = UIImage(cgImage: PhotoEditor.render(previewBase, draft))
    }
}
