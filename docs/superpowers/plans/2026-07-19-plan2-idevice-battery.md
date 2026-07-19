# ibattery-mcp Plan 2: iPhone/iPad Battery via libimobiledevice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add iPhone/iPad battery reporting to `ibattery-mcp` by shelling out to the `libimobiledevice` CLI tools (`idevice_id`, `ideviceinfo`), declared as an external Homebrew dependency rather than bundled — matching the design doc's §3 approach and licensing rationale (libimobiledevice is LGPL, an independent upstream project, unrelated to AirBattery's own AGPL code).

**Architecture:** A new `IDeviceBatterySource` conforming to the existing `BatteryDataSource` protocol (no changes needed to `DeviceRegistry` — this is exactly the abstraction boundary it was built for). It shells out to `idevice_id -l` to enumerate connected device UDIDs, then `ideviceinfo` per UDID (once for the default identity domain, once for the `com.apple.mobile.battery` domain) via `Process`, parsing the XML property-list output with Foundation's `PropertyListSerialization` — **not** the tool's default plain-text output, which libimobiledevice's own source code explicitly documents as "*output-only* format... NOT for machine parsing." Tool location is resolved via `/usr/bin/env` (portable across Intel/Apple Silicon Homebrew prefixes and other install methods), not a hardcoded path. Same as the BLE helper's status check, a separate `IDeviceBatterySource.checkStatus()` reports whether the tools are installed and whether any connected-but-unreadable devices were seen, so `MCPServerFactory` can surface an actionable warning — wired into **both** `get_all_devices_status` and `get_device_battery`'s not-found branch (the original BLE-only version of this pattern was flagged in the Plan 1b final review for missing the second tool; don't repeat that gap here).

**Tech Stack:** Same package (`ibattery-mcp`), `swift-tools-version: 5.9`, `.macOS(.v13)`. No new SwiftPM dependency — `Process` (Foundation) to shell out, `PropertyListSerialization` (Foundation) to parse XML plist output. External runtime dependency: the `libimobiledevice` Homebrew formula (providing `idevice_id`/`ideviceinfo` on `$PATH`), not bundled.

## Global Constraints

- Same repo, same package (`ibattery-mcp`), same targets (`IBatteryCore`, `ibattery-mcp`, `ibattery-ble-helper`, `IBatteryCoreTests`) from Plan 1/1b — this plan adds files, it does not restructure targets.
- `swift-tools-version: 5.9`, platform floor `.macOS(.v13)` (unchanged).
- No code or bundled binaries from AirBattery (AGPLv3) copied anywhere. No `libimobiledevice` binaries are bundled with this project — it is invoked as an external tool the user installs themselves (documented in a later distribution plan as a Homebrew formula `depends_on`).
- **Empirically verified fact, not a guess** (confirmed on this machine by installing `libimobiledevice` via Homebrew and running the real tools before writing this plan):
  - `idevice_id -l` lists USB-attached device UDIDs, one per line, and exits `0` even when zero devices are attached (empty stdout, not an error).
  - `ideviceinfo` with no device reachable exits `255` and prints `ERROR: No device found!` to stderr.
  - `ideviceinfo`'s **default** (no `-x`) output format is libplist's `PLIST_FORMAT_LIMD`, whose own source (`libplist/src/out-limd.c`) is headed `"libplist *output-only* format introduced by libimobiledevice/ideviceinfo - NOT for machine parsing"`. **Always pass `-x` (XML plist) and parse with `PropertyListSerialization` — never parse the default text output.**
  - Foundation's `PropertyListSerialization.propertyList(from:options:format:)` correctly parses a `com.apple.mobile.battery`-shaped XML dict on this project's toolchain, bridging `<integer>`/`<true/>` to `NSNumber`, castable via `as? Int` / `as? Bool` — verified with a synthetic plist (`BatteryCurrentCapacity`/`BatteryIsCharging`) since no physical iPhone/iPad was available to generate a real one.
  - Invoking tools via `Process` with `executableURL = URL(fileURLWithPath: "/usr/bin/env")` and `arguments = [command] + args` correctly resolves `$PATH` (works whether Homebrew installed to `/opt/homebrew` or `/usr/local`) and returns exit code `127` when the command isn't found on `$PATH` — verified directly (both the real installed tool and a deliberately-nonexistent command name).
