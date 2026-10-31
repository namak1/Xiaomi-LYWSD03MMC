import SwiftUI
import AppKit
import CoreBluetooth
import WidgetKit
import Charts
import ServiceManagement

private func uuid(_ part: String) -> CBUUID { CBUUID(string: "EBE0\(part)-7A0A-4B0C-8A1A-6FF2997DA3A6") }
private let dataUUID = uuid("CCC1"), timeUUID = uuid("CCB7"), historyUUID = uuid("CCBC"), indexUUID = uuid("CCBA"), countUUID = uuid("CCB9")
private func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24
}
private func i16(_ b: [UInt8], _ i: Int) -> Int16 { Int16(bitPattern: UInt16(b[i]) | UInt16(b[i+1]) << 8) }

struct Reading {
    let temperature: Double
    let humidity: Int
    let voltage: Double
    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 5 else { return nil }
        temperature = Double(i16(b, 0)) / 100
        humidity = Int(b[2])
        voltage = Double(UInt16(b[3]) | UInt16(b[4]) << 8) / 1000
        guard (-40...85).contains(temperature), (0...100).contains(humidity), (1.0...4.0).contains(voltage) else { return nil }
    }
}
struct Record: Codable, Identifiable {
    var id: String
    var device: String
    var date: Date
    var source: String
    var minTemp: Double
    var maxTemp: Double
    var minHumidity: Int
    var maxHumidity: Int
    var voltage: Double?
}

