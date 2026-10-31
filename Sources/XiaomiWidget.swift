import SwiftUI
import WidgetKit
import Darwin

struct SensorEntry: TimelineEntry {
    let date: Date
    let temperature: Double?
    let humidity: Int?
    let updated: Date?
}
struct SensorProvider: TimelineProvider {
    func placeholder(in context: Context) -> SensorEntry {
        SensorEntry(date: Date(), temperature: 23.5, humidity: 48, updated: Date())
    }
    func getSnapshot(in context: Context, completion: @escaping (SensorEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SensorEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
    func current() -> SensorEntry {
        guard let info = getpwuid(getuid()), let home = info.pointee.pw_dir else {
            return SensorEntry(date: Date(), temperature: nil, humidity: nil, updated: nil)
        }
        let path = URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Xiaomi Sensor/widget-reading.json")
        guard let data = try? Data(contentsOf: path),
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Double],
              let temp = values["temperature"], let humidity = values["humidity"],
              let timestamp = values["timestamp"] else {
            return SensorEntry(date: Date(), temperature: nil, humidity: nil, updated: nil)
        }
        return SensorEntry(date: Date(), temperature: temp, humidity: Int(humidity), updated: Date(timeIntervalSince1970: timestamp))
    }
}
// Bevelled LCD segments match the physical sensor rather than a rounded digital font.
struct LCDSegment: Shape {
    let name: Character
    let thin: Bool
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let t = thin ? min(w * 0.10, h * 0.055) : min(w * 0.16, h * 0.09)
        let gap = t * 0.18
        let mid = h / 2
        func horizontal(_ y: CGFloat) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: t * 0.55, y: y))
            p.addLine(to: CGPoint(x: w - t * 0.55, y: y))
            p.addLine(to: CGPoint(x: w - t * 1.10, y: y + t))
            p.addLine(to: CGPoint(x: t * 1.10, y: y + t))
            p.closeSubpath()
            return p
        }
        func vertical(_ x: CGFloat, _ y1: CGFloat, _ y2: CGFloat, _ left: Bool) -> Path {
            var p = Path()
            let outer = left ? x : x + t
            let inner = left ? x + t : x
            p.move(to: CGPoint(x: outer, y: y1))
            p.addLine(to: CGPoint(x: inner, y: y1 + t * 0.55))
            p.addLine(to: CGPoint(x: inner, y: y2 - t * 0.55))
            p.addLine(to: CGPoint(x: outer, y: y2))
            p.closeSubpath()
            return p
        }
        switch name {
        case "a": return horizontal(0)
        case "g": return horizontal(mid - t / 2)
        case "d": return horizontal(h - t)
        case "f": return vertical(0, gap, mid - gap, true)
        case "b": return vertical(w - t, gap, mid - gap, false)
        case "e": return vertical(0, mid + gap, h - gap, true)
        case "c": return vertical(w - t, mid + gap, h - gap, false)
        default: return Path()
        }
    }
}

struct LCDNumber: View {
    let value: String
    var thin = false
    private let patterns: [Character: String] = ["0":"abcdef", "1":"bc", "2":"abged", "3":"abgcd", "4":"fgbc", "5":"afgcd", "6":"afgecd", "7":"abc", "8":"abcdefg", "9":"abfgcd", "-":"g"]
    var body: some View {
        GeometryReader { geo in
            let chars = Array(value)
            let widths = chars.map { $0 == "." ? CGFloat(6) : CGFloat(34) }
            let total = widths.reduce(0, +) + CGFloat(max(0, chars.count - 1)) * 5
            let scale = min(geo.size.width / max(total, 1), geo.size.height / 64)
            HStack(spacing: 5 * scale) {
                ForEach(Array(chars.enumerated()), id: \.offset) { index, char in
                    ZStack(alignment: .bottom) {
                        if char == "." {
                            Rectangle().frame(width: 5 * scale, height: 5 * scale)
                        } else {
                            ForEach(Array((patterns[char] ?? "").enumerated()), id: \.offset) { _, segment in
                                LCDSegment(name: segment, thin: thin)
                            }
                        }
                    }.frame(width: widths[index] * scale, height: 64 * scale, alignment: .bottom)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityHidden(true)
    }
}

// The LCD face is made of vector strokes, matching the sensor's segmented icon.
struct FaceStrokes: Shape {
    var happy: Bool
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.12, y: h * 0.05))
        p.addQuadCurve(to: CGPoint(x: w * 0.12, y: h * 0.95), control: CGPoint(x: w * -0.02, y: h * 0.50))
        p.move(to: CGPoint(x: w * 0.88, y: h * 0.05))
        p.addQuadCurve(to: CGPoint(x: w * 0.88, y: h * 0.95), control: CGPoint(x: w * 1.02, y: h * 0.50))
        for x in [CGFloat(0.29), CGFloat(0.70)] {
            p.move(to: CGPoint(x: w * (x - 0.07), y: h * 0.40))
            p.addLine(to: CGPoint(x: w * x, y: h * (happy ? 0.25 : 0.40)))
            p.addLine(to: CGPoint(x: w * (x + 0.07), y: h * 0.40))
        }
        p.move(to: CGPoint(x: w * 0.41, y: h * 0.80))
        p.addLine(to: CGPoint(x: w * 0.59, y: h * 0.80))
        return p
    }
}

