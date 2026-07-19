# ibattery-mcp Plan 1b: BLE Helper App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make BLE-based battery data sources (currently broken) actually work
by moving all `CBCentralManager` usage into a separate, persistent, real
`.app`-bundled helper (`ibattery-ble-helper`) that the stateless MCP process
talks to over a local Unix domain socket.

**Architecture:** `ibattery-ble-helper` is a new executable target, packaged
as a real `.app` bundle with its own `Info.plist` declaring
`NSBluetoothAlwaysUsageDescription`, launched via `open` (not exec'd
directly). It runs a blocking-accept-loop Unix domain socket server on a
background thread, dispatching each scan request onto the main thread/actor
(where `CBCentralManager` must be created for CoreBluetooth to work at all —
see rationale below), reusing the existing `BLEBatteryScanner` unchanged. The
MCP process's `BLEBatterySource` becomes a thin socket client with a timeout,
replacing its previous direct in-process CoreBluetooth usage.

**Tech Stack:** Same Swift package as Plan 1 (`swift-tools-version: 5.9`,
`.macOS(.v13)`); raw POSIX Unix domain sockets (`Darwin`'s `socket`/`bind`/
`listen`/`accept`/`connect`/`read`/`write`) — no new external dependency.

## Global Constraints

- Same repo, same package (`ibattery-mcp`), same targets already in
  `Package.swift` from Plan 1 (`IBatteryCore`, `ibattery-mcp`,
  `IBatteryCoreTests`) — this plan ADDS a new target, it does not remove or
  rename the existing ones.
