import SwiftUI
import AppKit
import CoreBluetooth
import WidgetKit

private let sensorCharacteristic = CBUUID(string: "EBE0CCC1-7A0A-4B0C-8A1A-6FF2997DA3A6")

struct Reading {
    let temperature: Double
    let humidity: Int
    let voltage: Double
    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 5 else { return nil }
        let raw = UInt16(b[0]) | UInt16(b[1]) << 8
        temperature = Double(Int16(bitPattern: raw)) / 100
        humidity = Int(b[2])
        voltage = Double(UInt16(b[3]) | UInt16(b[4]) << 8) / 1000
        guard (-40...85).contains(temperature), (0...100).contains(humidity), (1.0...4.0).contains(voltage) else { return nil }
    }
}

final class Sensor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var devices: [CBPeripheral] = []
    @Published var status = "Starting Bluetooth…"
    @Published var reading: Reading?
    @Published var lastUpdated: Date?
    @Published var selectedID: UUID?
    private var manager: CBCentralManager!
    private var connected: CBPeripheral?
    private var retry: DispatchWorkItem?
    private var connectionTimeout: DispatchWorkItem?
    private let savedKey = "selectedSensorUUID"
    override init() {
        super.init()
        if let s = UserDefaults.standard.string(forKey: savedKey) { selectedID = UUID(uuidString: s) }
        manager = CBCentralManager(delegate: self, queue: .main)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: scan()
        case .unauthorized: status = "Bluetooth permission denied. Enable it in System Settings → Privacy & Security → Bluetooth."
        case .poweredOff: status = "Bluetooth is off. Turn it on in System Settings."
        case .unsupported: status = "Bluetooth is not supported on this Mac."
        default: status = "Bluetooth is unavailable."
        }
    }
    func scan() {
        guard manager.state == .poweredOn else { return }
        status = selectedID == nil ? "Scanning for sensors…" : "Searching for your sensor…"
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "")
        guard name.localizedCaseInsensitiveContains("LYWSD03MMC") || p.identifier == selectedID else { return }
        if !devices.contains(where: { $0.identifier == p.identifier }) { devices.append(p) }
        if p.identifier == selectedID && connected == nil { connect(p) }
    }
    func choose(_ p: CBPeripheral) {
        retry?.cancel()
        if let old = connected { manager.cancelPeripheralConnection(old) }
        connected = nil
        reading = nil
        lastUpdated = nil
        selectedID = p.identifier
        UserDefaults.standard.set(p.identifier.uuidString, forKey: savedKey)
        connect(p)
    }
    private func connect(_ p: CBPeripheral) {
        guard manager.state == .poweredOn, connected == nil else { return }
        connected = p
        p.delegate = self
        status = "Connecting to \(p.name ?? "sensor")…"
        manager.connect(p, options: nil)
        let timeout = DispatchWorkItem { [weak self, weak p] in
            guard let self = self, let p = p, p.state == .connecting else { return }
            self.status = "Connection timed out. Retrying…"
            self.manager.cancelPeripheralConnection(p)
        }
        connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        connectionTimeout?.cancel()
        status = "Connected. Waiting for readings…"
        p.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { disconnected(p, error) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { disconnected(p, error) }
    private func disconnected(_ p: CBPeripheral, _ error: Error?) {
        connectionTimeout?.cancel()
        guard connected?.identifier == p.identifier else { return }
        connected = nil
        status = "Disconnected. Reconnecting…"
        guard p.identifier == selectedID else { return }
        let task = DispatchWorkItem { [weak self] in self?.connect(p) }
        retry = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { status = "Service discovery failed: \(error.localizedDescription)"; return }
        for service in p.services ?? [] { p.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error { status = "Characteristic discovery failed: \(error.localizedDescription)"; return }
        for c in service.characteristics ?? [] where c.uuid == sensorCharacteristic {
            if c.properties.contains(.notify) || c.properties.contains(.indicate) { p.setNotifyValue(true, for: c) }
            else if c.properties.contains(.read) { p.readValue(for: c) }
            else { status = "Sensor does not expose a readable measurement." }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error = error { status = "Notifications failed: \(error.localizedDescription)" }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let error = error { status = "Reading failed: \(error.localizedDescription)"; return }
        guard c.uuid == sensorCharacteristic, let data = c.value, let value = Reading(data) else { return }
        reading = value
        lastUpdated = Date()
        status = "Connected"
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.namak1.xiaomisensor.widget/Data/Library/Application Support/XiaomiSensor/reading.json")
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload: [String: Double] = ["temperature": value.temperature, "humidity": Double(value.humidity), "voltage": value.voltage, "timestamp": Date().timeIntervalSince1970]
            try JSONSerialization.data(withJSONObject: payload).write(to: path, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: "XiaomiSensorWidget")
        } catch {
            status = "Connected; widget data could not be saved: \(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @ObservedObject var sensor: Sensor
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Xiaomi Sensor").font(.largeTitle.bold())
                    Text("Temperature & humidity monitor").foregroundColor(.secondary)
                }
                Spacer()

            }
            HStack(spacing: 14) {
                metric("Temperature", sensor.reading.map { String(format: "%.1f °C", $0.temperature) } ?? "—", "thermometer")
                metric("Humidity", sensor.reading.map { "\($0.humidity) %" } ?? "—", "humidity")
                metric("Battery voltage", sensor.reading.map { String(format: "%.2f V", $0.voltage) } ?? "—", "battery.75")
            }
            HStack {
                Circle().fill(sensor.status == "Connected" ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(sensor.status).font(.callout)
                Spacer()
                if let date = sensor.lastUpdated { Text("Last reading: \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundColor(.secondary) }
            }
            Divider()
            HStack {
                Text("Nearby sensors").font(.headline)
                Spacer()
                Button("Scan") { sensor.scan() }
            }
            if sensor.devices.isEmpty {
                Text("No sensors found yet. Keep the sensor nearby and allow Bluetooth access.").foregroundColor(.secondary)
            } else {
                ForEach(sensor.devices, id: \.identifier) { p in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.name ?? "LYWSD03MMC")
                            Text(p.identifier.uuidString).font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(p.identifier == sensor.selectedID ? "Selected" : "Connect") { sensor.choose(p) }
                    }.padding(10).background(Color.secondary.opacity(0.08)).cornerRadius(8)
                }
            }
            Spacer()
            Text("Keep this app open to collect readings. Add the Xiaomi Sensor widget using Edit Widgets on your desktop. Widget updates are managed by macOS.").font(.caption).foregroundColor(.secondary)
        }.padding(24).frame(minWidth: 620, minHeight: 420)
    }
    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
        }.frame(maxWidth: .infinity, minHeight: 90, alignment: .leading).padding(14).background(Color.accentColor.opacity(0.09)).cornerRadius(12)
    }
}

@main struct XiaomiSensorApp: App {
    @StateObject private var sensor = Sensor()
    var body: some Scene {
        WindowGroup { ContentView(sensor: sensor) }
    }
}
