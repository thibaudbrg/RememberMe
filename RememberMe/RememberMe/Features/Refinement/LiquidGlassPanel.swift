import SwiftUI

/// Plain horizontal stroke for map legends — a short flat line, not a capsule outline.
/// Used by both the Compare routes legend and the trip-detail mini-map legend.
struct LegendLine: View {
    let color: Color
    let dashed: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .butt, dash: dashed ? [3, 2] : [])
            )
        }
        .frame(width: 18, height: 4)
    }
}

/// Backgrounds the receiver with Liquid Glass on iOS 26+ and falls back to `.thinMaterial`
/// on iOS 17–25. Same call site, no per-screen `if #available` plumbing.
extension View {
    @ViewBuilder
    func liquidGlassPanel<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.thinMaterial, in: shape)
        }
    }

    /// Variant that fills the view's bounding rectangle (no shape clip). Use for full-bleed
    /// bars like the Compare routes bottom action panel.
    @ViewBuilder
    func liquidGlassPanel() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Rectangle())
        } else {
            self.background(.thinMaterial)
        }
    }
}