- `swift-tools-version: 5.9`, platform floor `.macOS(.v13)` (unchanged).
- No code or bundled binaries from AirBattery (AGPLv3) copied anywhere.
- **Empirically verified fact, not a design guess** (confirmed by building
  and running real test programs before writing this plan): a bare
  executable — even one with an `Info.plist` embedded via linker section,
  even ad-hoc code-signed, even packaged as a real `.app` bundle — still
  crashes with `SIGABRT`/TCC ("`NSBluetoothAlwaysUsageDescription`... must
  contain") the instant it touches `CBCentralManager`, UNLESS it is launched
  via `open` (real LaunchServices), not exec'd directly. This is why
  `ibattery-ble-helper` must be launched via `open` in Task 2's manual
  verification step, not by running its binary path directly.
- **Empirically verified fact:** `CBCentralManager` must be created on the
  actual main thread with an active `RunLoop.main.run()` pumping it, even
  though its `queue:` parameter can be `.main` — creating it from a plain
  `Task { }` (cooperative thread pool, not guaranteed to be the main thread)
  was tested and its delegate callback never fired. Wrapping the call in
  `Task { @MainActor in ... }` (which does run on the main actor/thread) was
  tested and works correctly. Do not "simplify" this away — it is required,
  not a stylistic choice.
- `BLEBatteryScanner`, `parseBatteryLevelCharacteristic`,
  `batteryServiceUUID`, `batteryLevelCharacteristicUUID` (all in
  `Sources/IBatteryCore/DataSources/BLEBattery.swift`, from Plan 1 Task 3)
  are reused **unchanged** by the new helper target — do not duplicate or
  rewrite this class. Only `BLEBatterySource` in that same file changes (Task
  3 of this plan).
- This plan does not touch Apple Watch, iPhone/iPad, or LAN multi-Mac scope —
  those remain out of scope per the main design doc.

---

### Task 1: BLE Helper IPC protocol + helper app executable target

**Files:**
- Create: `Sources/IBatteryCore/BLEHelperIPC.swift`
- Modify: `Sources/IBatteryCore/JSONFormatting.swift` (make the encoder
  public, add a matching public decoder)
- Create: `Sources/ibattery-ble-helper/main.swift`
- Modify: `Package.swift` (add the new executable target)

**Interfaces:**
- Produces: `public let bleHelperSocketPath: String`, `public func
  makeUnixSocketAddress(path: String) -> sockaddr_un`, `public let
  deviceJSONEncoder: JSONEncoder` (changed from internal to public), `public
  let deviceJSONDecoder: JSONDecoder` (new).

- [ ] **Step 1: Add the shared socket path and address-construction helper**

```swift
// Sources/IBatteryCore/BLEHelperIPC.swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public let bleHelperSocketDirectory: String = {
    ("~/Library/Application Support/ibattery-mcp" as NSString).expandingTildeInPath
}()

public let bleHelperSocketPath: String = {
    bleHelperSocketDirectory + "/ble-helper.sock"
}()

public func makeUnixSocketAddress(path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ptr.pointee)) { charPtr in
            for (i, byte) in pathBytes.enumerated() {
                charPtr[i] = CChar(bitPattern: byte)
            }
            charPtr[pathBytes.count] = 0
        }
    }
    return addr
}
```

- [ ] **Step 2: Make the JSON encoder public and add a matching decoder**

In `Sources/IBatteryCore/JSONFormatting.swift`, change:
```swift
let deviceJSONEncoder: JSONEncoder = {
```
to:
```swift
public let deviceJSONEncoder: JSONEncoder = {
```

Add immediately after the existing `encodeDevicesAsText` function:
```swift
public let deviceJSONDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()
```

- [ ] **Step 3: Verify the existing package still builds after the visibility change**

Run: `swift build`
Expected: `Build complete!` with no errors (making a `let` public is
source-compatible with all existing internal call sites).

- [ ] **Step 4: Add the helper app executable target to Package.swift**

Add a new entry to the `targets:` array in `Package.swift`, alongside the
existing `IBatteryCore`/`ibattery-mcp`/`IBatteryCoreTests` targets (do not
remove or reorder the existing ones):
```swift
        .executableTarget(
            name: "ibattery-ble-helper",
            dependencies: ["IBatteryCore"]
        ),
```

- [ ] **Step 5: Write the helper's main.swift**

```swift
// Sources/ibattery-ble-helper/main.swift
import Foundation
import IBatteryCore
#if canImport(Darwin)
import Darwin
#endif

setvbuf(stdout, nil, _IONBF, 0)

try? FileManager.default.createDirectory(
    atPath: bleHelperSocketDirectory,
    withIntermediateDirectories: true
)
unlink(bleHelperSocketPath)

let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard serverFD >= 0 else {
    fatalError("socket() failed: \(errno)")
}

var serverAddr = makeUnixSocketAddress(path: bleHelperSocketPath)
let bindResult = withUnsafePointer(to: &serverAddr) { ptr -> Int32 in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bindResult == 0 else {
    fatalError("bind() failed: \(errno)")
}
guard listen(serverFD, 4) == 0 else {
    fatalError("listen() failed: \(errno)")
}

print("ibattery-ble-helper listening on \(bleHelperSocketPath)")

DispatchQueue.global(qos: .userInitiated).async {
    while true {
        let clientFD = accept(serverFD, nil, nil)
        guard clientFD >= 0 else { continue }

        var buffer = [UInt8](repeating: 0, count: 256)
        let bytesRead = read(clientFD, &buffer, buffer.count)
        guard bytesRead > 0 else {
            close(clientFD)
            continue
        }

        // CBCentralManager must be created on the main thread/actor with
        // RunLoop.main actively running — see this plan's Global Constraints.
        Task { @MainActor in
            let devices = await BLEBatteryScanner().scan(duration: 4.0)
            var responseData = (try? deviceJSONEncoder.encode(devices)) ?? Data("[]".utf8)
            responseData.append(0x0A)
            responseData.withUnsafeBytes { rawBuffer in
                _ = write(clientFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            close(clientFD)
        }
    }
}

RunLoop.main.run()
```

- [ ] **Step 6: Build and verify it compiles**

Run: `swift build --product ibattery-ble-helper`
Expected: `Build complete!` with no errors.

- [ ] **Step 7: Commit**

```bash
git add Sources/IBatteryCore/BLEHelperIPC.swift Sources/IBatteryCore/JSONFormatting.swift Sources/ibattery-ble-helper/main.swift Package.swift
git commit -m "Add ibattery-ble-helper: Unix-socket BLE scan server"
```

---

### Task 2: Package the helper as a `.app` bundle and verify it end-to-end

**Files:**
- Create: `Resources/ibattery-ble-helper/Info.plist`
- Create: `Scripts/build-ble-helper-app.sh`

**Interfaces:**
- Consumes: the `ibattery-ble-helper` binary built by Task 1.
- Produces: a runnable `.app` bundle at
  `.build/ibattery-ble-helper.app` (built by the script, not committed to
  git — add `.build/` is already covered by the existing `.gitignore` from
  Plan 1 Task 1).

- [ ] **Step 1: Write the helper's Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ibattery-ble-helper</string>
    <key>CFBundleIdentifier</key>
    <string>com.ibattery-mcp.ble-helper</string>
    <key>CFBundleName</key>
    <string>ibattery-ble-helper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>ibattery-ble-helper scans nearby Bluetooth devices to read their battery level for the ibattery-mcp MCP server.</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

Save as `Resources/ibattery-ble-helper/Info.plist`.

- [ ] **Step 2: Write the packaging script**

```bash
#!/usr/bin/env bash
# Assembles ibattery-ble-helper.app from the SwiftPM-built binary + Info.plist.
# Usage: Scripts/build-ble-helper-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

swift build --product ibattery-ble-helper

BIN_PATH="$(swift build --show-bin-path)/ibattery-ble-helper"
APP_DIR=".build/ibattery-ble-helper.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/ibattery-ble-helper"
cp "Resources/ibattery-ble-helper/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign -s - --force --deep "$APP_DIR"

echo "Built $APP_DIR"
```

Save as `Scripts/build-ble-helper-app.sh` and make it executable:
```bash
chmod +x Scripts/build-ble-helper-app.sh
```

- [ ] **Step 3: Run the packaging script**

Run: `./Scripts/build-ble-helper-app.sh`
Expected: ends with `Built .build/ibattery-ble-helper.app`, no errors from
`codesign`.

- [ ] **Step 4: Manually verify the helper runs and answers a scan request**

```bash
open .build/ibattery-ble-helper.app
sleep 2
python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(6)
s.connect('$HOME/Library/Application Support/ibattery-mcp/ble-helper.sock')
s.send(b'scan\n')
print('response:', s.recv(4096))
"
pkill -f ibattery-ble-helper.app
```
Expected: `response: b'[]\n'` (or a JSON array containing any real BLE Battery
Service peripherals actually nearby) — the key thing to confirm is **no
crash, no timeout, a valid JSON array comes back**. If you have a real BLE
device exposing the standard Battery Service nearby, its entry should appear
in the array; an empty array is still a successful result if none are
nearby.

- [ ] **Step 5: Commit**

```bash
git add Resources/ibattery-ble-helper/Info.plist Scripts/build-ble-helper-app.sh
git commit -m "Package ibattery-ble-helper as a launchable .app bundle"
```

---

### Task 3: Rewrite `BLEBatterySource` as a socket IPC client

**Files:**
- Modify: `Sources/IBatteryCore/DataSources/BLEBattery.swift`
- Create: `Tests/IBatteryCoreTests/BLEBatterySourceIPCTests.swift`

**Interfaces:**
- Consumes: `bleHelperSocketPath`, `makeUnixSocketAddress(path:)` (Task 1),
  `deviceJSONDecoder` (Task 1), `DeviceBatteryInfo` (Plan 1 Task 2).
- Produces: `public func parseHelperResponse(_ data: Data) -> [DeviceBatteryInfo]`
  (pure, unit-testable), modified `BLEBatterySource.fetchAll()` (now a socket
  client instead of a direct `BLEBatteryScanner` caller). `BLEBatteryScanner`,
  `parseBatteryLevelCharacteristic`, `batteryServiceUUID`,
  `batteryLevelCharacteristicUUID` in this same file are **not** modified —
  they stay exactly as Plan 1 Task 3 left them, for use by the helper app.

- [ ] **Step 1: Write the failing test for the pure response-parsing function**

```swift
// Tests/IBatteryCoreTests/BLEBatterySourceIPCTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class BLEBatterySourceIPCTests: XCTestCase {
    func testParseHelperResponse_decodesValidJSONArray() {
        let json = """
        [{"id":"abc","name":"Test Mouse","kind":"bleGeneric","percentage":72,"isCharging":null,"lastUpdated":"2026-07-19T08:00:00Z","stale":false}]
        """
        let data = Data(json.utf8)
        let devices = parseHelperResponse(data)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, "abc")
        XCTAssertEqual(devices.first?.percentage, 72)
    }

    func testParseHelperResponse_emptyArray_returnsEmpty() {
        let data = Data("[]".utf8)
        XCTAssertEqual(parseHelperResponse(data), [])
    }

    func testParseHelperResponse_malformedData_returnsEmpty() {
        let data = Data("not json".utf8)
        XCTAssertEqual(parseHelperResponse(data), [])
    }
}
```

- [ ] **Step 2: Run it and verify it fails**

Run: `swift test --filter BLEBatterySourceIPCTests`
Expected: FAIL to compile — `parseHelperResponse` not found.

- [ ] **Step 3: Add the pure parsing function and rewrite `BLEBatterySource`**

In `Sources/IBatteryCore/DataSources/BLEBattery.swift`, add this function
(anywhere in the file, e.g. just above the `BLEBatterySource` struct):

```swift
public func parseHelperResponse(_ data: Data) -> [DeviceBatteryInfo] {
    (try? deviceJSONDecoder.decode([DeviceBatteryInfo].self, from: data)) ?? []
}
```

Replace the existing `BLEBatterySource` struct entirely with:

```swift
public struct BLEBatterySource: BatteryDataSource {
    let connectTimeoutSeconds: Int
    let readTimeoutSeconds: Int

    public init(connectTimeoutSeconds: Int = 2, readTimeoutSeconds: Int = 6) {
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.readTimeoutSeconds = readTimeoutSeconds
    }

    public func fetchAll() async -> [DeviceBatteryInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.fetchAllBlocking())
            }
        }
    }

    private func fetchAllBlocking() -> [DeviceBatteryInfo] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var readTimeout = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = makeUnixSocketAddress(path: bleHelperSocketPath)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            // Helper not installed/running — not an error, just no BLE data this call.
            return []
        }

        let request = "scan\n"
        request.withCString { cString in
            _ = write(fd, cString, strlen(cString))
        }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            guard bytesRead > 0 else { break }
            responseData.append(contentsOf: buffer[0..<bytesRead])
        }

        return parseHelperResponse(responseData)
    }
}
```

Add `#if canImport(Darwin)\nimport Darwin\n#endif` near the top of the file
if it isn't already imported (check first — `BLEBatteryScanner` in this same
file uses `CoreBluetooth`, which is Darwin-only already, but the raw POSIX
socket calls above need `Darwin` explicitly imported).

