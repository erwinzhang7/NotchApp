import SwiftUI

/// Panel outline: square top corners (flush to screen edge), convex
/// rounded bottom corners.
struct NotchPanelShape: Shape {
    var bottomConvexRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let br = max(0, bottomConvexRadius)
        let x0 = rect.minX
        let y0 = rect.minY
        let W = rect.width
        let H = rect.height

        path.move(to: CGPoint(x: x0, y: y0))
        path.addLine(to: CGPoint(x: x0 + W, y: y0))
        path.addLine(to: CGPoint(x: x0 + W, y: y0 + H - br))

        path.addArc(
            center: CGPoint(x: x0 + W - br, y: y0 + H - br),
            radius: br,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        path.addLine(to: CGPoint(x: x0 + br, y: y0 + H))

        path.addArc(
            center: CGPoint(x: x0 + br, y: y0 + H - br),
            radius: br,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )

        path.addLine(to: CGPoint(x: x0, y: y0))
        path.closeSubpath()
        return path
    }
}
