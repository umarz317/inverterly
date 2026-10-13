import SwiftUI
import InverterCore

/// Today from midnight to midnight: solar as a soft filled curve, grid and load as lines over it.
struct TodayChart: View {
    let curve: DayCurve

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { canvas, size in draw(&canvas, size: size) }
                .accessibilityLabel("Chart of today's solar and load power")
            HStack(spacing: 10) {
                Text("Peak").font(.system(size: 10)).foregroundStyle(.tertiary)
                legend(color: .solarText, name: "Solar", watts: curve.peakPvW)
                legend(color: .gridText, name: "Grid", watts: curve.peakGridW)
                legend(color: .primary.opacity(0.75), name: "Load", watts: curve.peakLoadW)
                Spacer(minLength: 0)
            }
        }
    }

    private func legend(color: Color, name: String, watts: Double) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 8, height: 2.5)
            Text(name).foregroundStyle(.secondary)
            Text(PowerFormat.watts(watts)).monospacedDigit()
        }
        .font(.system(size: 10)).lineLimit(1).fixedSize()
    }

    private func draw(_ canvas: inout GraphicsContext, size: CGSize) {
        guard !curve.isEmpty else { return }
        // The day runs midnight to midnight in the plant's time zone, which the curve already knows.
        let dayStart = curve.dayStart
        let labelBand: CGFloat = 12
        let plot = CGRect(x: 0, y: 2, width: size.width, height: size.height - labelBand - 2)
        let top = niceCeiling(max(curve.peakPvW, curve.peakLoadW, curve.peakGridW, 500))
        let ink = Color.primary

        func x(_ date: Date) -> CGFloat {
            plot.minX + plot.width * min(1, max(0, date.timeIntervalSince(dayStart) / 86_400))
        }
        func y(_ watts: Double) -> CGFloat { plot.maxY - plot.height * min(1, max(0, watts / top)) }

        // Baseline, a mid line and hour marks.
        var grid = Path()
        grid.move(to: CGPoint(x: plot.minX, y: plot.maxY)); grid.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        canvas.stroke(grid, with: .color(ink.opacity(0.16)), lineWidth: 1)
        var mid = Path()
        mid.move(to: CGPoint(x: plot.minX, y: y(top / 2))); mid.addLine(to: CGPoint(x: plot.maxX, y: y(top / 2)))
        canvas.stroke(mid, with: .color(ink.opacity(0.07)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        for hour in [6, 12, 18] {
            let px = plot.minX + plot.width * Double(hour) / 24
            var tick = Path()
            tick.move(to: CGPoint(x: px, y: plot.maxY)); tick.addLine(to: CGPoint(x: px, y: plot.maxY + 3))
            canvas.stroke(tick, with: .color(ink.opacity(0.2)), lineWidth: 1)
            let label = hour == 12 ? "12 pm" : hour < 12 ? "\(hour) am" : "\(hour - 12) pm"
            canvas.draw(Text(label).font(.system(size: 9)).foregroundStyle(ink.opacity(0.4)),
                        at: CGPoint(x: px, y: plot.maxY + 8), anchor: .center)
        }
        canvas.draw(Text(PowerFormat.kilowatts(top)).font(.system(size: 9)).foregroundStyle(ink.opacity(0.4)),
                    at: CGPoint(x: plot.minX, y: plot.minY + 4), anchor: .leading)

        // Solar area.
        var area = Path()
        var line = Path()
        for (index, point) in curve.points.enumerated() {
            let p = CGPoint(x: x(point.time), y: y(point.pvW))
            if index == 0 { area.move(to: CGPoint(x: p.x, y: plot.maxY)); area.addLine(to: p); line.move(to: p) }
            else { area.addLine(to: p); line.addLine(to: p) }
        }
        if let last = curve.points.last { area.addLine(to: CGPoint(x: x(last.time), y: plot.maxY)) }
        area.closeSubpath()
        canvas.fill(area, with: .linearGradient(Gradient(colors: [Color.solarAccent.opacity(0.34), Color.solarAccent.opacity(0.04)]),
                                                startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
        canvas.stroke(line, with: .color(Color.solarAccent.opacity(0.95)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))

        // Grid and load lines.
        func trace(_ watts: KeyPath<DayCurvePoint, Double>) -> Path {
            var path = Path()
            for (index, point) in curve.points.enumerated() {
                let p = CGPoint(x: x(point.time), y: y(point[keyPath: watts]))
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            return path
        }
        canvas.stroke(trace(\.gridW), with: .color(Color.gridAccent.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        canvas.stroke(trace(\.loadW), with: .color(ink.opacity(0.75)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))

        // "Now" marker at the latest reading.
        if let last = curve.points.last {
            let px = x(last.time)
            var now = Path()
            now.move(to: CGPoint(x: px, y: plot.minY)); now.addLine(to: CGPoint(x: px, y: plot.maxY))
            canvas.stroke(now, with: .color(ink.opacity(0.14)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            let dot = CGRect(x: px - 2.5, y: y(last.loadW) - 2.5, width: 5, height: 5)
            canvas.fill(Path(ellipseIn: dot), with: .color(ink))
        }
    }

    /// Next round number of watts at or above `value`: 500, 1000, 2000, 3000, 4000, 5000, 6000, 8000, 10000…
    private func niceCeiling(_ value: Double) -> Double {
        let steps: [Double] = [500, 1000, 2000, 3000, 4000, 5000, 6000, 8000, 10_000, 12_000, 15_000, 20_000]
        return steps.first { $0 >= value } ?? (value / 5000).rounded(.up) * 5000
    }
}