final class Sensor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var devices: [CBPeripheral] = []
    @Published var status = "Starting Bluetooth…"
    @Published var reading: Reading?
    @Published var lastUpdated: Date?
    @Published var selectedID: UUID?
    @Published var intervalMinutes: Int {
        didSet {
            intervalMinutes = max(5, min(1440, intervalMinutes))
            UserDefaults.standard.set(intervalMinutes, forKey: "intervalMinutes")
            if !busy { scheduleNext() }
        }
    }
    @Published var records: [Record] = []
    @Published var nextCheck: Date?
    @Published var importing = false
    private var manager: CBCentralManager!
    private var connected: CBPeripheral?
    private var timer: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private var historyTimeout: DispatchWorkItem?
    private var busy = false
    private var wantsHistory = false
    private var gotReading = false
    private var bootTime: Date?
    private var historyCharacteristic: CBCharacteristic?
    private var indexCharacteristic: CBCharacteristic?
    private var nextIndex: UInt32?
    private var cursorStarted = false
    private var countImported = 0
    private var receivedTime = false
    private var discoveredServices = 0
    private var archiveURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Xiaomi Sensor/history.json")
    }
    override init() {
        let saved = UserDefaults.standard.integer(forKey: "intervalMinutes")
        intervalMinutes = saved == 0 ? 60 : max(5, min(1440, saved))
        super.init()
        if let s = UserDefaults.standard.string(forKey: "selectedSensorUUID") { selectedID = UUID(uuidString: s) }
        load()
        manager = CBCentralManager(delegate: self, queue: .main)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }
    @objc private func didWake() {
        guard !busy, let due = nextCheck, due <= Date(), selectedID != nil, manager.state == .poweredOn else { return }
        begin(history: false)
    }
    private func load() {
        guard let data = try? Data(contentsOf: archiveURL),
              let saved = try? JSONDecoder().decode([Record].self, from: data) else { return }
        records = saved.sorted { $0.date > $1.date }
    }
    @discardableResult private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: archiveURL, options: .atomic)
            return true
        } catch { status = "Could not save history: \(error.localizedDescription)"; return false }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if selectedID != nil {
                let due = UserDefaults.standard.double(forKey: "nextCheckTimestamp")
                if due > Date().timeIntervalSince1970 {
                    scheduleNext(at: Date(timeIntervalSince1970: due))
                } else { begin(history: false) }
            } else { scan() }
        case .unauthorized: status = "Allow Bluetooth in System Settings → Privacy & Security → Bluetooth."
        case .poweredOff: status = "Bluetooth is off."
        case .unsupported: status = "Bluetooth is not supported."
        default: status = "Bluetooth is unavailable."
        }
    }
    func scan() {
        guard manager.state == .poweredOn else { return }
        status = "Scanning for sensors…"
        manager.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, !self.busy else { return }
            self.manager.stopScan()
            if self.devices.isEmpty { self.status = "No sensors found. Move the sensor closer and scan again." }
        }
    }
    func choose(_ p: CBPeripheral) {
        stopCurrent()
        selectedID = p.identifier
        UserDefaults.standard.set(p.identifier.uuidString, forKey: "selectedSensorUUID")
        reading = nil; lastUpdated = nil
        begin(history: false)
    }
    func begin(history: Bool) {
        guard manager.state == .poweredOn, selectedID != nil else {
            status = "Select a sensor and enable Bluetooth first."; return
        }
        stopCurrent()
        busy = true; wantsHistory = history; importing = history; gotReading = false
        bootTime = nil; historyCharacteristic = nil; indexCharacteristic = nil; nextIndex = nil; cursorStarted = false; countImported = 0; receivedTime = false; discoveredServices = 0
        nextCheck = nil
        status = history ? "Connecting to import sensor history…" : "Connecting for a reading…"
        if let id = selectedID, let p = manager.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
        } else {
            manager.scanForPeripherals(withServices: nil, options: nil)
        }
        let task = DispatchWorkItem { [weak self] in self?.finish("Sensor unavailable or connection timed out.") }
        timeout = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: task)
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.localizedCaseInsensitiveContains("LYWSD03MMC") || p.identifier == selectedID else { return }
        if !devices.contains(where: { $0.identifier == p.identifier }) { devices.append(p) }
        if busy, p.identifier == selectedID, connected == nil { manager.stopScan(); connect(p) }
    }
    private func connect(_ p: CBPeripheral) {
        connected = p; p.delegate = self
        if p.state == .connected { p.discoverServices(nil) }
        else { manager.connect(p) }
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard connected?.identifier == p.identifier else { central.cancelPeripheralConnection(p); return }
        status = wantsHistory ? "Discovering sensor history…" : "Waiting for a reading…"
        p.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard connected?.identifier == p.identifier, busy else { return }
        finish("Connection failed: \(error?.localizedDescription ?? "unknown error")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard connected?.identifier == p.identifier, busy else { return }
        finish("Disconnected before the operation completed.")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard busy, connected?.identifier == p.identifier else { return }
        if let error = error { finish("Service discovery failed: \(error.localizedDescription)"); return }
        let services = p.services ?? []
        guard !services.isEmpty else { finish("No Bluetooth services found."); return }
        discoveredServices = services.count
        for service in services { p.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard busy, connected?.identifier == p.identifier else { return }
        if let error = error { finish("Discovery failed: \(error.localizedDescription)"); return }
        discoveredServices -= 1
        for c in service.characteristics ?? [] {
            if c.uuid == dataUUID && !wantsHistory {
                if c.properties.contains(.notify) || c.properties.contains(.indicate) { p.setNotifyValue(true, for: c) }
                else if c.properties.contains(.read) { p.readValue(for: c) }
            } else if c.uuid == timeUUID && wantsHistory && c.properties.contains(.read) { p.readValue(for: c) }
            else if c.uuid == historyUUID && wantsHistory { historyCharacteristic = c }
            else if c.uuid == indexUUID && wantsHistory { indexCharacteristic = c }
            else if c.uuid == countUUID && wantsHistory && c.properties.contains(.read) { p.readValue(for: c) }
        }
        if wantsHistory { startHistoryIfReady(p) }
        if discoveredServices == 0 {
            if wantsHistory && historyCharacteristic == nil { finish("This firmware does not expose sensor history.") }
            if wantsHistory && historyCharacteristic != nil && !receivedTime {
                // The uptime read is asynchronous; the overall timeout handles failure.
            }
        }
    }
    private func startHistoryIfReady(_ p: CBPeripheral) {
        guard busy, wantsHistory, receivedTime, let history = historyCharacteristic, let boot = bootTime,
              let deviceNext = nextIndex, !cursorStarted else { return }
        guard history.properties.contains(.notify) || history.properties.contains(.indicate) else {
            finish("History notifications unavailable."); return
        }
        cursorStarted = true
        let prefix = "\(p.identifier.uuidString)-\(Int(boot.timeIntervalSince1970 / 3600))-"
        let saved = records.compactMap { record -> UInt32? in
            guard record.source.hasPrefix("sensor history"), record.id.hasPrefix(prefix) else { return nil }
            return UInt32(record.id.dropFirst(prefix.count))
        }.max()
        if let last = saved, last < UInt32.max, last + 1 >= deviceNext {
            finish("Reading saved; history is up to date."); return
        }
        if let last = saved, last < UInt32.max, let index = indexCharacteristic,
           index.properties.contains(.write) {
            let value = last + 1
            let data = Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
                             UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
            p.writeValue(data, for: index, type: .withResponse)
        } else {
            subscribeHistory(p, history)
        }
    }
    private func subscribeHistory(_ p: CBPeripheral, _ history: CBCharacteristic) {
        timeout?.cancel()
        p.setNotifyValue(true, for: history)
        status = "Importing sensor history…"
        resetHistoryTimeout()
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard busy, wantsHistory, c.uuid == indexUUID, let history = historyCharacteristic else { return }
        if let error = error { finish("Could not request new history: \(error.localizedDescription)"); return }
        subscribeHistory(p, history)
    }
    private func resetHistoryTimeout() {
        historyTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.busy else { return }
            if self.save() { self.finish("History import finished: \(self.countImported) new records. The sensor may have more if the transfer stopped early.") }
            else { let message = self.status; self.finish(message) }
        }
        historyTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard busy, connected?.identifier == p.identifier else { return }
        if let error = error { finish("Notifications failed: \(error.localizedDescription)") }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard busy, connected?.identifier == p.identifier else { return }
        if let error = error { finish("Read failed: \(error.localizedDescription)"); return }
        guard let data = c.value else { return }
        let b = [UInt8](data)
        if c.uuid == dataUUID && !wantsHistory, let value = Reading(data), !gotReading {
            gotReading = true
            reading = value; lastUpdated = Date()
            let date = Date()
            records.insert(Record(id: UUID().uuidString, device: p.identifier.uuidString, date: date, source: "sample", minTemp: value.temperature, maxTemp: value.temperature, minHumidity: value.humidity, maxHumidity: value.humidity, voltage: value.voltage), at: 0)
            guard save() else { let message = status; finish(message); return }
            let widgetSaved = saveWidget(value, date)
            guard widgetSaved else { finish("Reading saved, but widget update failed. Check macOS privacy settings."); return }
            // Reconnect for the sensor's stored hourly records after each sample.
            stopCurrent()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.begin(history: true) }
        } else if c.uuid == countUUID && wantsHistory {
            guard b.count >= 8 else { finish("Invalid history count."); return }
            nextIndex = u32(b, 4)
            startHistoryIfReady(p)
        } else if c.uuid == timeUUID && wantsHistory {
            guard b.count >= 4 else { finish("Invalid sensor uptime."); return }
            let estimate = Date().addingTimeInterval(-Double(u32(b, 0)))
            let key = "bootTime-" + p.identifier.uuidString
            let previous = UserDefaults.standard.double(forKey: key)
            let stable = previous > 0 && abs(previous - estimate.timeIntervalSince1970) < 120 ? previous : estimate.timeIntervalSince1970
            UserDefaults.standard.set(stable, forKey: key)
            bootTime = Date(timeIntervalSince1970: stable)
            receivedTime = true
            startHistoryIfReady(p)
        } else if c.uuid == historyUUID && wantsHistory {
            guard b.count >= 14, let boot = bootTime else { return }
            let index = u32(b, 0), seconds = u32(b, 4)
            let maxTemp = Double(i16(b, 8)) / 10, maxHum = Int(b[10])
            let minTemp = Double(i16(b, 11)) / 10, minHum = Int(b[13])
            guard (-40...85).contains(minTemp), (-40...85).contains(maxTemp), (0...100).contains(minHum), (0...100).contains(maxHum), minTemp <= maxTemp, minHum <= maxHum else { return }
            let date = boot.addingTimeInterval(Double(seconds))
            // Device index may be reused after a reset; estimated boot time is rounded to an hour.
            let key = "\(p.identifier.uuidString)-\(Int(boot.timeIntervalSince1970 / 3600))-\(index)"
            if !records.contains(where: { $0.id == key }) {
                records.append(Record(id: key, device: p.identifier.uuidString, date: date, source: "sensor history (estimated)", minTemp: minTemp, maxTemp: maxTemp, minHumidity: minHum, maxHumidity: maxHum, voltage: nil))
                countImported += 1
                guard save() else { let message = status; finish(message); return }
            }
            status = "Importing stored history: \(countImported) new records…"
            if let end = nextIndex, end > 0, index >= end - 1 {
                finish("Reading and history updated: \(countImported) new records.")
            } else { resetHistoryTimeout() }
        }
    }
    @discardableResult private func saveWidget(_ value: Reading, _ date: Date) -> Bool {
        let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Xiaomi Sensor/widget-reading.json")
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload: [String: Double] = ["temperature": value.temperature, "humidity": Double(value.humidity), "voltage": value.voltage, "timestamp": date.timeIntervalSince1970]
            try JSONSerialization.data(withJSONObject: payload).write(to: path, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: "XiaomiSensorWidget")
            return true
        } catch {
            return false
        }
    }
    private func stopCurrent() {
        timer?.cancel(); timeout?.cancel(); historyTimeout?.cancel()
        if manager != nil { manager.stopScan(); if let p = connected { manager.cancelPeripheralConnection(p) } }
        connected = nil; busy = false; importing = false
    }
    private func finish(_ message: String) {
        stopCurrent()
        records.sort { $0.date > $1.date }
        status = message
        scheduleNext()
    }
    private func scheduleNext(at requested: Date? = nil) {
        timer?.cancel()
        guard selectedID != nil else { nextCheck = nil; return }
        let seconds = Double(intervalMinutes * 60)
        let due = requested ?? Date().addingTimeInterval(seconds)
        nextCheck = due
        UserDefaults.standard.set(due.timeIntervalSince1970, forKey: "nextCheckTimestamp")
        let work = DispatchWorkItem { [weak self] in self?.begin(history: false) }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due.timeIntervalSinceNow), execute: work)
    }
    func exportCSV() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Xiaomi-Sensor-History.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let iso = ISO8601DateFormatter()
        var csv = "time_utc,source,sensor_id,min_temp_c,max_temp_c,min_humidity_percent,max_humidity_percent,voltage_v\n"
        for r in records.sorted(by: { $0.date < $1.date }) {
            csv += "\(iso.string(from: r.date)),\(r.source),\(r.device),\(r.minTemp),\(r.maxTemp),\(r.minHumidity),\(r.maxHumidity),\(r.voltage.map { String($0) } ?? "")\n"
        }
        do { try csv.write(to: url, atomically: true, encoding: .utf8); status = "History exported." }
        catch { status = "Export failed: \(error.localizedDescription)" }
    }
}