- [ ] **Step 4: Run the new tests and verify they pass**

Run: `swift test --filter BLEBatterySourceIPCTests`
Expected: `Test Suite 'BLEBatterySourceIPCTests' passed` (3 tests).

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all tests pass. `BLEBatteryParsingTests` (testing
`parseBatteryLevelCharacteristic`, unaffected by this change) must still
pass unchanged.

- [ ] **Step 6: Manual end-to-end verification with both processes running**

```bash
./Scripts/build-ble-helper-app.sh
open .build/ibattery-ble-helper.app
sleep 2
BIN=$(swift build --show-bin-path)/ibattery-mcp
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe-client","version":"0.1"}}}'
  sleep 0.3
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  sleep 0.3
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_all_devices_status","arguments":{}}}'
  sleep 8
} | "$BIN" &
PID=$!
sleep 10
kill $PID 2>/dev/null
wait $PID 2>/dev/null
pkill -f ibattery-ble-helper.app
```
Expected: the bare `ibattery-mcp` binary (exec'd directly, exactly as an MCP
host would spawn it) does **not** crash, and the `tools/call` response
contains a valid JSON array — this is the whole point of this plan: the
direct-exec'd MCP process itself never touches `CBCentralManager` anymore,
so it cannot hit the TCC crash regardless of how it's launched.

