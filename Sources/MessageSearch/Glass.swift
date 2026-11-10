import SwiftUI

// Liquid Glass (macOS 26 and later) for the app's controls, with a material
// fallback on earlier systems. Glass is for the control layer that floats over
// content (the filter chip, the status bar), never for the results themselves.
// The search field gets its glass from the window toolbar it sits in.

extension View {
    /// Puts the view on a capsule of Liquid Glass.
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
        }
    }

    /// Puts the view on a rounded panel of Liquid Glass.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 14) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator))
        }
    }

    /// Floats `bar` over one edge. Scrolling content passes underneath it and,
    /// on macOS 26, blurs out as it approaches (the scroll edge effect).
    @ViewBuilder
    func floatingBar(edge: VerticalEdge, @ViewBuilder _ bar: () -> some View) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: edge, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: edge, spacing: 0, content: bar)
        }
    }

    /// The prominent glass button style where there is one.
    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
