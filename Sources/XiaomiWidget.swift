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
// Use standard SwiftUI shapes so WidgetKit can archive and render every segment.
struct LCDNumber: View {
    let value: String
    private let patterns: [Character: String] = ["0":"abcdef", "1":"bc", "2":"abged", "3":"abgcd", "4":"fgbc", "5":"afgcd", "6":"afgecd", "7":"abc", "8":"abcdefg", "9":"abfgcd", "-":"g"]
    var body: some View {
        GeometryReader { geo in
            let chars = Array(value)
            let widths = chars.map { $0 == "." ? CGFloat(7) : ($0 == "-" ? CGFloat(18) : CGFloat(30)) }
            let total = widths.reduce(0, +) + CGFloat(max(0, chars.count - 1)) * 4
            let scale = min(geo.size.width / max(total, 1), geo.size.height / 55)
            HStack(spacing: 4 * scale) {
                ForEach(Array(chars.enumerated()), id: \.offset) { index, char in
                    let width = widths[index]
                    ZStack(alignment: .topLeading) {
                        if char == "." {
                            RoundedRectangle(cornerRadius: scale).frame(width: 5 * scale, height: 5 * scale).offset(x: scale, y: 49 * scale)
                        } else {
                            let active = patterns[char] ?? ""
                            ForEach(Array([( "a", CGFloat(4), CGFloat(0), width-8, CGFloat(5)), ("b", width-5, 4, 5, 22), ("c", width-5, 29, 5, 22), ("d", 4, 50, width-8, 5), ("e", 0, 29, 5, 22), ("f", 0, 4, 5, 22), ("g", 4, 25, width-8, 5)].enumerated()), id: \.offset) { _, segment in
                                if active.contains(segment.0) {
                                    RoundedRectangle(cornerRadius: 1.1 * scale)
                                        .frame(width: segment.3 * scale, height: segment.4 * scale)
                                        .offset(x: segment.1 * scale, y: segment.2 * scale)
                                }
                            }
                        }
                    }.frame(width: width * scale, height: 55 * scale)
                }
            }
            .foregroundStyle(Color(red: 0.16, green: 0.18, blue: 0.16))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .frame(width: unit * 0.43, height: unit * 0.24)
                    .position(x: unit * 0.465, y: unit * 0.39)
                BluetoothMark()
                    .stroke(style: StrokeStyle(lineWidth: unit * 0.005, lineCap: .round, lineJoin: .round))
                    .frame(width: unit * 0.025, height: unit * 0.045)
                    .position(x: unit * 0.75, y: unit * 0.30)
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