struct ComfortFace: View {
    let happy: Bool
    var body: some View {
        GeometryReader { geo in
            FaceStrokes(happy: happy)
                .stroke(style: StrokeStyle(lineWidth: max(1, geo.size.height * 0.075), lineCap: .square, lineJoin: .miter))
        }.accessibilityHidden(true)
    }
}

struct BluetoothMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.5, y: 0))
        p.addLine(to: CGPoint(x: w * 0.5, y: h))
        p.addLine(to: CGPoint(x: w * 0.85, y: h * 0.74))
        p.addLine(to: CGPoint(x: w * 0.15, y: h * 0.27))
        p.move(to: CGPoint(x: w * 0.15, y: h * 0.73))
        p.addLine(to: CGPoint(x: w * 0.85, y: h * 0.26))
        p.addLine(to: CGPoint(x: w * 0.5, y: 0))
        return p
    }
}

struct SensorWidgetView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    var entry: SensorEntry
    private var usesTint: Bool { renderingMode != .fullColor }
    private var comfortable: Bool {
        guard let t = entry.temperature, let h = entry.humidity else { return false }
        return (19...27).contains(t) && (20...85).contains(h)
    }
    var body: some View {
        GeometryReader { geo in
            let unit = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: unit * 0.12)
                    .fill(usesTint ? Color.clear : Color(red: 0.92, green: 0.92, blue: 0.92))
                RoundedRectangle(cornerRadius: unit * 0.018)
                    .fill(usesTint ? Color.primary.opacity(0.16) : Color(red: 0.59, green: 0.59, blue: 0.58))
                    .overlay(RoundedRectangle(cornerRadius: unit * 0.018)
                        .stroke(usesTint ? Color.primary.opacity(0.3) : Color.black.opacity(0.24), lineWidth: unit * 0.009))
                    .frame(width: unit * 0.67, height: unit * 0.67)
                    .shadow(color: .black.opacity(0.15), radius: unit * 0.012, x: 0, y: unit * 0.003)
                LCDNumber(value: entry.temperature.map { String(format: "%.1f", $0) } ?? "--.-")
                    .frame(width: unit * 0.47, height: unit * 0.23)
                    .position(x: unit * 0.465, y: unit * 0.39)
                BluetoothMark()
                    .stroke(style: StrokeStyle(lineWidth: unit * 0.005, lineCap: .round, lineJoin: .round))
                    .frame(width: unit * 0.025, height: unit * 0.045)
                    .position(x: unit * 0.75, y: unit * 0.30)
                Text("°C")
                    .font(.system(size: unit * 0.066, weight: .regular, design: .monospaced))
                    .position(x: unit * 0.75, y: unit * 0.465)
                ComfortFace(happy: comfortable)
                    .frame(width: unit * 0.27, height: unit * 0.13)
                    .position(x: unit * 0.37, y: unit * 0.65)
                LCDNumber(value: entry.humidity.map { String($0) } ?? "--", thin: true)
                    .frame(width: unit * 0.18, height: unit * 0.125)
                    .position(x: unit * 0.61, y: unit * 0.65)
                Text("%")
                    .font(.system(size: unit * 0.06, weight: .regular, design: .monospaced))
                    .position(x: unit * 0.745, y: unit * 0.68)
            }
            .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
        }
        .containerBackground(for: .widget) { if !usesTint { Color(red: 0.92, green: 0.92, blue: 0.92) } else { Color.clear } }
    }
    private var accessibilityDescription: String {
        guard let t = entry.temperature, let h = entry.humidity else { return "Xiaomi sensor. No reading yet. Open the app and connect the sensor." }
        let age = entry.updated.map { ", last updated " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        return String(format: "Temperature %.1f degrees Celsius, humidity %d percent", t, h) + age
    }
}

@main struct XiaomiSensorWidget: Widget {
    let kind = "XiaomiSensorWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SensorProvider()) { entry in SensorWidgetView(entry: entry) }
            .configurationDisplayName("Xiaomi Sensor")
            .description("Shows the latest temperature and humidity reading.")
            .supportedFamilies([.systemSmall])
            .contentMarginsDisabled()
    }
}
