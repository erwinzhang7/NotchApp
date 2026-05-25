import SwiftUI

/// Panel outline drawn into an expanded canvas. The top edge spans the full
/// canvas width; on each side a cubic Bezier sweeps inward and down with
/// smooth tangents to the body's vertical edges (which are inset by
/// `topSweep` on each side). The bottom keeps the existing convex rounded
/// corners at body width.
///
/// Render frame must be wider than the hitbox: `canvasWidth = bodyWidth + 2 * topSweep`.
struct NotchPanelShape: Shape {
    var topSweep: CGFloat
    var bottomConvexRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let s = max(0, topSweep)
        let br = max(0, bottomConvexRadius)
        let x0 = rect.minX
        let y0 = rect.minY
        let W = rect.width
        let H = rect.height
        let bodyL = x0 + s
        let bodyR = x0 + W - s

        // Start at top-left of the expanded canvas.
        path.move(to: CGPoint(x: x0, y: y0))
        // Top edge spans the full canvas width.
        path.addLine(to: CGPoint(x: x0 + W, y: y0))

        // Top-right outward sweep: smooth Bezier from canvas top-right down
        // to body's top-right. Tangent at start continues the top edge to
        // the right; tangent at end matches the body's vertical side going
        // down. The curve bulges outward (to the upper-right) before
        // settling onto the body.
        path.addCurve(
            to: CGPoint(x: bodyR, y: y0 + s),
            control1: CGPoint(x: x0 + W + s, y: y0),
            control2: CGPoint(x: bodyR, y: y0)
        )

        // Body right edge down to bottom convex corner.
        path.addLine(to: CGPoint(x: bodyR, y: y0 + H - br))

        path.addArc(
            center: CGPoint(x: bodyR - br, y: y0 + H - br),
            radius: br,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        // Bottom edge.
        path.addLine(to: CGPoint(x: bodyL + br, y: y0 + H))

        path.addArc(
            center: CGPoint(x: bodyL + br, y: y0 + H - br),
            radius: br,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )

        // Body left edge up to the start of the top-left sweep.
        path.addLine(to: CGPoint(x: bodyL, y: y0 + s))

        // Top-left outward sweep (mirror of top-right). Tangent at start
        // matches the body's vertical side going up; tangent at end
        // continues the top edge going right (into the move-to point).
        path.addCurve(
            to: CGPoint(x: x0, y: y0),
            control1: CGPoint(x: bodyL, y: y0),
            control2: CGPoint(x: x0 - s, y: y0)
        )

        path.closeSubpath()
        return path
    }
}