struct ContentView: View {
    @ObservedObject var sensor: Sensor
    @State private var historyView = "Graphs"
    @State private var showSettings = false
    var selectedRecords: [Record] { sensor.records.filter { $0.device == sensor.selectedID?.uuidString } }
    private var sensorName: String {
        guard let id = sensor.selectedID else { return "Choose sensor" }
        return sensor.devices.first(where: { $0.identifier == id })?.name ?? "LYWSD03MMC"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "thermometer.medium").font(.title2).foregroundStyle(.teal)
                    .frame(width: 42, height: 42).background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Xiaomi Sensor").font(.title2.weight(.bold))
                    HStack(spacing: 5) {
                        Circle().fill(sensor.selectedID == nil ? Color.secondary : Color.teal).frame(width: 6, height: 6)
                        Text(sensor.status).lineLimit(1)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Button { sensor.begin(history: false) } label: { Label("Read now", systemImage: "arrow.clockwise") }
                    .disabled(sensor.selectedID == nil || sensor.importing)
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape").frame(width: 20) }
                    .help("Sensor and schedule settings")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { settings }
            }.padding(.bottom, 18)
            HStack(spacing: 10) {
                metric("TEMPERATURE", sensor.reading.map { String(format: "%.1f °C", $0.temperature) } ?? "—", "thermometer.medium", .orange)
                metric("HUMIDITY", sensor.reading.map { "\($0.humidity) %" } ?? "—", "humidity.fill", .blue)
                metric("BATTERY VOLTAGE", sensor.reading.map { String(format: "%.2f V", $0.voltage) } ?? "—", "battery.75", .teal)
            }
            HStack(spacing: 12) {
                Label(sensorName, systemImage: "sensor")
                if let date = sensor.lastUpdated { Text("Updated \(date.formatted(date: .omitted, time: .shortened))") }
                if let date = sensor.nextCheck { Text("Next check \(date.formatted(date: .omitted, time: .shortened))") }
                Spacer()
                Button("Settings") { showSettings.toggle() }.buttonStyle(.link)
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 10).padding(.bottom, 18)
            Divider()
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("History").font(.title3.weight(.semibold))
                    Text("\(selectedRecords.count.formatted()) saved records").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("History view", selection: $historyView) {
                    Text("Graphs").tag("Graphs")
                    Text("List").tag("List")
                }.labelsHidden().pickerStyle(.segmented).frame(width: 145)
                Menu {
                    Button("Import sensor history") { sensor.begin(history: true) }.disabled(sensor.selectedID == nil || sensor.importing)
                    Button("Export CSV") { sensor.exportCSV() }.disabled(sensor.records.isEmpty)
                } label: { Label("History actions", systemImage: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }.padding(.top, 16).padding(.bottom, 12)
            if selectedRecords.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("No readings yet").font(.headline)
                    Text("Connect a sensor or import its stored history.").font(.callout).foregroundStyle(.secondary)
                    Button("Import sensor history") { sensor.begin(history: true) }.disabled(sensor.selectedID == nil || sensor.importing)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if historyView == "Graphs" {
                HistoryCharts(records: selectedRecords).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selectedRecords) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened))
                            Text(r.source).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(r.minTemp == r.maxTemp ? String(format: "%.1f °C", r.minTemp) : String(format: "%.1f–%.1f °C", r.minTemp, r.maxTemp)).monospacedDigit()
                        Text(r.minHumidity == r.maxHumidity ? "\(r.minHumidity)%" : "\(r.minHumidity)–\(r.maxHumidity)%").frame(width: 90, alignment: .trailing).monospacedDigit()
                    }.padding(.vertical, 3)
                }.listStyle(.inset)
            }
        }.padding(22).frame(minWidth: 740, minHeight: 640)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sensor settings").font(.headline)
            Text(SMAppService.agent(plistName: "com.namak1.xiaomisensor.background.plist").status == .enabled
                 ? "Background monitoring: enabled"
                 : "Background monitoring requires approval in System Settings → General → Login Items & Extensions.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Sensor")
                Spacer()
                Menu(sensorName) {
                    ForEach(sensor.devices, id: \.identifier) { p in
                        Button("\(p.name ?? "LYWSD03MMC") · \(p.identifier.uuidString.suffix(5))") { sensor.choose(p) }
                    }
                }.fixedSize()
                Button("Scan") { sensor.scan() }
            }
            HStack {
                Text("Check every")
                Spacer()
                Picker("Check every", selection: $sensor.intervalMinutes) {
                    Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("1 hour").tag(60); Text("2 hours").tag(120); Text("6 hours").tag(360); Text("12 hours").tag(720); Text("24 hours").tag(1440)
                }.labelsHidden().frame(width: 145)
            }
            Divider()
            Text("Background monitoring uses a macOS background item. Enable it in Login Items if requested.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(width: 340)
    }
    private func metric(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private enum GraphRange: String, CaseIterable, Identifiable {
    case day = "24 hours", week = "7 days", month = "30 days", all = "All"
    var id: String { rawValue }
    var seconds: TimeInterval? {
        switch self {
        case .day: return 86400
        case .week: return 604800
        case .month: return 2592000
        case .all: return nil
        }
    }
}
private enum GraphMode: String, CaseIterable, Identifiable {
    case combined = "Combined", temperature = "Temperature", humidity = "Humidity", daily = "Daily range"
    var id: String { rawValue }
}
private struct DailyRange: Identifiable {
    let day: Date
    let lowTemp: Double
    let highTemp: Double
    let lowHumidity: Double
    let highHumidity: Double
    var id: Date { day }
}
struct HistoryCharts: View {
    let records: [Record]
    @State private var range: GraphRange = .week
    @State private var mode: GraphMode = .combined
    private var visible: [Record] {
        let cutoff = range.seconds.map { Date().addingTimeInterval(-$0) } ?? .distantPast
        return records.filter { $0.date >= cutoff && $0.date <= Date() }.sorted { $0.date < $1.date }
    }
    private var daily: [DailyRange] {
        let grouped = Dictionary(grouping: visible) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted().compactMap { day in
            guard let values = grouped[day], let first = values.first else { return nil }
            return DailyRange(day: day,
                lowTemp: values.map(\.minTemp).min() ?? first.minTemp,
                highTemp: values.map(\.maxTemp).max() ?? first.maxTemp,
                lowHumidity: Double(values.map(\.minHumidity).min() ?? first.minHumidity),
                highHumidity: Double(values.map(\.maxHumidity).max() ?? first.maxHumidity))
        }
    }
    private var xDomain: ClosedRange<Date> {
        let now = Date()
        if let seconds = range.seconds { return now.addingTimeInterval(-seconds)...now }
        let first = visible.first?.date ?? now.addingTimeInterval(-86400)
        return min(first.addingTimeInterval(-1800), now.addingTimeInterval(-3600))...now
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Graph", selection: $mode) {
                    ForEach(GraphMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Time range", selection: $range) {
                    ForEach(GraphRange.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 125)
            }
            if visible.isEmpty {
                Spacer()
                Text("No readings in this period. Try a longer range or import sensor history.")
                    .foregroundColor(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if mode == .temperature || mode == .combined { measurementChart(isTemperature: true) }
                        if mode == .humidity || mode == .combined { measurementChart(isTemperature: false) }
                        if mode == .daily {
                            dailyChart(isTemperature: true)
                            dailyChart(isTemperature: false)
                        }
                    }.padding(.trailing, 6)
                }
                Text(mode == .daily
                     ? "Daily ranges combine saved samples and sensor-reported hourly extremes. Partial days are shown."
                     : "Dots and lines: app samples. Vertical bars: sensor hourly minimum–maximum. Sensor history times are estimated.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }
    private func measurementChart(isTemperature: Bool) -> some View {
        let samples = visible.filter { $0.source == "sample" }
        let history = visible.filter { $0.source != "sample" }
        let color: Color = isTemperature ? .orange : .blue
        return VStack(alignment: .leading, spacing: 5) {
            Text(isTemperature ? "Temperature · °C" : "Humidity · %").font(.subheadline.weight(.semibold))
            Chart {
                ForEach(history) { record in
                    RuleMark(x: .value("Time", record.date),
                             yStart: .value("Minimum", isTemperature ? record.minTemp : Double(record.minHumidity)),
                             yEnd: .value("Maximum", isTemperature ? record.maxTemp : Double(record.maxHumidity)))
                        .foregroundStyle(color.opacity(0.48)).lineStyle(StrokeStyle(lineWidth: 3))
                    PointMark(x: .value("Time", record.date),
                              y: .value("Minimum", isTemperature ? record.minTemp : Double(record.minHumidity)))
                        .foregroundStyle(color.opacity(0.45)).symbolSize(12)
                }
                ForEach(samples) { record in
                    LineMark(x: .value("Time", record.date),
                             y: .value("Reading", isTemperature ? record.minTemp : Double(record.minHumidity)))
                        .foregroundStyle(color)
                    PointMark(x: .value("Time", record.date),
                              y: .value("Reading", isTemperature ? record.minTemp : Double(record.minHumidity)))
                        .foregroundStyle(color).symbolSize(22)
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: isTemperature ? .automatic(includesZero: false) : .automatic(includesZero: true))
            .frame(height: mode == .combined || mode == .daily ? 190 : 280)
        }
    }
    private func dailyChart(isTemperature: Bool) -> some View {
        let color: Color = isTemperature ? .orange : .blue
        return VStack(alignment: .leading, spacing: 5) {
            Text(isTemperature ? "Daily temperature range · °C" : "Daily humidity range · %").font(.subheadline.weight(.semibold))
            Chart(daily) { day in
                RuleMark(x: .value("Day", day.day, unit: .day),
                         yStart: .value("Minimum", isTemperature ? day.lowTemp : day.lowHumidity),
                         yEnd: .value("Maximum", isTemperature ? day.highTemp : day.highHumidity))
                    .foregroundStyle(color.opacity(0.75)).lineStyle(StrokeStyle(lineWidth: 5))
                PointMark(x: .value("Day", day.day, unit: .day),
                          y: .value("Minimum", isTemperature ? day.lowTemp : day.lowHumidity))
                    .foregroundStyle(color).symbolSize(24)
                PointMark(x: .value("Day", day.day, unit: .day),
                          y: .value("Maximum", isTemperature ? day.highTemp : day.highHumidity))
                    .foregroundStyle(color).symbolSize(24)
            }.frame(height: mode == .combined || mode == .daily ? 190 : 280)
        }
    }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var monitoringActivity: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--background") { NSApp.setActivationPolicy(.accessory); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.hide(nil) } }
        do { let service = SMAppService.agent(plistName: "com.namak1.xiaomisensor.background.plist"); if service.status == .notRegistered { try service.register() } } catch { NSLog("Background service registration failed: %@", error.localizedDescription) }
        ProcessInfo.processInfo.disableAutomaticTermination("Scheduled sensor monitoring")
        monitoringActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Scheduled Bluetooth sensor readings")
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let activity = monitoringActivity { ProcessInfo.processInfo.endActivity(activity) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct SensorMenu: View {
    @ObservedObject var sensor: Sensor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Xiaomi Sensor") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if let reading = sensor.reading {
            Text(String(format: "%.1f °C · %d%%", reading.temperature, reading.humidity))
        } else {
            Text("No reading yet")
        }
        Text(sensor.status)
        if let next = sensor.nextCheck {
            Text("Next check: \(next.formatted(date: .omitted, time: .shortened))")
        }
        Button("Read now") { sensor.begin(history: false) }.disabled(sensor.selectedID == nil || sensor.importing)
        Divider()
        Button("Quit Xiaomi Sensor") { NSApp.terminate(nil) }
    }
}

@main struct XiaomiSensorApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    @StateObject private var sensor = Sensor()
    var body: some Scene {
        Window("Xiaomi Sensor", id: "main") { ContentView(sensor: sensor) }
            .defaultSize(width: 960, height: 800)
            .commands {
                CommandGroup(replacing: .appTermination) {
                    Button("Quit Xiaomi Sensor") { NSApp.terminate(nil) }
                        .keyboardShortcut("q", modifiers: .command)
                    Button("Stop Monitoring and Quit") { NSApp.terminate(nil) }
                }
            }
        MenuBarExtra("Xiaomi Sensor", systemImage: "thermometer.medium") { SensorMenu(sensor: sensor) }
    }
}
