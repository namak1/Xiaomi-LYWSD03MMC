import Foundation
import AppKit

@main struct CollectorLauncher {
    static func main() {
        guard let selected = UserDefaults(suiteName: "com.namak1.xiaomisensor")?.string(forKey: "selectedSensorUUID"), !selected.isEmpty else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.namak1.xiaomisensor").isEmpty else { return }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", app.path, "--args", "--background"]
        do { try open.run(); open.waitUntilExit() } catch { NSLog("Could not start sensor monitor: %@", error.localizedDescription) }
    }
}
