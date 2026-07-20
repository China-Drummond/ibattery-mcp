// Sources/IBatteryCore/DataSources/BLESnapshotMerge.swift
//
// Pure post-pass over DeviceRegistry results reconciling ble-helper
// snapshot entries (id prefix "ble-") with the official sources, per the
// merge rules in docs/superpowers/specs/2026-07-20-ble-advertisement-design.md
// §4–§6. Origin is determined entirely by the id prefix, so the pass is
// independent of source ordering.
import Foundation

/// Marks entries that came from the ble-helper's advertisement snapshot
/// rather than an official path.
public let bleSnapshotIDPrefix = "ble-"

/// How recently a BLE advertisement must have been seen for its battery
/// level to be preferred over system_profiler's cached value (spec §4).
public let bleAirPodsFreshnessWindow: TimeInterval = 600

/// Precomputed cross-references between the ble- snapshot entries and the
/// official-source entries in a single `mergeBLESnapshot` call, keyed by
/// device name (the only identifier the two sources agree on).
private struct BLESnapshotContext {
    let bleAirPodsByName: [String: DeviceBatteryInfo]
    let profilerAirPodsIDByName: [String: String]
    let officialIOSNames: Set<String>

    init(_ devices: [DeviceBatteryInfo]) {
        bleAirPodsByName = Dictionary(
            devices
                .filter { $0.kind == .airpods && $0.id.hasPrefix(bleSnapshotIDPrefix) }
                .map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        profilerAirPodsIDByName = Dictionary(
            devices
                .filter { $0.kind == .airpods && !$0.id.hasPrefix(bleSnapshotIDPrefix) }
                .map { ($0.name, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        officialIOSNames = Set(
            devices
                .filter { $0.kind == .iosDevice && !$0.id.hasPrefix(bleSnapshotIDPrefix) }
                .map(\.name)
        )
    }
}

/// Rule 2: a `ble-` iOS-device entry is dropped when an official
/// (non-`ble-`) entry with the same name exists — that official entry
/// always passes through untouched via the default case below. Otherwise
/// the BLE-GATT entry fills the gap (e.g. a locked phone libimobiledevice
/// can't read), stale-marked as needed.
private func resolveBLEIOSDevice(
    _ device: DeviceBatteryInfo, context: BLESnapshotContext, now: Date
) -> DeviceBatteryInfo? {
    guard !context.officialIOSNames.contains(device.name) else { return nil }
    return markStaleIfNeeded(device, now: now)
}

/// Rules 3–4: a `ble-` AirPods entry, fresh or stale.
private func resolveBLEAirPods(
    _ device: DeviceBatteryInfo, context: BLESnapshotContext, now: Date
) -> DeviceBatteryInfo? {
    let fresh = now.timeIntervalSince(device.lastUpdated) <= bleAirPodsFreshnessWindow
    if fresh {
        // Fresh advertisement data wins, but keeps the profiler's stable
        // MAC-based id when one exists.
        let id = context.profilerAirPodsIDByName[device.name] ?? device.id
        return markStaleIfNeeded(DeviceBatteryInfo(
            id: id,
            name: device.name,
            kind: .airpods,
            percentage: device.percentage,
            isCharging: device.isCharging,
            lastUpdated: device.lastUpdated,
            inCase: device.inCase,
            lidOpen: device.lidOpen
        ), now: now)
    }
    guard context.profilerAirPodsIDByName[device.name] == nil else {
        // Stale with a profiler entry present: skipped — the profiler
        // branch (resolveProfilerAirPods) carries the state over.
        return nil
    }
    // Stale, but BLE is the only source that knows this device — an honest
    // stale entry beats losing it entirely.
    return markStaleIfNeeded(device, now: now)
}

/// Rules 3 & 5: a profiler (non-`ble-`) AirPods entry, possibly superseded
/// or supplemented by a same-name `ble-` entry.
private func resolveProfilerAirPods(
    _ device: DeviceBatteryInfo, context: BLESnapshotContext, now: Date
) -> DeviceBatteryInfo? {
    guard let ble = context.bleAirPodsByName[device.name] else { return device }
    let bleFresh = now.timeIntervalSince(ble.lastUpdated) <= bleAirPodsFreshnessWindow
    guard !bleFresh else {
        // The fresh BLE entry already claimed this name (and this id).
        return nil
    }
    // Profiler's cached level, but the monitor's last-known in-case state
    // with its honest last-seen timestamp (spec §4.2). isCharging: nil —
    // the profiler doesn't know it and the BLE data is too old to assert it.
    return markStaleIfNeeded(DeviceBatteryInfo(
        id: device.id,
        name: device.name,
        kind: .airpods,
        percentage: device.percentage,
        isCharging: nil,
        lastUpdated: ble.lastUpdated,
        inCase: ble.inCase,
        lidOpen: ble.lidOpen
    ), now: now)
}

public func mergeBLESnapshot(_ devices: [DeviceBatteryInfo], now: Date) -> [DeviceBatteryInfo] {
    let context = BLESnapshotContext(devices)

    var merged: [DeviceBatteryInfo] = []
    var seenIDs = Set<String>()

    // Rule 1: any entry whose exact id was already emitted is dropped
    // (absorbs old-helper skew, where "snapshot" returns generic-scan
    // duplicates).
    func emit(_ device: DeviceBatteryInfo?) {
        guard let device, !seenIDs.contains(device.id) else { return }
        seenIDs.insert(device.id)
        merged.append(device)
    }

    for device in devices {
        let isBLE = device.id.hasPrefix(bleSnapshotIDPrefix)
        switch device.kind {
        case .iosDevice where isBLE:
            emit(resolveBLEIOSDevice(device, context: context, now: now))
        case .airpods where isBLE:
            emit(resolveBLEAirPods(device, context: context, now: now))
        case .airpods where !isBLE:
            emit(resolveProfilerAirPods(device, context: context, now: now))
        default:
            // Rule 6: everything else (official iOS entries, mac, watch,
            // bleGeneric) passes through unchanged.
            emit(device)
        }
    }
    return merged
}