- This plan's scope is iPhone/iPad battery only. Apple Watch (via a paired iPhone) is explicitly out of scope — it's Plan 3, flagged in the design doc as its own research spike.
- Testing philosophy (unchanged from Plan 1/1b): pure parsing/logic functions are unit tested with synthetic fixtures; the actual `Process` invocation of `idevice_id`/`ideviceinfo` requires a real attached iOS device and is manual-QA-only, documented as such.

---

### Task 1: iOS device data source (parsing + CLI invocation + `BatteryDataSource` conformance)

**Files:**
- Modify: `Sources/IBatteryCore/DeviceBatteryInfo.swift` (add `.iosDevice` to `Kind`)
- Create: `Sources/IBatteryCore/DataSources/IDeviceBattery.swift`
- Create: `Tests/IBatteryCoreTests/IDeviceBatteryTests.swift`

**Interfaces:**
- Consumes: `DeviceBatteryInfo`, `BatteryDataSource` (Plan 1 Tasks 2 and 4).
- Produces: `public func parseDeviceIdList(_ output: String) -> [String]`, `public func parseBatteryPlist(_ data: Data) -> (percentage: Int, isCharging: Bool)?`, `public func parseDeviceNamePlist(_ data: Data) -> String?`, `public struct IDeviceStatus: Sendable, Equatable { public let toolsInstalled: Bool; public let connectedButUnreadableCount: Int }`, `public struct IDeviceBatterySource: BatteryDataSource` with `static func checkStatus() -> IDeviceStatus` (consumed by Task 2).

- [ ] **Step 1: Add the new device kind**

In `Sources/IBatteryCore/DeviceBatteryInfo.swift`, change:
```swift
    public enum Kind: String, Codable, Sendable {
        case mac
        case bleGeneric
    }
```
to:
```swift
    public enum Kind: String, Codable, Sendable {
        case mac
        case bleGeneric
        case iosDevice
    }
```

- [ ] **Step 2: Write the failing tests for the pure parsing functions**

```swift
// Tests/IBatteryCoreTests/IDeviceBatteryTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class IDeviceBatteryTests: XCTestCase {
    func testParseDeviceIdList_multipleUdids() {
        let output = "00008030-000C1234ABCD002E\n00008110-001A2345BCDE003F\n"
        XCTAssertEqual(parseDeviceIdList(output), [
            "00008030-000C1234ABCD002E",
            "00008110-001A2345BCDE003F"
        ])
    }

    func testParseDeviceIdList_emptyOutput_returnsEmpty() {
        XCTAssertEqual(parseDeviceIdList(""), [])
    }

    func testParseDeviceIdList_trailingBlankLinesIgnored() {
        XCTAssertEqual(parseDeviceIdList("00008030-000C1234ABCD002E\n\n\n"), ["00008030-000C1234ABCD002E"])
    }

    func testParseBatteryPlist_validPlist_returnsCapacityAndCharging() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>BatteryCurrentCapacity</key>
            <integer>87</integer>
            <key>BatteryIsCharging</key>
            <true/>
        </dict>
        </plist>
        """
        let result = parseBatteryPlist(Data(xml.utf8))
        XCTAssertEqual(result?.percentage, 87)
        XCTAssertEqual(result?.isCharging, true)
    }

    func testParseBatteryPlist_missingCapacityKey_returnsNil() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>BatteryIsCharging</key>
            <false/>
        </dict>
        </plist>
        """
        XCTAssertNil(parseBatteryPlist(Data(xml.utf8)))
    }

    func testParseBatteryPlist_malformedData_returnsNil() {
        XCTAssertNil(parseBatteryPlist(Data("not a plist".utf8)))
    }

    func testParseBatteryPlist_missingChargingKey_defaultsToFalse() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>BatteryCurrentCapacity</key>
            <integer>50</integer>
        </dict>
        </plist>
        """
        let result = parseBatteryPlist(Data(xml.utf8))
        XCTAssertEqual(result?.percentage, 50)
        XCTAssertEqual(result?.isCharging, false)
    }

    func testParseDeviceNamePlist_validPlist_returnsName() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>DeviceName</key>
            <string>Drummond's iPhone</string>
            <key>DeviceClass</key>
            <string>iPhone</string>
        </dict>
        </plist>
        """
        XCTAssertEqual(parseDeviceNamePlist(Data(xml.utf8)), "Drummond's iPhone")
    }

    func testParseDeviceNamePlist_missingKey_returnsNil() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>DeviceClass</key>
            <string>iPhone</string>
        </dict>
        </plist>
        """
        XCTAssertNil(parseDeviceNamePlist(Data(xml.utf8)))
    }
}
```

