import SwiftUI

/// The whole message history as a strip of time. Grey bars are how much was
/// said in each stretch; coloured bars are where the current search's strong
/// matches fall. It is redrawn on every keystroke, from a full pass that
/// scores every message. Clicking a year narrows the results to it; clicking
/// it again clears that.
struct TimelineStrip: View {
    let axis: TimeAxis
    let matches: [Float]
    @Binding var selectedYear: Int?

    private static let labelHeight: CGFloat = 13

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                let fraction = tap.location.x / max(1, geometry.size.width)
                guard let year = axis.years.first(where: { fraction >= $0.start && fraction < $0.end })?.year else { return }
                selectedYear = selectedYear == year ? nil : year
            })
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .help("Where matches fall over time. Click a year to narrow results to it.")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let bars = CGRect(x: 0, y: 0, width: size.width, height: size.height - Self.labelHeight)
        let count = axis.volume.count
        guard count > 0 else { return }
        let width = size.width / CGFloat(count)
        let selected = axis.years.first { $0.year == selectedYear }

        if let selected {
            let band = CGRect(x: selected.start * size.width, y: 0, width: (selected.end - selected.start) * size.width, height: size.height)
            context.fill(Path(roundedRect: band, cornerRadius: 5), with: .color(.accentColor.opacity(0.14)))
        }

        // Square roots keep quiet months visible next to busy ones.
        let mostVolume = max(1, axis.volume.max() ?? 1)
        let mostMatches = max(1, matches.max() ?? 1)
        for bucket in 0..<count {
            let x = CGFloat(bucket) * width
            let middle = (Double(bucket) + 0.5) / Double(count)
            let inFocus = selected.map { middle >= $0.start && middle < $0.end } ?? true

            let volume = CGFloat((axis.volume[bucket] / mostVolume).squareRoot()) * bars.height
            if volume > 0 {
                let rect = CGRect(x: x + 0.5, y: bars.maxY - volume, width: max(1, width - 1), height: volume)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.primary.opacity(inFocus ? 0.13 : 0.06)))
            }
            if bucket < matches.count, matches[bucket] > 0 {
                let height = max(2, CGFloat((matches[bucket] / mostMatches).squareRoot()) * bars.height)
                let rect = CGRect(x: x + 0.5, y: bars.maxY - height, width: max(1, width - 1), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.accentColor.opacity(inFocus ? 1 : 0.35)))
            }
        }

        // Year marks, skipping labels that would collide.
        var lastLabel = -CGFloat.infinity
        for year in axis.years {
            let x = year.start * size.width
            if year.start > 0 {
                context.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(.primary.opacity(0.15)))
            }
            guard x - lastLabel >= 36, size.width - x >= 30 else { continue }
            lastLabel = x
            let label = Text(verbatim: String(year.year))
                .font(.system(size: 9, weight: year.year == selectedYear ? .bold : .regular))
                .foregroundStyle(year.year == selectedYear ? Color.accentColor : Color.secondary)
            context.draw(label, at: CGPoint(x: x + 3, y: size.height - Self.labelHeight / 2), anchor: .leading)
        }
    }
}
