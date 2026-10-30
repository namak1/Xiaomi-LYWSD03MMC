import SwiftUI
import AppKit
import CoreBluetooth
import WidgetKit

private func uuid(_ part: String) -> CBUUID { CBUUID(string: "EBE0\(part)-7A0A-4B0C-8A1A-6FF2997DA3A6") }
private let dataUUID = uuid("CCC1"), timeUUID = uuid("CCB7"), historyUUID = uuid("CCBC")
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
            if selectedID != nil { begin(history: false) } else { scan() }
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
        bootTime = nil; historyCharacteristic = nil; countImported = 0; receivedTime = false; discoveredServices = 0
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
        guard busy, wantsHistory, receivedTime, let c = historyCharacteristic, bootTime != nil else { return }
        guard c.properties.contains(.notify) || c.properties.contains(.indicate) else { finish("History notifications are unavailable."); return }
        receivedTime = false
        timeout?.cancel()
        p.setNotifyValue(true, for: c)
        status = "Importing stored history…"
        resetHistoryTimeout()
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
            saveWidget(value, date)
            finish("Reading saved.")
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
                if countImported % 20 == 0 { _ = save() }
            }
            status = "Importing stored history: \(countImported) new records…"
            resetHistoryTimeout()
        }
    }
    private func saveWidget(_ value: Reading, _ date: Date) {
        let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Xiaomi Sensor/widget-reading.json")
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload: [String: Double] = ["temperature": value.temperature, "humidity": Double(value.humidity), "voltage": value.voltage, "timestamp": date.timeIntervalSince1970]
            try JSONSerialization.data(withJSONObject: payload).write(to: path, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: "XiaomiSensorWidget")
        } catch { status = "Widget data could not be saved: \(error.localizedDescription)" }
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
    private func scheduleNext() {
        timer?.cancel()
        guard selectedID != nil else { nextCheck = nil; return }
        let seconds = Double(intervalMinutes * 60)
        nextCheck = Date().addingTimeInterval(seconds)
        let work = DispatchWorkItem { [weak self] in self?.begin(history: false) }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
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
    var selectedRecords: [Record] { sensor.records.filter { $0.device == sensor.selectedID?.uuidString } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) { Text("Xiaomi Sensor").font(.largeTitle.bold()); Text("Temperature & humidity monitor").foregroundColor(.secondary) }
                Spacer()
                Button("Read now") { sensor.begin(history: false) }.disabled(sensor.selectedID == nil || sensor.importing)
            }
            HStack(spacing: 14) {
                metric("Temperature", sensor.reading.map { String(format: "%.1f °C", $0.temperature) } ?? "—", "thermometer")
                metric("Humidity", sensor.reading.map { "\($0.humidity) %" } ?? "—", "humidity")
                metric("Battery voltage", sensor.reading.map { String(format: "%.2f V", $0.voltage) } ?? "—", "battery.75")
            }
            Text(sensor.status).font(.callout)
            HStack {
                Text("Check every")
                Picker("Check interval", selection: $sensor.intervalMinutes) {
                    Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("1 hour").tag(60); Text("2 hours").tag(120); Text("6 hours").tag(360); Text("12 hours").tag(720); Text("24 hours").tag(1440)
                }.labelsHidden().frame(width: 130)
                if let date = sensor.nextCheck { Text("Next: \(date.formatted(date: .omitted, time: .shortened))").foregroundColor(.secondary).font(.caption) }
                Spacer()
                Button("Scan") { sensor.scan() }
                Menu("Sensor") {
                    ForEach(sensor.devices, id: \.identifier) { p in Button(p.name ?? "LYWSD03MMC") { sensor.choose(p) } }
                }
            }
            HStack {
                Text("History").font(.headline)
                Text("\(selectedRecords.count) records").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Import sensor history") { sensor.begin(history: true) }.disabled(sensor.selectedID == nil || sensor.importing)
                Button("Export CSV") { sensor.exportCSV() }.disabled(sensor.records.isEmpty)
            }
            if selectedRecords.isEmpty {
                Text("No saved readings for this sensor yet. Choose a sensor above, or import its stored history.").foregroundColor(.secondary)
                Spacer()
            } else {
                List(selectedRecords) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened))
                            Text(r.source).font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(r.minTemp == r.maxTemp ? String(format: "%.1f °C", r.minTemp) : String(format: "%.1f–%.1f °C", r.minTemp, r.maxTemp))
                        Text(r.minHumidity == r.maxHumidity ? "\(r.minHumidity)%" : "\(r.minHumidity)–\(r.maxHumidity)%").frame(width: 90, alignment: .trailing)
                    }
                }
            }
            Text("Keep the app open and the Mac awake for scheduled checks. Stored sensor history times are estimated. Widget refresh timing is controlled by macOS.").font(.caption).foregroundColor(.secondary)
        }.padding(24).frame(minWidth: 680, minHeight: 560)
    }
    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
        }.frame(maxWidth: .infinity, minHeight: 75, alignment: .leading).padding(14).background(Color.accentColor.opacity(0.09)).cornerRadius(12)
    }
}

@main struct XiaomiSensorApp: App {
    @StateObject private var sensor = Sensor()
    var body: some Scene { WindowGroup { ContentView(sensor: sensor) } }
}