- [ ] **Step 3: Run the tests and verify they fail**

Run: `swift test --filter IDeviceBatteryTests`
Expected: FAIL to compile — `parseDeviceIdList`, `parseBatteryPlist`, `parseDeviceNamePlist` not found.

- [ ] **Step 4: Implement the pure parsing functions and the CLI-invocation helper**

```swift
// Sources/IBatteryCore/DataSources/IDeviceBattery.swift
import Foundation

public func parseDeviceIdList(_ output: String) -> [String] {
    output
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

public func parseBatteryPlist(_ data: Data) -> (percentage: Int, isCharging: Bool)? {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = plist as? [String: Any],
          let percentage = dict["BatteryCurrentCapacity"] as? Int
    else {
        return nil
    }
    let isCharging = dict["BatteryIsCharging"] as? Bool ?? false
    return (percentage, isCharging)
}

public func parseDeviceNamePlist(_ data: Data) -> String? {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = plist as? [String: Any],
          let name = dict["DeviceName"] as? String
    else {
        return nil
    }
    return name
}

func runLibimobiledeviceTool(_ command: String, _ arguments: [String]) -> (stdout: Data, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + arguments
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return (Data(), -1)
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (outData, process.terminationStatus)
}
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `swift test --filter IDeviceBatteryTests`
Expected: `Test Suite 'IDeviceBatteryTests' passed` (9 tests).

- [ ] **Step 6: Implement `IDeviceStatus` and `IDeviceBatterySource`**

Add to the same file, `Sources/IBatteryCore/DataSources/IDeviceBattery.swift`:

```swift
public struct IDeviceStatus: Sendable, Equatable {
    public let toolsInstalled: Bool
    public let connectedButUnreadableCount: Int
}

public struct IDeviceBatterySource: BatteryDataSource {
    public init() {}

    public func fetchAll() async -> [DeviceBatteryInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.fetchAllBlocking().devices)
            }
        }
    }

    public static func checkStatus() -> IDeviceStatus {
        fetchAllBlocking().status
    }

    private static func fetchAllBlocking() -> (devices: [DeviceBatteryInfo], status: IDeviceStatus) {
        let idResult = runLibimobiledeviceTool("idevice_id", ["-l"])
        guard idResult.exitCode == 0 else {
            return ([], IDeviceStatus(toolsInstalled: false, connectedButUnreadableCount: 0))
        }

        let output = String(data: idResult.stdout, encoding: .utf8) ?? ""
        let udids = parseDeviceIdList(output)

        var devices: [DeviceBatteryInfo] = []
        for udid in udids {
            if let info = fetchDeviceInfo(udid: udid) {
                devices.append(info)
            }
        }

        let unreadableCount = udids.count - devices.count
        return (devices, IDeviceStatus(toolsInstalled: true, connectedButUnreadableCount: unreadableCount))
    }

    private static func fetchDeviceInfo(udid: String) -> DeviceBatteryInfo? {
        let batteryResult = runLibimobiledeviceTool("ideviceinfo", ["-u", udid, "-q", "com.apple.mobile.battery", "-x"])
        guard batteryResult.exitCode == 0,
              let battery = parseBatteryPlist(batteryResult.stdout)
        else {
            return nil
        }

        let identityResult = runLibimobiledeviceTool("ideviceinfo", ["-u", udid, "-x"])
        let name = (identityResult.exitCode == 0 ? parseDeviceNamePlist(identityResult.stdout) : nil) ?? udid

        return DeviceBatteryInfo(
            id: udid,
            name: name,
            kind: .iosDevice,
            percentage: battery.percentage,
            isCharging: battery.isCharging,
            lastUpdated: Date()
        )
    }
}
```

Note: `ideviceinfo -u <udid> -x` with **no** `-q`/`-k` returns the full default (lockdown root) domain as one XML dict, which is why `parseDeviceNamePlist` can look up `dict["DeviceName"]` directly — this was verified against the real `PropertyListSerialization` behavior for a dict-shaped plist. Do not add a `-k DeviceName` flag here: `ideviceinfo` returns a **bare value** (not a dict) when a specific `-k` key is requested, which `parseDeviceNamePlist`'s dict-based lookup would not handle — this was deliberately avoided, not an oversight.

- [ ] **Step 7: Build and run the full test suite**

Run: `swift build && swift test`
Expected: `Build complete!`, then all tests pass (32 tests: the prior 23 from Plan 1/1b plus these 9 new `IDeviceBatteryTests`).

- [ ] **Step 8: Manual QA note**

`runLibimobiledeviceTool`/`IDeviceBatterySource.fetchAll()` cannot be unit-tested (real `idevice_id`/`ideviceinfo` binaries plus a real, USB-or-WiFi-connected, trusted iPhone/iPad are required). Before considering this task validated on real hardware:
1. `brew install libimobiledevice` if not already installed (confirmed on this machine during planning; verify on the target machine too).
2. Connect a real iPhone/iPad via USB or ensure it's paired over WiFi and trusted with this Mac.
3. Manually verify via a throwaway `print(await IDeviceBatterySource().fetchAll())` in `main.swift`, `swift run`, confirm a real `DeviceBatteryInfo` with plausible percentage/name is printed, then revert the throwaway print before committing (same technique as Plan 1 Task 2's manual QA step for `MacBatterySource`).

- [ ] **Step 9: Commit**

```bash
git add Sources/IBatteryCore/DeviceBatteryInfo.swift Sources/IBatteryCore/DataSources/IDeviceBattery.swift Tests/IBatteryCoreTests/IDeviceBatteryTests.swift
git commit -m "Add iPhone/iPad battery source via libimobiledevice CLI tools"
```

---

### Task 2: Wire `IDeviceBatterySource` in and surface its status as a warning in both tools

**Files:**
- Modify: `Sources/ibattery-mcp/main.swift` (add `IDeviceBatterySource()` to the registry's sources)
- Modify: `Sources/IBatteryCore/DataSources/IDeviceBattery.swift` (add the warning-message function)
- Modify: `Sources/IBatteryCore/MCPServerFactory.swift` (surface the warning from both `get_all_devices_status` and `get_device_battery`)
- Create: `Tests/IBatteryCoreTests/IDeviceStatusWarningTests.swift`

**Interfaces:**
- Consumes: `IDeviceStatus`, `IDeviceBatterySource.checkStatus()` (Task 1).
- Produces: `public func iDeviceStatusWarning(status: IDeviceStatus) -> String?`.

- [ ] **Step 1: Write the failing tests for the warning function**

```swift
// Tests/IBatteryCoreTests/IDeviceStatusWarningTests.swift
import XCTest
@testable import IBatteryCore

