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
            let side = min(size.width, size.height)
            let x = (size.width - side) / 2, y = (size.height - side) / 2
            let color = Color(red: 0.16, green: 0.18, blue: 0.16)
            let circle = CGRect(x: x + side * 0.08, y: y + side * 0.08, width: side * 0.84, height: side * 0.84)
            context.stroke(Path(ellipseIn: circle), with: .color(color), lineWidth: side * 0.065)
            for eye in [0.34, 0.66] {
                context.fill(Path(ellipseIn: CGRect(x: x + side * eye - side * 0.045, y: y + side * 0.34, width: side * 0.09, height: side * 0.09)), with: .color(color))
            }
            var mouth = Path()
            mouth.move(to: CGPoint(x: x + side * 0.30, y: y + side * (happy ? 0.59 : 0.68)))
            mouth.addQuadCurve(to: CGPoint(x: x + side * 0.70, y: y + side * (happy ? 0.59 : 0.68)),
                               control: CGPoint(x: x + side * 0.50, y: y + side * (happy ? 0.84 : 0.52)))
            context.stroke(mouth, with: .color(color), style: StrokeStyle(lineWidth: side * 0.065, lineCap: .round))
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
                RoundedRectangle(cornerRadius: unit * 0.12).fill(Color(red: 0.97, green: 0.97, blue: 0.95))
                RoundedRectangle(cornerRadius: unit * 0.035)
                    .fill(Color(red: 0.79, green: 0.82, blue: 0.76))
                    .padding(unit * 0.08)
                VStack(spacing: unit * 0.025) {
                    HStack(alignment: .top, spacing: unit * 0.01) {
                        LCDNumber(value: entry.temperature.map { String(format: "%.1f", $0) } ?? "--.-")
                        Text("°C").font(.system(size: unit * 0.13, weight: .medium, design: .rounded))
                            .padding(.top, unit * 0.018)
                    }.frame(height: unit * 0.34)
                    HStack(alignment: .center, spacing: unit * 0.015) {
                        LCDNumber(value: entry.humidity.map { String($0) } ?? "--")
                            .frame(width: unit * 0.34, height: unit * 0.28)
                        Text("%").font(.system(size: unit * 0.13, weight: .medium, design: .rounded))
                        Spacer(minLength: 0)
                        ComfortFace(happy: comfortable).frame(width: unit * 0.22, height: unit * 0.22)
                    }.frame(height: unit * 0.29)
                }
                .foregroundStyle(Color(red: 0.16, green: 0.18, blue: 0.16))
                .padding(.horizontal, unit * 0.14)
                .padding(.vertical, unit * 0.13)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
        }
        .containerBackground(for: .widget) { Color(red: 0.97, green: 0.97, blue: 0.95) }
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
