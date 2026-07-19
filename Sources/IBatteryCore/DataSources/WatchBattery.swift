import CLibimobiledevice
import Foundation

public func parseUDIDList(fromPairedDevicesPlist plist: plist_t?) -> [String] {
    guard let plist else { return [] }
    let count = plist_array_get_size(plist)
    var result: [String] = []
    for i in 0..<count {
        guard let item = plist_array_get_item(plist, i) else { continue }
        var cstr: UnsafeMutablePointer<CChar>?
        plist_get_string_val(item, &cstr)
        if let cstr {
            result.append(String(cString: cstr))
            plist_mem_free(cstr)
        }
    }
    return result
}

public func parseWatchBatteryValue(fromCapacityPlist capacityPlist: plist_t?, chargingPlist: plist_t?) -> (percentage: Int, isCharging: Bool)? {
    guard let capacityPlist else { return nil }
    var capacity: UInt64 = 0
    plist_get_uint_val(capacityPlist, &capacity)

    var isCharging = false
    if let chargingPlist {
        var chargingRaw: UInt8 = 0
        plist_get_bool_val(chargingPlist, &chargingRaw)
        isCharging = chargingRaw != 0
    }
    return (Int(capacity), isCharging)
}

public func parseWatchProductType(fromPlist plist: plist_t?) -> String? {
    guard let plist else { return nil }
    var cstr: UnsafeMutablePointer<CChar>?
    plist_get_string_val(plist, &cstr)
    guard let cstr else { return nil }
    defer { plist_mem_free(cstr) }
    return String(cString: cstr)
}

public struct WatchBatterySource: BatteryDataSource {
    public init() {}

    public func fetchAll() async -> [DeviceBatteryInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.fetchAllBlocking())
            }
        }
    }

    private static func fetchAllBlocking() -> [DeviceBatteryInfo] {
        let idResult = runLibimobiledeviceTool("idevice_id", ["-l"])
        guard idResult.exitCode == 0 else { return [] }

        let output = String(data: idResult.stdout, encoding: .utf8) ?? ""
        let iphoneUDIDs = parseDeviceIdList(output)

        var results: [DeviceBatteryInfo] = []
        for iphoneUDID in iphoneUDIDs {
            results.append(contentsOf: fetchWatches(pairedWithIPhoneUDID: iphoneUDID))
        }
        return results
    }

    private static func fetchWatches(pairedWithIPhoneUDID iphoneUDID: String) -> [DeviceBatteryInfo] {
        var device: idevice_t?
        guard idevice_new(&device, iphoneUDID) == IDEVICE_E_SUCCESS, let device else {
            return []
        }
        defer { idevice_free(device) }

        var client: companion_proxy_client_t?
        guard companion_proxy_client_start_service(device, &client, "ibattery-mcp") == COMPANION_PROXY_E_SUCCESS,
              let client
        else {
            return []
        }
        defer { companion_proxy_client_free(client) }

        var pairedDevicesPlist: plist_t?
        guard companion_proxy_get_device_registry(client, &pairedDevicesPlist) == COMPANION_PROXY_E_SUCCESS,
              let pairedDevicesPlist
        else {
            return []
        }
        defer { plist_free(pairedDevicesPlist) }

        let watchUDIDs = parseUDIDList(fromPairedDevicesPlist: pairedDevicesPlist)

        var results: [DeviceBatteryInfo] = []
        for watchUDID in watchUDIDs {
            if let info = fetchWatchBatteryInfo(client: client, watchUDID: watchUDID) {
                results.append(info)
            }
        }
        return results
    }

    private static func fetchWatchBatteryInfo(client: companion_proxy_client_t, watchUDID: String) -> DeviceBatteryInfo? {
        var capacityPlist: plist_t?
        let capacityResult = companion_proxy_get_value_from_registry(client, watchUDID, "BatteryCurrentCapacity", &capacityPlist)
        guard capacityResult == COMPANION_PROXY_E_SUCCESS, let capacityPlist else {
            return nil
        }
        defer { plist_free(capacityPlist) }

        var chargingPlist: plist_t?
        _ = companion_proxy_get_value_from_registry(client, watchUDID, "BatteryIsCharging", &chargingPlist)
        defer { if let chargingPlist { plist_free(chargingPlist) } }

        guard let battery = parseWatchBatteryValue(fromCapacityPlist: capacityPlist, chargingPlist: chargingPlist) else {
            return nil
        }

        var productTypePlist: plist_t?
        _ = companion_proxy_get_value_from_registry(client, watchUDID, "ProductType", &productTypePlist)
        defer { if let productTypePlist { plist_free(productTypePlist) } }
        let name = parseWatchProductType(fromPlist: productTypePlist) ?? watchUDID

        return DeviceBatteryInfo(
            id: watchUDID,
            name: name,
            kind: .watch,
            percentage: battery.percentage,
            isCharging: battery.isCharging,
            lastUpdated: Date()
        )
    }
}
