# ibattery-mcp Plan 1: Core Scaffold + Mac Battery + Generic BLE Devices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a working, testable MCP server (`ibattery-mcp`) that answers battery/status questions for this Mac's own battery and any nearby Bluetooth devices exposing the standard GATT Battery Service, via three MCP tools (`get_all_devices_status`, `get_device_battery`, `list_known_devices`).

**Architecture:** A single Swift Package with a thin `ibattery-mcp` executable target (stdio entry point) and a testable `IBatteryCore` library target containing all logic: device data models, per-device-type data sources conforming to a shared `BatteryDataSource` protocol, a `DeviceRegistry` actor that aggregates sources and answers queries, and the MCP tool wiring built on the official Swift SDK.

**Tech Stack:** Swift 5.9 tools-version (Swift 5 language mode) targeting macOS 13+, `modelcontextprotocol/swift-sdk` for the MCP protocol layer over stdio, `IOKit.ps` for the Mac's own battery, `CoreBluetooth` for generic BLE Battery Service devices, XCTest for unit + blackbox integration tests.

## Global Constraints

- Repo root: `/Users/drummond/Documents/workspace/ibattery-mcp` (already a git repo, `main` branch, one prior commit for the design doc).
- Project/binary/package name: `ibattery-mcp` throughout.
- `swift-tools-version: 5.9` — gives our own code Swift 5 language mode (no Swift 6 strict-concurrency checking friction), independent of the SDK dependency's own tools-version.
- Platform floor: `.macOS(.v13)` — matches the MCP Swift SDK's own minimum (`.macOS("13.0")`); building for anything lower will fail dependency resolution.
- MCP SDK dependency: `.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")`. **Verified fact, not a guess:** the correct `package:` argument for `.product(name: "MCP", package: "swift-sdk")` is `"swift-sdk"` (the URL-derived identity) — **not** `"mcp-swift-sdk"`, even though that is the name declared inside the SDK's own `Package.swift`. This was confirmed by actually building a probe package; do not "fix" it to match the internal manifest name.
- **Building test targets requires full Xcode installed (not just Command Line Tools)** — `import XCTest` is unavailable under CLT-only. Run `xcrun --find xctest` first; if it errors, install Xcode from the App Store / developer.apple.com before starting Task 1's test steps.
- MIT license for the whole project (LICENSE file itself is added in a later plan — not blocking for this plan's code).
- No code or bundled binaries from AirBattery (AGPLv3) are to be copied anywhere in this plan.
- This plan's scope is deliberately limited to: project scaffold, MCP tool surface, the Mac's own battery, and generic BLE devices exposing the standard GATT Battery Service (`180F`/`2A19`). AirPods' proprietary Apple Continuity protocol, iPhone/iPad, Apple Watch, and the LAN multi-Mac companion are explicitly out of scope for this plan (see design doc `docs/superpowers/specs/2026-07-19-ibattery-mcp-design.md` §3 and §10) and will be covered by later plans.

---

### Task 1: Package scaffold + minimal MCP stdio server

**Files:**
- Create: `Package.swift`
- Create: `Sources/IBatteryCore/MCPServerFactory.swift`
- Create: `Sources/ibattery-mcp/main.swift`
- Create: `Tests/IBatteryCoreTests/MCPServerSmokeTests.swift`

**Interfaces:**
- Produces: `public func makeServer() async -> Server` in `IBatteryCore` (Task 5 will change this signature to accept a `DeviceRegistry` parameter — that's expected and handled in Task 5, not here).

- [ ] **Step 1: Create the package manifest**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ibattery-mcp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        .target(
            name: "IBatteryCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .executableTarget(
            name: "ibattery-mcp",
            dependencies: ["IBatteryCore"]
        ),
        .testTarget(
            name: "IBatteryCoreTests",
            dependencies: ["IBatteryCore"]
        )
    ]
)
```

Save this as `Package.swift` at the repo root.

- [ ] **Step 2: Write the server factory**

```swift
// Sources/IBatteryCore/MCPServerFactory.swift
import MCP

public func makeServer() async -> Server {
    let server = Server(
        name: "ibattery-mcp",
        version: "0.1.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [])
    }

    await server.withMethodHandler(CallTool.self) { params in
        return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
    }

    return server
}
```

- [ ] **Step 3: Write the executable entry point**

```swift
// Sources/ibattery-mcp/main.swift
import IBatteryCore
import MCP