final class IDeviceStatusWarningTests: XCTestCase {
    func testIDeviceStatusWarning_toolsNotInstalled_returnsInstallMessage() {
        let status = IDeviceStatus(toolsInstalled: false, connectedButUnreadableCount: 0)
        let warning = iDeviceStatusWarning(status: status)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("brew install libimobiledevice") == true)
    }

    func testIDeviceStatusWarning_unreadableDevices_returnsTrustMessage() {
        let status = IDeviceStatus(toolsInstalled: true, connectedButUnreadableCount: 1)
        let warning = iDeviceStatusWarning(status: status)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.lowercased().contains("trust") == true)
    }

    func testIDeviceStatusWarning_allClear_returnsNil() {
        let status = IDeviceStatus(toolsInstalled: true, connectedButUnreadableCount: 0)
        XCTAssertNil(iDeviceStatusWarning(status: status))
    }
}
```

- [ ] **Step 2: Run it and verify it fails**

Run: `swift test --filter IDeviceStatusWarningTests`
Expected: FAIL to compile — `iDeviceStatusWarning` not found.

- [ ] **Step 3: Implement the warning function**

Add to `Sources/IBatteryCore/DataSources/IDeviceBattery.swift`:

```swift
public func iDeviceStatusWarning(status: IDeviceStatus) -> String? {
    guard status.toolsInstalled else {
        return "libimobiledevice isn't installed, so iPhone/iPad battery couldn't be checked. Install it with `brew install libimobiledevice`."
    }
    guard status.connectedButUnreadableCount == 0 else {
        let plural = status.connectedButUnreadableCount == 1 ? "device" : "devices"
        return "\(status.connectedButUnreadableCount) connected iOS \(plural) couldn't be read — make sure to trust this computer on the device (tap \"Trust\" when prompted after connecting)."
    }
    return nil
}
```

- [ ] **Step 4: Run the new tests and verify they pass**

Run: `swift test --filter IDeviceStatusWarningTests`
Expected: `Test Suite 'IDeviceStatusWarningTests' passed` (3 tests).

- [ ] **Step 5: Wire `IDeviceBatterySource` into the registry**

In `Sources/ibattery-mcp/main.swift`, change:
```swift
let registry = DeviceRegistry(sources: [MacBatterySource(), BLEBatterySource()])
```
to:
```swift
let registry = DeviceRegistry(sources: [MacBatterySource(), BLEBatterySource(), IDeviceBatterySource()])
```

- [ ] **Step 6: Surface the warning from both tools in `MCPServerFactory.swift`**

Change the `"get_all_devices_status"` case from:
```swift
        case "get_all_devices_status":
            let devices = await registry.getAllDevicesStatus()
            var content: [Tool.Content] = [.text(text: encodeDevicesAsText(devices), annotations: nil, _meta: nil)]
            let bluetoothStatus = BLEBatterySource.fetchBluetoothStatus()
            if let warning = bleHelperStatusWarning(status: bluetoothStatus) {
                content.append(.text(text: warning, annotations: nil, _meta: nil))
            }
            return .init(content: content, isError: false)
