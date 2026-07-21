// Sources/IBatteryCore/DataSources/BLEAdvertisementMonitor.swift
//
// Runs only inside ibattery-ble-helper. Periodically passive-scans all BLE
// advertisements (AirPods stop broadcasting shortly after their lid closes,
// so an on-demand scan would miss the lid-close message that carries the
// exact per-bud in-case state — continuous listening is what catches it),
// feeds them to BLEAdvertisementCache, and serves the "snapshot" IPC
// request: cached AirPods entries plus a bounded GATT battery read of every
// remembered iOS-device candidate. All state is confined to the main queue:
// the CBCentralManager is created with queue: .main and snapshot() hops to
// the main queue before touching anything.
import CoreBluetooth
import Foundation

let deviceInformationServiceUUID = CBUUID(string: "180A")
let modelNumberCharacteristicUUID = CBUUID(string: "2A24")

public final class BLEAdvertisementMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager?
    private var cache = BLEAdvertisementCache()
    private var candidatePeripherals: [UUID: CBPeripheral] = [:]
    private var candidateLastSeen: [UUID: Date] = [:]
    private var scanTimer: Timer?

    private let initialScanDuration: TimeInterval = 15
    private let periodicScanDuration: TimeInterval = 5
    private let scanInterval: TimeInterval = 30
    private let perDeviceGATTTimeout: TimeInterval = 5
    private let totalGATTTimeout: TimeInterval = 10
    // Candidates not re-seen in an advertisement within this window are
    // evicted before each GATT snapshot. 600s (10 minutes) matches the
    // MCP-side freshness window's notion of "nearby recently" — a candidate
    // this stale wouldn't be reported as fresh even if the GATT read
    // succeeded, so there's no point still connecting to it.
    private let candidateTTL: TimeInterval = 600

    // In-flight GATT snapshot state (main queue only). One snapshot at a
    // time: a second concurrent request gets [] for the iOS portion rather
    // than corrupting the first one's bookkeeping. gattGeneration guards
    // against a completed snapshot's stray timers firing into the next
    // snapshot's state.
    private var gattCompletion: (([DeviceBatteryInfo]) -> Void)?
    private var gattGeneration = 0
    private var gattPending: Set<UUID> = []
    private var gattLevels: [UUID: Int] = [:]
    private var gattModels: [UUID: String] = [:]
    private var gattNames: [UUID: String] = [:]

    /// Call once at helper startup, from the main queue.
    public func start() {
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            scanTimer?.invalidate()
            scanTimer = nil
            return
        }
        beginScan(duration: initialScanDuration)
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.beginScan(duration: self.periodicScanDuration)
        }
    }

    private func beginScan(duration: TimeInterval) {
        guard let central = centralManager, central.state == .poweredOn, !central.isScanning else { return }
        // Allow duplicates so a mid-window state change (e.g. the one-shot
        // lid-close message right after an open message from the same
        // peripheral) isn't coalesced away.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.centralManager?.stopScan()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let name = peripheral.name,
              let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        else { return }
        cache.ingest(deviceName: name, peripheralID: peripheral.identifier, manufacturerData: data, at: Date())
        // Retain the CBPeripheral for iOS candidates — connect() needs the
        // object, not just its identifier.
        if cache.iosCandidates[name] == peripheral.identifier {
            candidatePeripherals[peripheral.identifier] = peripheral
            candidateLastSeen[peripheral.identifier] = Date()
        }
    }

    /// Serves the helper's "snapshot" IPC request.
    public func snapshot() async -> [DeviceBatteryInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let airpods = self.cache.airpodsEntries()
                self.startGATTReads { iosDevices in
                    continuation.resume(returning: airpods + iosDevices)
                }
            }
        }
    }

    // MARK: - GATT reads of iOS candidates (main queue only)

    private func startGATTReads(completion: @escaping ([DeviceBatteryInfo]) -> Void) {
        let now = Date()
        let staleIDs = candidatePeripherals.keys.filter { id in
            guard let lastSeen = candidateLastSeen[id] else { return true }
            return now.timeIntervalSince(lastSeen) > candidateTTL
        }
        for id in staleIDs {
            candidatePeripherals.removeValue(forKey: id)
            candidateLastSeen.removeValue(forKey: id)
        }
        let peripherals = Array(candidatePeripherals.values)
        guard !peripherals.isEmpty,
              let central = centralManager, central.state == .poweredOn,
              gattCompletion == nil
        else {
            completion([])
            return
        }
        gattGeneration += 1
        let generation = gattGeneration
        gattCompletion = completion
        gattPending = Set(peripherals.map(\.identifier))
        gattLevels = [:]
        gattModels = [:]
        gattNames = [:]
        for peripheral in peripherals {
            gattNames[peripheral.identifier] = peripheral.name
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            let id = peripheral.identifier
            DispatchQueue.main.asyncAfter(deadline: .now() + perDeviceGATTTimeout) { [weak self] in
                self?.finishCandidate(id, generation: generation, cancel: peripheral)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + totalGATTTimeout) { [weak self] in
            self?.finishAllCandidates(generation: generation)
        }
    }

    private func finishCandidate(_ id: UUID, generation: Int, cancel peripheral: CBPeripheral? = nil) {
        guard generation == gattGeneration else { return }
        guard gattPending.contains(id) else { return }
        gattPending.remove(id)
        if let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        if gattPending.isEmpty {
            finishAllCandidates(generation: generation)
        }
    }

    private func finishAllCandidates(generation: Int) {
        guard generation == gattGeneration else { return }
        guard let completion = gattCompletion else { return }
        gattCompletion = nil
        gattPending = []
        var results: [DeviceBatteryInfo] = []
        let now = Date()
        for (id, level) in gattLevels.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            // Apple Watch exclusion: its GATT battery is not reliable
            // (AirBattery applies the same exclusion). A device that never
            // reported a model string is kept — the filter only drops
            // confirmed Watches.
            if let model = gattModels[id], model.contains("Watch") { continue }
            results.append(DeviceBatteryInfo(
                id: "ble-\(id.uuidString.lowercased())",
                name: gattNames[id] ?? "Unknown iOS Device",
                kind: .iosDevice,
                percentage: level,
                isCharging: nil,
                lastUpdated: now
            ))
        }
        completion(results)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryServiceUUID, deviceInformationServiceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishCandidate(peripheral.identifier, generation: gattGeneration)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            finishCandidate(peripheral.identifier, generation: gattGeneration, cancel: peripheral)
            return
        }
        for service in services {
            if service.uuid == batteryServiceUUID {
                peripheral.discoverCharacteristics([batteryLevelCharacteristicUUID], for: service)
            } else if service.uuid == deviceInformationServiceUUID {
                peripheral.discoverCharacteristics([modelNumberCharacteristicUUID], for: service)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            peripheral.readValue(for: characteristic)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        if characteristic.uuid == batteryLevelCharacteristicUUID,
           let data = characteristic.value,
           let level = parseBatteryLevelCharacteristic(data) {
            gattLevels[id] = level
        }
        if characteristic.uuid == modelNumberCharacteristicUUID, let data = characteristic.value {
            gattModels[id] = String(data: data, encoding: .ascii) ?? ""
        }
        if gattLevels[id] != nil && gattModels[id] != nil {
            finishCandidate(id, generation: gattGeneration, cancel: peripheral)
        }
    }
}