- [ ] **Step 7: Commit**

```bash
git add Sources/IBatteryCore/DataSources/BLEBattery.swift Tests/IBatteryCoreTests/BLEBatterySourceIPCTests.swift
git commit -m "Rewrite BLEBatterySource as a Unix-socket client of ibattery-ble-helper"
```

---

### Task 4: Stale-data marking + helper-reachability warning

**Files:**
- Create: `Tests/IBatteryCoreTests/StalenessTests.swift`
- Modify: `Sources/IBatteryCore/DeviceRegistry.swift` (add stale recomputation
  on read)
- Modify: `Sources/IBatteryCore/DataSources/BLEBattery.swift` (add a pure,
  testable helper-reachability check)
- Modify: `Sources/IBatteryCore/MCPServerFactory.swift` (surface the warning
  as an extra content block on `get_all_devices_status`)

This task supersedes Plan 1's original Task 6, which assumed
`CBManager.authorization` would be checked from inside the MCP process — that
assumption no longer applies now that the MCP process never touches
CoreBluetooth (Task 3 of this plan). The stale-data-marking half is
unchanged from the original Task 6 design.

**Interfaces:**
- Produces: `public func markStaleIfNeeded(_ device: DeviceBatteryInfo, now:
  Date, threshold: TimeInterval = 120) -> DeviceBatteryInfo`, `public func
  bleHelperUnreachableWarning(canConnect: Bool) -> String?`.

