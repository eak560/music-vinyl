import AppKit
import SwiftUI

extension Color {
    /// Linear blend in sRGB. `Color.mix(with:by:)` is macOS 15, and this app
    /// targets 14.
    func blended(with other: Color, amount: Double) -> Color {
        let t = min(max(amount, 0), 1)
        guard let a = NSColor(self).usingColorSpace(.sRGB),
              let b = NSColor(other).usingColorSpace(.sRGB) else { return self }
        return Color(
            red: Double(a.redComponent) + (Double(b.redComponent) - Double(a.redComponent)) * t,
            green: Double(a.greenComponent) + (Double(b.greenComponent) - Double(a.greenComponent)) * t,
            blue: Double(a.blueComponent) + (Double(b.blueComponent) - Double(a.blueComponent)) * t
        )
    }
}

/// A list where each entry reacts to how close the pointer is: the label slides
/// out, its colour warms toward the accent, and the rule beside it lengthens.
/// Between the rules sit shorter ticks that grow with the same proximity.
struct LineSidebarList: View {
    let items: [String]
    /// Index drawn as permanently near — the playlist currently playing.
    var activeIndex: Int?
    var accent: Color = Color(red: 0.659, green: 0.333, blue: 0.969)
    var textColor: Color = Color(white: 0.77)
    var markerColor: Color = Color(white: 0.42)
    let onSelect: (Int) -> Void

    private let rowHeight: CGFloat = 19
    private let itemGap: CGFloat = 15
    private let markerLength: CGFloat = 42
    private let markerGap: CGFloat = 10
    private let proximityRadius: CGFloat = 88
    private let maxShift: CGFloat = 20
    private let tickScale: CGFloat = 0.5

    /// Pointer position in the list's own space; nil when it has left.
    @State private var pointerY: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: itemGap) {
            ForEach(items.indices, id: \.self) { index in
                row(index)
                    .frame(height: rowHeight, alignment: .leading)
            }
        }
        // Hover is read in this stack's coordinates, so a row's centre is pure
        // arithmetic rather than a GeometryReader per row.
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): pointerY = point.y
            case .ended: pointerY = nil
            }
        }
        .padding(.leading, markerLength + markerGap)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .animation(.easeOut(duration: 0.12), value: pointerY)
    }

    private func centre(of index: Int) -> CGFloat {
        CGFloat(index) * (rowHeight + itemGap) + rowHeight / 2
    }

    /// 0 at rest, 1 directly under the pointer, on a smoothstep curve.
    private func effect(_ index: Int) -> Double {
        var value = 0.0
        if let pointerY {
            let distance = abs(pointerY - centre(of: index))
            let p = max(0, 1 - distance / proximityRadius)
            value = p * p * (3 - 2 * p)
        }
        // The playing entry stays lit whether or not the pointer is near it.
        return activeIndex == index ? max(value, 0.85) : value
    }

    @ViewBuilder
    private func row(_ index: Int) -> some View {
        let e = effect(index)
        let tint = textColor.blended(with: accent, amount: e)

        HStack(spacing: 7) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .opacity(0.55 + e * 0.45)
            Text(items[index])
                .font(.system(size: 13))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .offset(x: e * maxShift)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            // The rule, drawn out into the leading padding.
            Rectangle()
                .fill(markerColor.blended(with: accent, amount: e))
                .frame(width: markerLength * (0.7 + e * 0.5), height: 1)
                .offset(x: -(markerLength + markerGap))
        }
        .overlay(alignment: .leading) {
            if index < items.count - 1 {
                Rectangle()
                    .fill(markerColor.opacity(0.5))
                    .frame(width: markerLength * tickScale * (0.7 + e * 0.6), height: 1)
                    .offset(x: -(markerLength + markerGap), y: rowHeight / 2 + itemGap / 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(index) }
    }
}