let server = await makeServer()
let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
```

- [ ] **Step 4: Build and verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors. (First build will take 1-2 minutes while the SDK dependency and its own dependencies — swift-system, swift-log, eventsource, swift-nio — compile; subsequent builds are fast.)

If the build fails on the `.product(name: "MCP", package: "swift-sdk")` line with a "product not found" style error, do not guess — run `swift package resolve` and inspect `.build/checkouts/swift-sdk/Package.swift` for the actual declared product/target names for the resolved version, and adjust to match.

- [ ] **Step 5: Manually verify the server responds over stdio**

Run:
```bash
BIN=$(swift build --show-bin-path)/ibattery-mcp
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe-client","version":"0.1"}}}'
  sleep 0.3
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  sleep 0.3
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  sleep 0.3
} | "$BIN" &
PID=$!
sleep 2
kill $PID 2>/dev/null
wait $PID 2>/dev/null
```
Expected: two JSON lines printed to stdout — an `initialize` result containing `"serverInfo":{"name":"ibattery-mcp"...}`, and a `tools/list` result containing `"tools":[]`.

- [ ] **Step 6: Write the blackbox integration test**

```swift
// Tests/IBatteryCoreTests/MCPServerSmokeTests.swift
import XCTest

final class MCPServerSmokeTests: XCTestCase {
    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("Couldn't find the products directory")
    }

    private var executableURL: URL {
        productsDirectory.appendingPathComponent("ibattery-mcp")
    }

    func testServerRespondsToToolsList() throws {
        let process = Process()
        process.executableURL = executableURL
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try process.run()
        defer { process.terminate() }

        let initRequest = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-client","version":"0.1"}}}"# + "\n"
        inPipe.fileHandleForWriting.write(initRequest.data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.3)

        let initializedNotification = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n"
        inPipe.fileHandleForWriting.write(initializedNotification.data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.2)

        let listRequest = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"# + "\n"
        inPipe.fileHandleForWriting.write(listRequest.data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.3)

        let outputData = outPipe.fileHandleForReading.availableData
        let response = String(data: outputData, encoding: .utf8) ?? ""
        XCTAssertTrue(response.contains("\"tools\""), "Expected a tools/list response, got: \(response)")
    }
}
```

- [ ] **Step 7: Run the test and verify it passes**

Run: `swift test --filter MCPServerSmokeTests`
Expected: `Test Suite 'MCPServerSmokeTests' passed` (requires full Xcode per Global Constraints — if `swift test` fails with "no such module 'XCTest'", install Xcode first).

- [ ] **Step 8: Add a .gitignore and commit**

```
.build/
.swiftpm/
*.xcodeproj
.DS_Store
```
Save as `.gitignore` at repo root.

```bash
git add Package.swift Sources Tests .gitignore
git commit -m "Add MCP stdio server scaffold with empty tool list"
```

---

### Task 2: Device model + Mac battery source

**Files:**
- Create: `Sources/IBatteryCore/DeviceBatteryInfo.swift`
- Create: `Sources/IBatteryCore/DataSources/MacBattery.swift`
- Create: `Tests/IBatteryCoreTests/MacBatteryTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `public struct DeviceBatteryInfo: Codable, Equatable, Sendable` with fields `id: String`, `name: String`, `kind: DeviceBatteryInfo.Kind`, `percentage: Int`, `isCharging: Bool?`, `lastUpdated: Date`, `stale: Bool`. `public struct MacBatterySource` (defined in Task 4's `BatteryDataSource` protocol — see note in Step 4 below). `public func parseMacBatteryDescription(_ description: [String: Any]) -> DeviceBatteryInfo?` and `public func fetchMacBatteryInfo() -> DeviceBatteryInfo?` as free functions.

- [ ] **Step 1: Write the shared device model**

```swift
// Sources/IBatteryCore/DeviceBatteryInfo.swift
import Foundation

public struct DeviceBatteryInfo: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case mac
        case bleGeneric
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let percentage: Int
    public let isCharging: Bool?
    public let lastUpdated: Date
    public let stale: Bool

    public init(
        id: String,
        name: String,
        kind: Kind,
        percentage: Int,
        isCharging: Bool?,
        lastUpdated: Date,
        stale: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.percentage = percentage
        self.isCharging = isCharging
        self.lastUpdated = lastUpdated
        self.stale = stale
    }
}
```

- [ ] **Step 2: Write the failing test for the pure parsing function**

```swift
// Tests/IBatteryCoreTests/MacBatteryTests.swift
import XCTest
@testable import IBatteryCore

final class MacBatteryTests: XCTestCase {
    func testParseMacBatteryDescription_returnsCorrectInfo() {
        let description: [String: Any] = [
            kIOPSCurrentCapacityKeyForTest: 87,
            kIOPSIsChargingKeyForTest: true
        ]
        let info = parseMacBatteryDescription(description)
        XCTAssertEqual(info?.percentage, 87)
        XCTAssertEqual(info?.isCharging, true)
        XCTAssertEqual(info?.kind, .mac)
    }

    func testParseMacBatteryDescription_missingCapacity_returnsNil() {
        let description: [String: Any] = [:]
        XCTAssertNil(parseMacBatteryDescription(description))
    }
}

// Test-only string constants mirroring the real IOKit key names, so this
// test file doesn't need to import IOKit.ps itself.
let kIOPSCurrentCapacityKeyForTest = "Current Capacity"
let kIOPSIsChargingKeyForTest = "Is Charging"
```

- [ ] **Step 3: Run it and verify it fails (function doesn't exist yet)**

Run: `swift test --filter MacBatteryTests`
Expected: FAIL to compile — `parseMacBatteryDescription` not found.

- [ ] **Step 4: Implement the Mac battery source**

```swift
// Sources/IBatteryCore/DataSources/MacBattery.swift
import Foundation
import IOKit.ps

public func parseMacBatteryDescription(_ description: [String: Any]) -> DeviceBatteryInfo? {
    guard let capacity = description[kIOPSCurrentCapacityKey as String] as? Int else {
        return nil
    }
    let isCharging = description[kIOPSIsChargingKey as String] as? Bool
    return DeviceBatteryInfo(
        id: "mac-internal-battery",
        name: Host.current().localizedName ?? "This Mac",
        kind: .mac,
        percentage: capacity,
        isCharging: isCharging,
        lastUpdated: Date()
    )
}

public func fetchMacBatteryInfo() -> DeviceBatteryInfo? {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
    guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            continue
        }
        guard (description[kIOPSTypeKey as String] as? String) == kIOPSInternalBatteryType else {
            continue
        }
        return parseMacBatteryDescription(description)
    }
    return nil
}

public struct MacBatterySource: Sendable {
    public init() {}
    public func fetchAll() async -> [DeviceBatteryInfo] {
        if let info = fetchMacBatteryInfo() {
            return [info]
        }
        return []
    }
}
```

Note: `MacBatterySource` does not yet declare conformance to `BatteryDataSource` — that protocol is defined in Task 4. Task 4 adds `: BatteryDataSource` to this declaration; it already has the right shape (`func fetchAll() async -> [DeviceBatteryInfo]`) so no logic changes are needed there, only the conformance annotation.

Update the test file's fixture keys to use the real IOKit constant string values (`"Current Capacity"` and `"Is Charging"` are the actual raw string values IOKit uses for these keys — the test uses its own string literals rather than importing IOKit.ps directly, so the test stays a pure-logic test independent of the IOKit import):

- [ ] **Step 5: Run the tests and verify they pass**

Run: `swift test --filter MacBatteryTests`
Expected: `Test Suite 'MacBatteryTests' passed` (2 tests).

- [ ] **Step 6: Manual QA note (do not skip when validating this task on real hardware)**

`fetchMacBatteryInfo()` itself is not unit-tested (it calls live IOKit APIs) — before considering this task done on a real machine, run:
```bash
swift run ibattery-mcp &
```
is not yet wired to expose this (that happens in Task 5); for now, manually verify via a throwaway `print(fetchMacBatteryInfo())` in `main.swift`, run `swift run`, confirm it prints a `DeviceBatteryInfo` with a plausible percentage, then revert the throwaway print before committing.

- [ ] **Step 7: Commit**

```bash
git add Sources/IBatteryCore/DeviceBatteryInfo.swift Sources/IBatteryCore/DataSources/MacBattery.swift Tests/IBatteryCoreTests/MacBatteryTests.swift
git commit -m "Add device model and Mac internal battery data source"
```

---

### Task 3: Generic BLE Battery Service scanner

**Files:**
- Create: `Sources/IBatteryCore/DataSources/BLEBattery.swift`
- Create: `Tests/IBatteryCoreTests/BLEBatteryParsingTests.swift`

**Interfaces:**
- Consumes: `DeviceBatteryInfo` from Task 2.
- Produces: `public let batteryServiceUUID: CBUUID`, `public let batteryLevelCharacteristicUUID: CBUUID`, `public func parseBatteryLevelCharacteristic(_ data: Data) -> Int?`, `public final class BLEBatteryScanner`, `public struct BLEBatterySource` with `func fetchAll() async -> [DeviceBatteryInfo]` (same note as Task 2 re: `BatteryDataSource` conformance being added in Task 4).

- [ ] **Step 1: Write the failing test for the pure parsing function**

```swift
// Tests/IBatteryCoreTests/BLEBatteryParsingTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class BLEBatteryParsingTests: XCTestCase {
    func testParseBatteryLevelCharacteristic_returnsPercentage() {
        let data = Data([100])
        XCTAssertEqual(parseBatteryLevelCharacteristic(data), 100)
    }

    func testParseBatteryLevelCharacteristic_emptyData_returnsNil() {
        XCTAssertNil(parseBatteryLevelCharacteristic(Data()))
    }
}
```

- [ ] **Step 2: Run it and verify it fails**

Run: `swift test --filter BLEBatteryParsingTests`
Expected: FAIL to compile — `parseBatteryLevelCharacteristic` not found.

- [ ] **Step 3: Implement the BLE Battery Service scanner**

```swift
// Sources/IBatteryCore/DataSources/BLEBattery.swift
import CoreBluetooth
import Foundation

public let batteryServiceUUID = CBUUID(string: "180F")
public let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")

public func parseBatteryLevelCharacteristic(_ data: Data) -> Int? {
    guard let firstByte = data.first else { return nil }
    return Int(firstByte)
}

public final class BLEBatteryScanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager!
    private var discoveredPeripherals: [CBPeripheral] = []
    private var pendingPeripherals: Set<UUID> = []
    private var results: [DeviceBatteryInfo] = []
    private var continuation: CheckedContinuation<[DeviceBatteryInfo], Never>?
    private var scanDuration: TimeInterval = 4.0
    private var finished = false

    public override init() {
        super.init()
    }

    public func scan(duration: TimeInterval = 4.0) async -> [DeviceBatteryInfo] {
        scanDuration = duration
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.centralManager = CBCentralManager(delegate: self, queue: .main)
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        centralManager.stopScan()
        continuation?.resume(returning: results)
        continuation = nil
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            finish()
            return
        }
        central.scanForPeripherals(withServices: [batteryServiceUUID], options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + scanDuration) { [weak self] in
            self?.finish()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard !pendingPeripherals.contains(peripheral.identifier) else { return }
        pendingPeripherals.insert(peripheral.identifier)
        discoveredPeripherals.append(peripheral)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryServiceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        pendingPeripherals.remove(peripheral.identifier)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services where service.uuid == batteryServiceUUID {
            peripheral.discoverCharacteristics([batteryLevelCharacteristicUUID], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == batteryLevelCharacteristicUUID {
            peripheral.readValue(for: characteristic)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              characteristic.uuid == batteryLevelCharacteristicUUID,
              let data = characteristic.value,
              let percentage = parseBatteryLevelCharacteristic(data)
        else { return }

        let info = DeviceBatteryInfo(
            id: peripheral.identifier.uuidString,
            name: peripheral.name ?? "Unknown BLE Device",
            kind: .bleGeneric,
            percentage: percentage,
            isCharging: nil,
            lastUpdated: Date()
        )
        results.append(info)
        centralManager.cancelPeripheralConnection(peripheral)
    }
}

public struct BLEBatterySource: Sendable {
    let scanDuration: TimeInterval
    public init(scanDuration: TimeInterval = 4.0) {
        self.scanDuration = scanDuration
    }
    public func fetchAll() async -> [DeviceBatteryInfo] {
        await BLEBatteryScanner().scan(duration: scanDuration)
    }
}
```

- [ ] **Step 4: Run the parsing tests and verify they pass**

Run: `swift test --filter BLEBatteryParsingTests`
Expected: `Test Suite 'BLEBatteryParsingTests' passed` (2 tests).

- [ ] **Step 5: Bluetooth permission note**

The first time `BLEBatteryScanner` actually runs on a real Mac, macOS will prompt for Bluetooth permission (or silently return `.denied`/`.restricted` if run from a context that can't prompt, e.g. a bare command-line tool without an associated app bundle/Info.plist). This task does not add explicit permission-check error handling yet — that is intentionally deferred to Task 6 alongside the stale-data-marking work, once this source is wired into an actual tool call that can surface a warning. Do not add ad-hoc permission handling here.

- [ ] **Step 6: Manual QA note**

`BLEBatteryScanner`/`BLEBatterySource` cannot be unit-tested (real Bluetooth hardware + real peripherals required — no BLE Battery Service peripheral is likely to be present in CI). Before considering this task validated on real hardware: pair a BLE accessory that exposes the standard Battery Service (many Bluetooth mice/keyboards, fitness trackers, etc. do — note that AirPods do NOT expose this standard service, they use Apple's proprietary Continuity protocol which is out of scope for this plan), then manually confirm scanning finds it (same throwaway-print-in-main.swift technique as Task 2's manual QA step).

- [ ] **Step 7: Commit**

```bash
git add Sources/IBatteryCore/DataSources/BLEBattery.swift Tests/IBatteryCoreTests/BLEBatteryParsingTests.swift
git commit -m "Add generic BLE Battery Service scanner and data source"
```

---

### Task 4: DeviceRegistry aggregation

**Files:**
- Create: `Sources/IBatteryCore/DeviceRegistry.swift`
- Create: `Tests/IBatteryCoreTests/DeviceRegistryTests.swift`
- Modify: `Sources/IBatteryCore/DataSources/MacBattery.swift:33` (add `: BatteryDataSource` conformance to `MacBatterySource` declaration)
- Modify: `Sources/IBatteryCore/DataSources/BLEBattery.swift` (add `: BatteryDataSource` conformance to `BLEBatterySource` declaration)

**Interfaces:**
- Consumes: `DeviceBatteryInfo` (Task 2), `MacBatterySource` (Task 2), `BLEBatterySource` (Task 3).
- Produces: `public protocol BatteryDataSource: Sendable { func fetchAll() async -> [DeviceBatteryInfo] }`, `public actor DeviceRegistry` with `init(sources: [BatteryDataSource])`, `func getAllDevicesStatus() async -> [DeviceBatteryInfo]`, `func getDeviceBattery(query: String) async -> DeviceBatteryInfo?`, `func listKnownDevices() async -> [DeviceBatteryInfo]`.

- [ ] **Step 1: Write the failing tests using fake sources**

```swift
// Tests/IBatteryCoreTests/DeviceRegistryTests.swift
import XCTest
@testable import IBatteryCore

private struct FakeBatterySource: BatteryDataSource {
    let devices: [DeviceBatteryInfo]
    func fetchAll() async -> [DeviceBatteryInfo] { devices }
}

final class DeviceRegistryTests: XCTestCase {
    func testGetAllDevicesStatus_aggregatesAllSources() async {
        let source1 = FakeBatterySource(devices: [
            DeviceBatteryInfo(id: "a", name: "Mac", kind: .mac, percentage: 90, isCharging: true, lastUpdated: Date())
        ])
        let source2 = FakeBatterySource(devices: [
            DeviceBatteryInfo(id: "b", name: "Generic BLE", kind: .bleGeneric, percentage: 60, isCharging: nil, lastUpdated: Date())
        ])
        let registry = DeviceRegistry(sources: [source1, source2])
        let result = await registry.getAllDevicesStatus()
        XCTAssertEqual(result.count, 2)
    }

    func testGetDeviceBattery_findsMatchingDeviceByNameSubstring() async {
        let source = FakeBatterySource(devices: [
            DeviceBatteryInfo(id: "a", name: "MacBook Pro", kind: .mac, percentage: 90, isCharging: true, lastUpdated: Date())
        ])
        let registry = DeviceRegistry(sources: [source])
        let result = await registry.getDeviceBattery(query: "macbook")
        XCTAssertEqual(result?.id, "a")
    }

    func testGetDeviceBattery_noMatch_returnsNil() async {
        let registry = DeviceRegistry(sources: [])
        let result = await registry.getDeviceBattery(query: "nonexistent")
        XCTAssertNil(result)
    }

    func testListKnownDevices_returnsCachedAfterScan() async {
        let source = FakeBatterySource(devices: [
            DeviceBatteryInfo(id: "a", name: "Mac", kind: .mac, percentage: 90, isCharging: true, lastUpdated: Date())
        ])
        let registry = DeviceRegistry(sources: [source])
        _ = await registry.getAllDevicesStatus()
        let known = await registry.listKnownDevices()
        XCTAssertEqual(known.count, 1)
    }

    func testListKnownDevices_emptyBeforeAnyScan() async {
        let registry = DeviceRegistry(sources: [])
        let known = await registry.listKnownDevices()
        XCTAssertEqual(known.count, 0)
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `swift test --filter DeviceRegistryTests`
Expected: FAIL to compile — `BatteryDataSource` and `DeviceRegistry` not found.

- [ ] **Step 3: Implement the registry**

```swift
// Sources/IBatteryCore/DeviceRegistry.swift
import Foundation

public protocol BatteryDataSource: Sendable {
    func fetchAll() async -> [DeviceBatteryInfo]
}

public actor DeviceRegistry {
    private let sources: [BatteryDataSource]
    private var cache: [String: DeviceBatteryInfo] = [:]

    public init(sources: [BatteryDataSource]) {
        self.sources = sources
    }

    public func getAllDevicesStatus() async -> [DeviceBatteryInfo] {
        var results: [DeviceBatteryInfo] = []
        for source in sources {
            results.append(contentsOf: await source.fetchAll())
        }
        for device in results {
            cache[device.id] = device
        }
        return results
    }

    public func getDeviceBattery(query: String) async -> DeviceBatteryInfo? {
        let all = await getAllDevicesStatus()
        let lowerQuery = query.lowercased()
        return all.first { $0.name.lowercased().contains(lowerQuery) }
    }

    public func listKnownDevices() async -> [DeviceBatteryInfo] {
        Array(cache.values)
    }
}
```

- [ ] **Step 4: Wire up `BatteryDataSource` conformance on the two existing sources**

In `Sources/IBatteryCore/DataSources/MacBattery.swift`, change:
```swift
public struct MacBatterySource: Sendable {
```
to:
```swift
public struct MacBatterySource: BatteryDataSource {
```

In `Sources/IBatteryCore/DataSources/BLEBattery.swift`, change:
```swift
public struct BLEBatterySource: Sendable {
```
to:
```swift
public struct BLEBatterySource: BatteryDataSource {
```

(`BatteryDataSource` already refines `Sendable`, so dropping the now-redundant standalone `Sendable` conformance in favor of `BatteryDataSource` is correct and required — a type can't declare the same protocol twice, but `Sendable` conformance is retained transitively.)

- [ ] **Step 5: Run the tests and verify they pass**

Run: `swift test --filter DeviceRegistryTests`
Expected: `Test Suite 'DeviceRegistryTests' passed` (5 tests).

- [ ] **Step 6: Run the full test suite to confirm nothing regressed**

Run: `swift test`
Expected: all tests across `MCPServerSmokeTests`, `MacBatteryTests`, `BLEBatteryParsingTests`, `DeviceRegistryTests` pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/IBatteryCore/DeviceRegistry.swift Sources/IBatteryCore/DataSources/MacBattery.swift Sources/IBatteryCore/DataSources/BLEBattery.swift Tests/IBatteryCoreTests/DeviceRegistryTests.swift
git commit -m "Add DeviceRegistry to aggregate battery data sources"
```

---

### Task 5: Wire the three MCP tools

**Files:**
- Create: `Sources/IBatteryCore/JSONFormatting.swift`
- Modify: `Sources/IBatteryCore/MCPServerFactory.swift` (full rewrite of tool registration)
- Modify: `Sources/ibattery-mcp/main.swift` (construct and pass in a `DeviceRegistry`)
- Modify: `Tests/IBatteryCoreTests/MCPServerSmokeTests.swift` (update assertion — the tool list is no longer empty)

**Interfaces:**
- Consumes: `DeviceRegistry`, `DeviceBatteryInfo`, `MacBatterySource`, `BLEBatterySource` (Tasks 2-4).
- Produces: `public func makeServer(registry: DeviceRegistry) async -> Server` (replaces Task 1's argument-less signature).

- [ ] **Step 1: Write the JSON formatting helper**

```swift
// Sources/IBatteryCore/JSONFormatting.swift
import Foundation

let deviceJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

func encodeDevicesAsText(_ devices: [DeviceBatteryInfo]) -> String {
    guard let data = try? deviceJSONEncoder.encode(devices),
          let json = String(data: data, encoding: .utf8)
    else {
        return "[]"
    }
    return json
}
```

- [ ] **Step 2: Update the blackbox test's expectations first (TDD: red)**

Replace the body of `testServerRespondsToToolsList` in `Tests/IBatteryCoreTests/MCPServerSmokeTests.swift` so the final assertion checks for the real tool names instead of an empty list:

```swift
        let outputData = outPipe.fileHandleForReading.availableData
        let response = String(data: outputData, encoding: .utf8) ?? ""
        XCTAssertTrue(response.contains("get_all_devices_status"), "Expected get_all_devices_status in tools/list, got: \(response)")
        XCTAssertTrue(response.contains("get_device_battery"), "Expected get_device_battery in tools/list, got: \(response)")
        XCTAssertTrue(response.contains("list_known_devices"), "Expected list_known_devices in tools/list, got: \(response)")
```

- [ ] **Step 3: Run it and verify it fails**

Run: `swift test --filter MCPServerSmokeTests`
Expected: FAIL — current `tools/list` response is still `"tools":[]`, doesn't contain the new tool names.

- [ ] **Step 4: Rewrite the server factory to register the three tools**

```swift
// Sources/IBatteryCore/MCPServerFactory.swift
import MCP

public func makeServer(registry: DeviceRegistry) async -> Server {
    let server = Server(
        name: "ibattery-mcp",
        version: "0.1.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(
                name: "get_all_devices_status",
                description: "Get battery and charging status for all Apple devices discoverable from this Mac (this Mac's own battery, plus any nearby Bluetooth devices exposing standard battery reporting).",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([:])
                ])
            ),
            Tool(
                name: "get_device_battery",
                description: "Get battery status for one device matching a name or type query, e.g. 'MacBook' or 'Keyboard'.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "query": .object([
                            "type": "string",
                            "description": "Device name or type substring to search for"
                        ])
                    ]),
                    "required": .array(["query"])
                ])
            ),
            Tool(
                name: "list_known_devices",
                description: "List devices seen during this session without triggering a new scan.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([:])
                ])
            )
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {
        case "get_all_devices_status":
            let devices = await registry.getAllDevicesStatus()
            return .init(content: [.text(text: encodeDevicesAsText(devices), annotations: nil, _meta: nil)], isError: false)

        case "get_device_battery":
            guard let query = params.arguments?["query"]?.stringValue else {
                return .init(content: [.text(text: "Missing required argument: query", annotations: nil, _meta: nil)], isError: true)
            }
            guard let device = await registry.getDeviceBattery(query: query) else {
                return .init(content: [.text(text: "No device found matching '\(query)'", annotations: nil, _meta: nil)], isError: true)
            }
            return .init(content: [.text(text: encodeDevicesAsText([device]), annotations: nil, _meta: nil)], isError: false)

        case "list_known_devices":
            let devices = await registry.listKnownDevices()
            return .init(content: [.text(text: encodeDevicesAsText(devices), annotations: nil, _meta: nil)], isError: false)

        default:
            return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    return server
}
```

- [ ] **Step 5: Update the executable entry point**

```swift
// Sources/ibattery-mcp/main.swift
import IBatteryCore
import MCP

let registry = DeviceRegistry(sources: [MacBatterySource(), BLEBatterySource()])
let server = await makeServer(registry: registry)
let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
```

- [ ] **Step 6: Build and run the blackbox test again, verify it passes**

Run: `swift test --filter MCPServerSmokeTests`
Expected: PASS.

- [ ] **Step 7: Run the entire test suite**

Run: `swift test`
Expected: all tests pass (10 tests total across all 4 test files).

- [ ] **Step 8: Manual end-to-end smoke test**

```bash
BIN=$(swift build --show-bin-path)/ibattery-mcp
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe-client","version":"0.1"}}}'
  sleep 0.3
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  sleep 0.3
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_all_devices_status","arguments":{}}}'
  sleep 5
} | "$BIN" &
PID=$!
sleep 6
kill $PID 2>/dev/null
wait $PID 2>/dev/null
```
Expected: a `tools/call` result whose `content[0].text` is a JSON array — on a real MacBook this should include at least this Mac's own battery entry with a plausible percentage. (The extra `sleep 5`/`sleep 6` gives the BLE scan window time to complete before the process is killed — reference Task 3's 4-second default `scanDuration`.)

- [ ] **Step 9: Commit**

```bash
git add Sources/IBatteryCore/JSONFormatting.swift Sources/IBatteryCore/MCPServerFactory.swift Sources/ibattery-mcp/main.swift Tests/IBatteryCoreTests/MCPServerSmokeTests.swift
git commit -m "Wire get_all_devices_status, get_device_battery, and list_known_devices MCP tools"
```

---

### Task 6: Bluetooth permission warning + stale-data marking

**Files:**
- Create: `Tests/IBatteryCoreTests/StalenessTests.swift`
- Modify: `Sources/IBatteryCore/DeviceRegistry.swift` (add stale recomputation on read)
- Modify: `Sources/IBatteryCore/DataSources/BLEBattery.swift` (add a pure, testable authorization-warning function)
- Modify: `Sources/IBatteryCore/MCPServerFactory.swift` (surface the warning as an extra content block on `get_all_devices_status`)

**Interfaces:**
- Consumes: `DeviceRegistry`, `DeviceBatteryInfo` (Tasks 2-4).
- Produces: `public func markStaleIfNeeded(_ device: DeviceBatteryInfo, now: Date, threshold: TimeInterval = 120) -> DeviceBatteryInfo`, `public func bluetoothAuthorizationWarning(for authorization: CBManagerAuthorization) -> String?`.

- [ ] **Step 1: Write the failing staleness test**

```swift
// Tests/IBatteryCoreTests/StalenessTests.swift
import XCTest
@testable import IBatteryCore

private struct FakeBatterySource: BatteryDataSource {
    let devices: [DeviceBatteryInfo]
    func fetchAll() async -> [DeviceBatteryInfo] { devices }
}

final class StalenessTests: XCTestCase {
    func testMarkStaleIfNeeded_marksOldDeviceAsStale() {
        let oldDevice = DeviceBatteryInfo(
            id: "a", name: "Old Device", kind: .bleGeneric,
            percentage: 50, isCharging: nil,
            lastUpdated: Date().addingTimeInterval(-200)
        )
        let result = markStaleIfNeeded(oldDevice, now: Date(), threshold: 120)
        XCTAssertTrue(result.stale)
    }

    func testMarkStaleIfNeeded_leavesFreshDeviceAlone() {
        let freshDevice = DeviceBatteryInfo(
            id: "a", name: "Fresh Device", kind: .mac,
            percentage: 90, isCharging: true,
            lastUpdated: Date()
        )
        let result = markStaleIfNeeded(freshDevice, now: Date(), threshold: 120)
        XCTAssertFalse(result.stale)
    }

    func testListKnownDevices_marksOldCachedEntriesAsStale() async {
        let source = FakeBatterySource(devices: [
            DeviceBatteryInfo(
                id: "a", name: "Mac", kind: .mac, percentage: 90,
                isCharging: true, lastUpdated: Date().addingTimeInterval(-200)
            )
        ])
        let registry = DeviceRegistry(sources: [source])
        _ = await registry.getAllDevicesStatus()
        let known = await registry.listKnownDevices()
        XCTAssertEqual(known.first?.stale, true)
    }

    func testBluetoothAuthorizationWarning_deniedReturnsMessage() {
        XCTAssertNotNil(bluetoothAuthorizationWarning(for: .denied))
    }

    func testBluetoothAuthorizationWarning_allowedReturnsNil() {
        XCTAssertNil(bluetoothAuthorizationWarning(for: .allowedAlways))
    }
}
```

- [ ] **Step 2: Run it and verify it fails**

Run: `swift test --filter StalenessTests`
Expected: FAIL to compile — `markStaleIfNeeded` and `bluetoothAuthorizationWarning` not found.

- [ ] **Step 3: Add the stale-marking function and use it in `DeviceRegistry`**

Add to `Sources/IBatteryCore/DeviceRegistry.swift` (above the `DeviceRegistry` actor definition):

```swift
public func markStaleIfNeeded(_ device: DeviceBatteryInfo, now: Date, threshold: TimeInterval = 120) -> DeviceBatteryInfo {
    guard !device.stale, now.timeIntervalSince(device.lastUpdated) > threshold else {
        return device
    }
    return DeviceBatteryInfo(
        id: device.id,
        name: device.name,
        kind: device.kind,
        percentage: device.percentage,
        isCharging: device.isCharging,
        lastUpdated: device.lastUpdated,
        stale: true
    )
}
```

Change the `listKnownDevices()` method body from `Array(cache.values)` to:

```swift
    public func listKnownDevices() async -> [DeviceBatteryInfo] {
        let now = Date()
        return cache.values.map { markStaleIfNeeded($0, now: now) }
    }
```

- [ ] **Step 4: Add the pure Bluetooth authorization warning function**

Add to `Sources/IBatteryCore/DataSources/BLEBattery.swift`:

```swift
public func bluetoothAuthorizationWarning(for authorization: CBManagerAuthorization) -> String? {
    switch authorization {
    case .denied, .restricted:
        return "Bluetooth access is not authorized for ibattery-mcp — nearby BLE devices will not be found. Grant access in System Settings > Privacy & Security > Bluetooth, then try again."
    case .allowedAlways, .notDetermined:
        return nil
    @unknown default:
        return nil
    }
}
```

- [ ] **Step 5: Run the new tests and verify they pass**

Run: `swift test --filter StalenessTests`
Expected: `Test Suite 'StalenessTests' passed` (5 tests).

- [ ] **Step 6: Surface the warning from the `get_all_devices_status` tool**

In `Sources/IBatteryCore/MCPServerFactory.swift`, change the `"get_all_devices_status"` case to:

```swift
        case "get_all_devices_status":
            let devices = await registry.getAllDevicesStatus()
            var content: [Tool.Content] = [.text(text: encodeDevicesAsText(devices), annotations: nil, _meta: nil)]
            if let warning = bluetoothAuthorizationWarning(for: CBManager.authorization) {
                content.append(.text(text: warning, annotations: nil, _meta: nil))
            }
            return .init(content: content, isError: false)
```

Add `import CoreBluetooth` to the top of `MCPServerFactory.swift`.

- [ ] **Step 7: Run the full test suite**

Run: `swift test`
Expected: all tests pass (15 tests total).

- [ ] **Step 8: Manual QA note**

`CBManager.authorization` reflects the real system permission state and can't be exercised for all four cases in an automated test on a single machine (you'd need to actually revoke Bluetooth permission in System Settings to see the `.denied` branch trigger through `get_all_devices_status` end-to-end). The pure `bluetoothAuthorizationWarning(for:)` function is fully unit-tested above; only the live wiring (Step 6) is manual-QA-only, consistent with this plan's overall testing strategy.

- [ ] **Step 9: Commit**

```bash
git add Sources/IBatteryCore/DeviceRegistry.swift Sources/IBatteryCore/DataSources/BLEBattery.swift Sources/IBatteryCore/MCPServerFactory.swift Tests/IBatteryCoreTests/StalenessTests.swift
git commit -m "Add Bluetooth authorization warning and stale-data marking"
```

---

## What This Plan Does Not Cover

Per the design doc, these are handled by later plans and are out of scope here:
- AirPods' proprietary Apple Continuity BLE protocol (needs a research-first task cross-referencing multiple independent reverse-engineering sources before writing a parser — the exact byte layout is genuinely disputed across public sources).
- iPhone/iPad via `libimobiledevice` (Plan 2).
- Apple Watch via paired iPhone (Plan 3, research spike).
- README, LICENSE, CONTRIBUTING, CI/CD, Homebrew tap (Plan 4).
- GitHub Pages landing page (Plan 5).
- LAN multi-Mac companion (Plan 6, future).