```
to:
```swift
        case "get_all_devices_status":
            let devices = await registry.getAllDevicesStatus()
            var content: [Tool.Content] = [.text(text: encodeDevicesAsText(devices), annotations: nil, _meta: nil)]
            let bluetoothStatus = BLEBatterySource.fetchBluetoothStatus()
            if let warning = bleHelperStatusWarning(status: bluetoothStatus) {
                content.append(.text(text: warning, annotations: nil, _meta: nil))
            }
            let iDeviceStatus = IDeviceBatterySource.checkStatus()
            if let warning = iDeviceStatusWarning(status: iDeviceStatus) {
                content.append(.text(text: warning, annotations: nil, _meta: nil))
            }
            return .init(content: content, isError: false)
```

Change the `"get_device_battery"` case's not-found branch from:
```swift
            guard let device = await registry.getDeviceBattery(query: query) else {
                var message = "No device found matching '\(query)'"
                let bluetoothStatus = BLEBatterySource.fetchBluetoothStatus()
                if let warning = bleHelperStatusWarning(status: bluetoothStatus) {
                    message += "\n\n\(warning)"
                }
                return .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
            }
```
to:
```swift
            guard let device = await registry.getDeviceBattery(query: query) else {
                var message = "No device found matching '\(query)'"
                let bluetoothStatus = BLEBatterySource.fetchBluetoothStatus()
                if let warning = bleHelperStatusWarning(status: bluetoothStatus) {
                    message += "\n\n\(warning)"
                }
                let iDeviceStatus = IDeviceBatterySource.checkStatus()
                if let warning = iDeviceStatusWarning(status: iDeviceStatus) {
                    message += "\n\n\(warning)"
                }
                return .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
            }
```

- [ ] **Step 7: Build and run the full test suite**

Run: `swift build && swift test`
Expected: `Build complete!`, then all tests pass (35 tests: 32 from Task 1 plus these 3 new `IDeviceStatusWarningTests`).

- [ ] **Step 8: Manual QA note**

With `libimobiledevice` not installed (or renamed/hidden from `$PATH` temporarily), confirm `get_all_devices_status`'s response includes the "isn't installed" warning as an extra content block, and `get_device_battery`'s not-found response includes it appended to the message. With the tools installed but no device trusted/connected, confirm neither warning appears spuriously (an empty device list from `idevice_id -l` is not the same as "tools not installed" — `checkStatus()` should report `toolsInstalled: true, connectedButUnreadableCount: 0` in that case, so `iDeviceStatusWarning` correctly returns `nil`).

- [ ] **Step 9: Commit**

```bash
git add Sources/ibattery-mcp/main.swift Sources/IBatteryCore/DataSources/IDeviceBattery.swift Sources/IBatteryCore/MCPServerFactory.swift Tests/IBatteryCoreTests/IDeviceStatusWarningTests.swift
git commit -m "Wire IDeviceBatterySource in and surface its status in both MCP tools"
```

---

## What This Plan Does Not Cover

- Apple Watch battery via a paired iPhone (Plan 3, research spike — the companion-proxy protocol over lockdownd needs independent investigation before scope is finalized, per the design doc).
- A Homebrew formula `depends_on "libimobiledevice"` declaration — that's part of the distribution plan (Plan 4), alongside the formula for `ibattery-mcp` itself.
- WiFi-only pairing edge cases beyond what `idevice_id -l`/`ideviceinfo` already handle natively (the design doc's original table also lists `idevice_id -n` for network-discovered devices; this plan only wires up `-l`/USB enumeration — extending to `-n` is a small, natural follow-up but is intentionally left out here to keep this plan's first pass focused, since it wasn't verified against real hardware during planning and deserves its own manual QA pass).
