// Sources/IBatteryCore/DataSources/AirPodsBattery.swift
import Foundation

private let airPodsVendorID = "0x004C"

private func parsedBatteryPercentage(_ raw: Any?) -> Int? {
    guard let string = raw as? String else { return nil }
    let cleaned = string
        .replacingOccurrences(of: "%", with: "")
        .trimmingCharacters(in: .whitespaces)
    return Int(cleaned)
}

/// Component label ("Left"/"Right"/"Case") and the `system_profiler` JSON key
/// that carries its battery percentage, in the order entries are emitted.
private let airPodsComponents: [(label: String, batteryKey: String)] = [
    (label: "Left", batteryKey: "device_batteryLevelLeft"),
    (label: "Right", batteryKey: "device_batteryLevelRight"),
    (label: "Case", batteryKey: "device_batteryLevelCase")
]

private func airPodsEntry(
    component: (label: String, batteryKey: String),
    info: [String: Any],
    lowercasedAddress: String,
    displayName: String,
    fetchedAt: Date
) -> DeviceBatteryInfo? {
    guard let percentage = parsedBatteryPercentage(info[component.batteryKey]) else { return nil }
    return DeviceBatteryInfo(
        id: "\(lowercasedAddress)-\(component.label.lowercased())",
        name: "\(displayName) (\(component.label))",
        kind: .airpods,
        percentage: percentage,
        isCharging: nil,
        lastUpdated: fetchedAt
    )
}

/// Parses `system_profiler SPBluetoothDataType -json` output into up to
/// three `DeviceBatteryInfo` entries (Left/Right/Case) per Apple-vendor
/// device that reports any of `device_batteryLevelLeft`/`Right`/`Case`.
/// Filters by field presence rather than matching "AirPods" in the device
/// name, so other same-chipset earbuds (e.g. Beats) are covered too. Scans
/// both `device_connected` and `device_not_connected`, since `system_profiler`
/// keeps reporting the last-known battery level for a device that's
/// currently disconnected (confirmed against real hardware during design).
public func parseSystemProfilerBluetoothJSON(_ data: Data, fetchedAt: Date) -> [DeviceBatteryInfo] {
    guard let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
          let dataTypeArray = root["SPBluetoothDataType"] as? [Any],
          let dataType = dataTypeArray.first as? [String: Any]
    else {
        return []
    }

    let connected = dataType["device_connected"] as? [Any] ?? []
    let notConnected = dataType["device_not_connected"] as? [Any] ?? []

    var results: [DeviceBatteryInfo] = []
    for entry in connected + notConnected {
        guard let entryDict = entry as? [String: Any],
              let name = entryDict.keys.first,
              let info = entryDict[name] as? [String: Any],
              info["device_vendorID"] as? String == airPodsVendorID,
              let address = info["device_address"] as? String,
              !address.isEmpty
        else {
            continue
        }

        let lowercasedAddress = address.lowercased()

        for component in airPodsComponents {
            if let entry = airPodsEntry(
                component: component,
                info: info,
                lowercasedAddress: lowercasedAddress,
                displayName: name,
                fetchedAt: fetchedAt
            ) {
                results.append(entry)
            }
        }
    }
    return results
}

public struct AirPodsBatterySource: BatteryDataSource {
    public init() {}

    public func fetchAll() async -> [DeviceBatteryInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runSubprocess("system_profiler", ["SPBluetoothDataType", "-json"])
                guard result.exitCode == 0 else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: parseSystemProfilerBluetoothJSON(result.stdout, fetchedAt: Date()))
            }
        }
    }
}
