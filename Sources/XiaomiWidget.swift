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
struct SensorWidgetView: View {
    var entry: SensorEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("XIAOMI SENSOR", systemImage: "sensor").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(entry.temperature.map { String(format: "%.1f", $0) } ?? "—").font(.system(size: 35, weight: .semibold, design: .rounded))
                Text("°C").font(.headline).foregroundStyle(.secondary)
            }
            Label(entry.humidity.map { "\($0)%" } ?? "—%", systemImage: "humidity.fill").font(.headline).foregroundStyle(.blue)
            Spacer(minLength: 0)
            if let updated = entry.updated {
                HStack(spacing: 3) {
                    Text("Updated")
                    Text(updated, style: .relative)
                    Text("ago")
                }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Open app and connect sensor").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }
}
@main struct XiaomiSensorWidget: Widget {
    let kind = "XiaomiSensorWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SensorProvider()) { entry in SensorWidgetView(entry: entry) }
            .configurationDisplayName("Xiaomi Sensor")
            .description("Shows the latest temperature and humidity reading.")
            .supportedFamilies([.systemSmall])
    }
}
