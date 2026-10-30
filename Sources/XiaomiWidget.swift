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
// A scalable seven-segment LCD, drawn in code so the reading stays sharp at widget size.
struct LCDNumber: View {
    let value: String
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let chars = Array(value)
                guard !chars.isEmpty else { return }
                let unitWidth: CGFloat = 30, height: CGFloat = 55, spacing: CGFloat = 4
                let widths: [CGFloat] = chars.map { $0 == "." ? 7 : ($0 == "-" ? 18 : unitWidth) }
                let total = widths.reduce(0, +) + spacing * CGFloat(max(0, chars.count - 1))
                let scale = min(size.width / total, size.height / height)
                var x = (size.width - total * scale) / 2
                let y = (size.height - height * scale) / 2
                let patterns: [Character: String] = ["0":"abcdef", "1":"bc", "2":"abged", "3":"abgcd", "4":"fgbc", "5":"afgcd", "6":"afgecd", "7":"abc", "8":"abcdefg", "9":"abfgcd", "-":"g"]
                for (idx, char) in chars.enumerated() {
                    let w = widths[idx]
                    if char == "." {
                        let dot = CGRect(x: x + 1 * scale, y: y + 49 * scale, width: 5 * scale, height: 5 * scale)
                        context.fill(Path(roundedRect: dot, cornerRadius: scale), with: .color(Color(red: 0.16, green: 0.18, blue: 0.16)))
                    } else {
                        let active = patterns[char] ?? ""
                        let segments: [(Character, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                            ("a",4,0,w-8,5), ("b",w-5,4,5,22), ("c",w-5,29,5,22),
                            ("d",4,50,w-8,5), ("e",0,29,5,22), ("f",0,4,5,22), ("g",4,25,w-8,5)]
                        for (name, sx, sy, sw, sh) in segments where active.contains(name) {
                            let rect = CGRect(x: x + sx * scale, y: y + sy * scale, width: sw * scale, height: sh * scale)
                            context.fill(Path(roundedRect: rect, cornerRadius: 1.1 * scale), with: .color(Color(red: 0.16, green: 0.18, blue: 0.16)))
                        }
                    }
                    x += (w + spacing) * scale
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct ComfortFace: View {
    let happy: Bool
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let ink = Color(red: 0.12, green: 0.12, blue: 0.12)
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
            context.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(1, h * 0.075), lineCap: .square, lineJoin: .miter))
        }.accessibilityHidden(true)
    }
}

struct SensorWidgetView: View {
    var entry: SensorEntry
    private var comfortable: Bool {
        guard let t = entry.temperature, let h = entry.humidity else { return false }
        return (19...27).contains(t) && (20...85).contains(h)
    }
    var body: some View {
        GeometryReader { geo in
            let unit = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: unit * 0.12)
                    .fill(Color(red: 0.92, green: 0.92, blue: 0.92))
                RoundedRectangle(cornerRadius: unit * 0.018)
                    .fill(Color(red: 0.59, green: 0.59, blue: 0.58))
                    .overlay(RoundedRectangle(cornerRadius: unit * 0.018)
                        .stroke(Color.black.opacity(0.24), lineWidth: unit * 0.009))
                    .frame(width: unit * 0.67, height: unit * 0.67)
                    .shadow(color: .black.opacity(0.15), radius: unit * 0.012, x: 0, y: unit * 0.003)
                LCDNumber(value: entry.temperature.map { String(format: "%.1f", $0) } ?? "--.-")
                    .frame(width: unit * 0.48, height: unit * 0.24)
                    .position(x: unit * 0.465, y: unit * 0.39)
                Text("°C")
                    .font(.system(size: unit * 0.08, weight: .medium, design: .monospaced))
                    .position(x: unit * 0.75, y: unit * 0.45)
                ComfortFace(happy: comfortable)
                    .frame(width: unit * 0.27, height: unit * 0.13)
                    .position(x: unit * 0.37, y: unit * 0.65)
                LCDNumber(value: entry.humidity.map { String($0) } ?? "--")
                    .frame(width: unit * 0.18, height: unit * 0.13)
                    .position(x: unit * 0.61, y: unit * 0.65)
                Text("%")
                    .font(.system(size: unit * 0.065, weight: .medium, design: .monospaced))
                    .position(x: unit * 0.745, y: unit * 0.68)
            }
            .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
        }
        .containerBackground(for: .widget) { Color(red: 0.92, green: 0.92, blue: 0.92) }
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
