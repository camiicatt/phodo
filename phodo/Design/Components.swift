import SwiftUI

// Small reusable pieces from "the vibe" style sheet.

struct ScreenHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    var trailing: String = ""

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .lastTextBaseline) {
                Text(title).font(PhFont.title(52)).foregroundStyle(theme.ink)
                Spacer()
                Text(trailing).font(PhFont.mono(14)).foregroundStyle(theme.softInk)
            }
            InkLine()
        }
    }
}

struct InkLine: View {
    @Environment(\.theme) private var theme
    var body: some View { Rectangle().fill(theme.ink).frame(height: Metrics.line) }
}

/// Mono label above a field ("caption", "tags").
struct FieldLabel: View {
    @Environment(\.theme) private var theme
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(PhFont.mono(13)).foregroundStyle(theme.softInk)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Filled ink capsule — "post it".
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PhFont.bold(20))
            .foregroundStyle(theme.bg)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Capsule().fill(theme.ink.opacity(isEnabled ? 1 : 0.35)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Outlined capsule — "edit profile".
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PhFont.bold(17))
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(Capsule().fill(configuration.isPressed ? theme.chip : theme.card))
            .overlay(Capsule().stroke(theme.ink, lineWidth: Metrics.line))
    }
}

/// #tag chip. Selected = ink fill, unselected = light chip, dashed = "+ add".
struct TagChip: View {
    @Environment(\.theme) private var theme
    let text: String
    var selected = false
    var dashed = false

    var body: some View {
        Text(text)
            .font(PhFont.mono(15))
            .foregroundStyle(selected ? theme.bg : theme.ink)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Capsule().fill(selected ? theme.ink : (dashed ? Color.clear : theme.chip)))
            .overlay(
                Capsule().stroke(theme.ink, style: StrokeStyle(lineWidth: Metrics.line, dash: dashed ? [4, 3] : []))
            )
            .contentShape(Capsule())
    }
}

/// Two-option pill toggle ("friends / just me", "pics / journal").
struct PillToggle: View {
    @Environment(\.theme) private var theme
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                Button { withAnimation(.snappy) { selection = i } } label: {
                    Text(options[i])
                        .font(PhFont.mono(15))
                        .foregroundStyle(selection == i ? theme.bg : theme.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 16).frame(minHeight: 42)
                        .background(Capsule().fill(selection == i ? theme.ink : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(theme.chip))
        .overlay(Capsule().stroke(theme.ink, lineWidth: Metrics.line))
        .fixedSize()
    }
}

/// A photo (or its placeholder) in a rounded, 1px-outlined frame.
/// `aspect` is height / width so masonry can lay out before the image loads.
struct PhotoTile: View {
    @Environment(\.theme) private var theme
    let image: UIImage?
    var url: URL? = nil
    var tint: Color? = nil
    var aspect: CGFloat = 1
    /// Varies placeholder brightness so neighboring tiles stay distinct.
    var seed: Int = 0

    private var placeholder: Color {
        [theme.photoTint, theme.sunken, theme.photoTint.opacity(0.75)][abs(seed) % 3]
    }

    var body: some View {
        Rectangle()
            .fill(tint ?? placeholder)
            .aspectRatio(1 / aspect, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if let url {
                    // TODO: swap for Nuke with a cache keyed by storage path (signed URLs change).
                    AsyncImage(url: url) { phase in
                        phase.image?.resizable().scaledToFill()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .stroke(theme.ink, lineWidth: Metrics.line))
    }
}

/// Two-column Pinterest-style layout. Each item goes into whichever column is
/// currently shorter, using `weight` (≈ aspect ratio + room for the caption).
struct Masonry<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    var spacing: CGFloat = 18
    let weight: (Item) -> CGFloat
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        let columns = split()
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<2, id: \.self) { i in
                VStack(spacing: spacing) {
                    ForEach(columns[i]) { cell($0) }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func split() -> [[Item]] {
        var columns: [[Item]] = [[], []]
        var heights: [CGFloat] = [0, 0]
        for item in items {
            let i = heights[0] <= heights[1] ? 0 : 1
            columns[i].append(item)
            heights[i] += weight(item)
        }
        return columns
    }
}

/// Simple wrapping row for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [(Int, CGFloat)] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].items.isEmpty {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let x = rows[rows.count - 1].items.isEmpty ? 0 : rows[rows.count - 1].width + spacing
            rows[rows.count - 1].items.append((i, x))
            rows[rows.count - 1].width = x + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

extension View {
    /// Standard page: themed background + side margins.
    func phodoPage() -> some View { modifier(PageModifier()) }
}

private struct PageModifier: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Metrics.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(theme.bg.ignoresSafeArea())
            .tint(theme.ink)
    }
}