- [ ] **Step 1: Write the failing tests**

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

    func testBleHelperUnreachableWarning_falseReturnsMessage() {
        XCTAssertNotNil(bleHelperUnreachableWarning(canConnect: false))
    }

    func testBleHelperUnreachableWarning_trueReturnsNil() {
        XCTAssertNil(bleHelperUnreachableWarning(canConnect: true))
    }
}
```

- [ ] **Step 2: Run it and verify it fails**

Run: `swift test --filter StalenessTests`
Expected: FAIL to compile — `markStaleIfNeeded` and
`bleHelperUnreachableWarning` not found.

- [ ] **Step 3: Add the stale-marking function and use it in `DeviceRegistry`**

Add to `Sources/IBatteryCore/DeviceRegistry.swift` (above the
`DeviceRegistry` actor definition):

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

- [ ] **Step 4: Add the pure helper-reachability warning function**

Add to `Sources/IBatteryCore/DataSources/BLEBattery.swift`:

```swift
public func bleHelperUnreachableWarning(canConnect: Bool) -> String? {
    guard !canConnect else { return nil }
    return "ibattery-ble-helper isn't running, so nearby Bluetooth devices (other than this Mac's own battery) weren't checked. Launch it once (double-click the .app, or `open` it) — it stays running in the background afterward."
}
```

- [ ] **Step 5: Run the new tests and verify they pass**

Run: `swift test --filter StalenessTests`
Expected: `Test Suite 'StalenessTests' passed` (5 tests).

- [ ] **Step 6: Surface the warning from the `get_all_devices_status` tool**

In `Sources/IBatteryCore/MCPServerFactory.swift`, change the
`"get_all_devices_status"` case to:

```swift
        case "get_all_devices_status":
            let devices = await registry.getAllDevicesStatus()
            var content: [Tool.Content] = [.text(text: encodeDevicesAsText(devices), annotations: nil, _meta: nil)]
            let canConnectToHelper = BLEBatterySource.canReachHelper()
            if let warning = bleHelperUnreachableWarning(canConnect: canConnectToHelper) {
                content.append(.text(text: warning, annotations: nil, _meta: nil))
            }
            return .init(content: content, isError: false)
```

Add this small connectivity-check method to `BLEBatterySource` in
`Sources/IBatteryCore/DataSources/BLEBattery.swift` (inside the struct,
alongside `fetchAll`/`fetchAllBlocking`):

```swift
    public static func canReachHelper() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = makeUnixSocketAddress(path: bleHelperSocketPath)
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
```

- [ ] **Step 7: Run the full test suite**

Run: `swift test`
Expected: all tests pass (18 tests total: Plan 1's 10 — 1
MCPServerSmokeTests + 2 MacBatteryTests + 2 BLEBatteryParsingTests + 5
DeviceRegistryTests, with Plan 1's own Task 6 never implemented since this
plan's Task 4 supersedes it — plus this plan's 3 BLEBatterySourceIPCTests
(Task 3) + 5 StalenessTests (this task) = 18).

- [ ] **Step 8: Manual QA note**

The warning path (helper genuinely not running) is straightforward to check
manually: run the Step 6-of-Task-3 style manual test but skip the `open
.build/ibattery-ble-helper.app` step, and confirm `get_all_devices_status`'s
response now includes the "isn't running" warning text as a second content
block instead of silently omitting BLE results.

- [ ] **Step 9: Commit**

```bash
git add Sources/IBatteryCore/DeviceRegistry.swift Sources/IBatteryCore/DataSources/BLEBattery.swift Sources/IBatteryCore/MCPServerFactory.swift Tests/IBatteryCoreTests/StalenessTests.swift
git commit -m "Add stale-data marking and ibattery-ble-helper reachability warning"
```

---

## What This Plan Does Not Cover

- Login-item auto-registration for `ibattery-ble-helper` (`SMAppService`) —
  the helper must be launched manually (`open .build/ibattery-ble-helper.app`)
  for now; auto-registration and a proper first-run UX are follow-up work,
  likely alongside Plan 4's distribution work once there's a stable app
  bundle location to register (Homebrew-installed, not `.build/`).
  Renaming/upgrading the Homebrew-formula-friendly filename and version
  matching between the two targets also becomes real work at that point.
- Full production code signing/notarization for the helper `.app` — ad-hoc
  signing (`codesign -s -`) is sufficient for it to run at all, matching
  this plan's finding; a properly notarized build is Plan 4 scope, same as
  the main `ibattery-mcp` binary.
- The LAN multi-Mac half of this same helper (peer discovery, cross-Mac
  queries) — still deferred to its own future plan per the main design doc.
