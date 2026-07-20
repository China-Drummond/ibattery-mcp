# AirPods Battery Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add AirPods (and other Apple-vendor truly-wireless earbuds) as a battery data source, and add a local-timezone timestamp field to every device's JSON output.

**Architecture:** A new `AirPodsBatterySource` shells out to `/usr/sbin/system_profiler SPBluetoothDataType -json` (the same official tool AirBattery itself uses) and parses Left/Right/Case battery fields into up to three `DeviceBatteryInfo` entries per device. The existing libimobiledevice-specific subprocess-watchdog helper is generalized into a shared, command-agnostic helper so all three subprocess-backed sources (iPhone, Watch, AirPods) use one implementation. Separately, `DeviceBatteryInfo` gains a `lastUpdatedLocal` field — an ISO8601 string with the local UTC offset, always derived from `lastUpdated`, so JSON consumers don't need to independently know the user's timezone to reason about freshness (most relevant for AirPods, since `system_profiler` returns cached, possibly stale, battery levels).

**Tech Stack:** Swift Package Manager, Foundation (`JSONSerialization`, `ISO8601DateFormatter`, `Process`), XCTest.

## Global Constraints

- New `DeviceBatteryInfo.Kind` case: `.airpods`.
- New `DeviceBatteryInfo.lastUpdatedLocal: String` field: ISO8601 with the
  local UTC offset (`TimeZone.current`), always computed from `lastUpdated`
  — on both construction and decode, never trusted from wire input. Applies
  to every device kind, not just AirPods.
- AirPods filter: `device_vendorID == "0x004C"` AND `device_address` present
  and non-empty AND at least one of `device_batteryLevelLeft` /
  `device_batteryLevelRight` / `device_batteryLevelCase` present.
- AirPods percentage parsing: strip `%` and whitespace, then `Int(...)`. A
  field that fails to parse as an integer is treated as absent.
- AirPods `id` scheme: `"<lowercased device_address>-left"` / `"-right"` /
  `"-case"`.
- AirPods `name` scheme: `"<display name> (Left)"` / `"(Right)"` / `"(Case)"`.
- AirPods `isCharging`: always `nil` — `system_profiler` never reports a
  charging flag for these fields.
- Subprocess helper: `runLibimobiledeviceTool` renamed to `runSubprocess`,
  `defaultLibimobiledeviceTimeoutSeconds` renamed to
  `defaultSubprocessTimeoutSeconds`, moved to a new file
  `Sources/IBatteryCore/DataSources/Subprocess.swift`. No behavior change.
- `system_profiler` is invoked as the bare command name `"system_profiler"`
  (PATH-resolved via the existing `/usr/bin/env` convention already used for
  `idevice_id`/`ideviceinfo`), with arguments `["SPBluetoothDataType", "-json"]`.
- Test fixtures must use fake MAC addresses (e.g. `AA:BB:CC:DD:EE:FF`,
  `11:22:33:44:55:66`) — never real captured hardware identifiers.
- README AirPods row wording: `⚠️ Implemented, unit-tested — not yet
  confirmed against real hardware` (English) / `⚠️ 已实现、有单元测试 — 但还没有在真实硬件上验证过` (Chinese) — matching the wording already used for
  the other not-yet-hardware-verified rows.

---

### Task 1: Add `lastUpdatedLocal` to `DeviceBatteryInfo`

**Files:**
- Modify: `Sources/IBatteryCore/DeviceBatteryInfo.swift`
- Test: `Tests/IBatteryCoreTests/DeviceBatteryInfoTests.swift` (create)

**Interfaces:**
- Consumes: nothing new — this is the foundational change other tasks build on.
- Produces: the new `DeviceBatteryInfo.Kind.airpods` case (Task 3 constructs
  entries with this kind) and `DeviceBatteryInfo.lastUpdatedLocal: String`, always present and
  always derived from `lastUpdated` via `TimeZone.current`. Every later task
  that constructs a `DeviceBatteryInfo` gets this field automatically — no
  call site elsewhere needs to change.

This task replaces `DeviceBatteryInfo`'s synthesized `Codable` conformance
with a hand-written one, because a synthesized `Decodable` would require the
new field to be present in every JSON payload — which would break the
existing BLE-helper IPC round trip fixture in
`Tests/IBatteryCoreTests/BLEBatterySourceIPCTests.swift:9`, whose hand-written
JSON literal has no `lastUpdatedLocal` key. The hand-written implementation
below never reads `lastUpdatedLocal` from incoming JSON at all — it's always
recomputed from the decoded `lastUpdated`, so old and new payloads both
decode correctly, and the field can never become inconsistent with
`lastUpdated`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/IBatteryCoreTests/DeviceBatteryInfoTests.swift`:

```swift
// Tests/IBatteryCoreTests/DeviceBatteryInfoTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class DeviceBatteryInfoTests: XCTestCase {
    func testInit_lastUpdatedLocal_roundTripsToSameInstantAsLastUpdated() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let info = DeviceBatteryInfo(
            id: "x",
            name: "X",
            kind: .mac,
            percentage: 50,
            isCharging: nil,
            lastUpdated: date
        )

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        let parsedBack = parser.date(from: info.lastUpdatedLocal)

        XCTAssertNotNil(parsedBack)
        XCTAssertEqual(parsedBack?.timeIntervalSince1970 ?? -1, date.timeIntervalSince1970, accuracy: 1.0)
    }

    func testDecode_legacyJSONWithoutLastUpdatedLocalKey_stillDecodes() {
        let json = """
        {"id":"abc","name":"Test Mouse","kind":"bleGeneric","percentage":72,"isCharging":null,"lastUpdated":"2026-07-19T08:00:00Z","stale":false}
        """
        let decoded = try? deviceJSONDecoder.decode(DeviceBatteryInfo.self, from: Data(json.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.id, "abc")
        XCTAssertFalse(decoded?.lastUpdatedLocal.isEmpty ?? true)
    }

    func testDecode_missingStaleKey_throws() {
        let json = """
        {"id":"abc","name":"Test Mouse","kind":"bleGeneric","percentage":72,"isCharging":null,"lastUpdated":"2026-07-19T08:00:00Z"}
        """
        XCTAssertThrowsError(try deviceJSONDecoder.decode(DeviceBatteryInfo.self, from: Data(json.utf8)))
    }

    func testEncode_includesLastUpdatedLocalKey() {
        let info = DeviceBatteryInfo(
            id: "x",
            name: "X",
            kind: .mac,
            percentage: 50,
            isCharging: nil,
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try! deviceJSONEncoder.encode(info)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"lastUpdatedLocal\""))
    }

    func testEquatable_sameLastUpdated_producesEqualLastUpdatedLocal() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = DeviceBatteryInfo(id: "x", name: "X", kind: .mac, percentage: 50, isCharging: nil, lastUpdated: date)
        let b = DeviceBatteryInfo(id: "x", name: "X", kind: .mac, percentage: 50, isCharging: nil, lastUpdated: date)
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DeviceBatteryInfoTests`
Expected: FAIL — `DeviceBatteryInfoTests.swift` doesn't compile yet
(`lastUpdatedLocal` doesn't exist on `DeviceBatteryInfo`).

- [ ] **Step 3: Implement `lastUpdatedLocal`**

Replace the full contents of `Sources/IBatteryCore/DeviceBatteryInfo.swift`
with:

```swift
import Foundation

public struct DeviceBatteryInfo: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case mac
        case bleGeneric
        case iosDevice
        case watch
        case airpods
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let percentage: Int
    public let isCharging: Bool?
    public let lastUpdated: Date
    /// ISO8601 timestamp of `lastUpdated` expressed in this machine's local
    /// UTC offset (`TimeZone.current`), rather than `lastUpdated`'s own
    /// always-UTC encoding. Added so a JSON consumer (an LLM reasoning about
    /// "how stale is this reading") doesn't have to separately know the
    /// user's timezone to interpret `lastUpdated` — most relevant for
    /// sources like AirPods that can report a cached, possibly-old battery
    /// level. Always derived from `lastUpdated`; never read from decoded
    /// JSON (see `init(from:)`) so it can never drift out of sync with it.
    public let lastUpdatedLocal: String
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
        self.lastUpdatedLocal = Self.formatLocal(lastUpdated)
        self.stale = stale
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, percentage, isCharging, lastUpdated, lastUpdatedLocal, stale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        percentage = try container.decode(Int.self, forKey: .percentage)
        isCharging = try container.decodeIfPresent(Bool.self, forKey: .isCharging)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        stale = try container.decode(Bool.self, forKey: .stale)
        lastUpdatedLocal = Self.formatLocal(lastUpdated)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(percentage, forKey: .percentage)
        try container.encode(isCharging, forKey: .isCharging)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(lastUpdatedLocal, forKey: .lastUpdatedLocal)
        try container.encode(stale, forKey: .stale)
    }

    private static let localTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func formatLocal(_ date: Date) -> String {
        localTimestampFormatter.string(from: date)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DeviceBatteryInfoTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full test suite to confirm no regressions**

Run: `swift test`
Expected: PASS — all previously-existing tests (57 before this task) still
pass, since `lastUpdatedLocal` is never required on decode and every
`DeviceBatteryInfo` equality comparison is between two values built the same
way (same `lastUpdated` in → same `lastUpdatedLocal` out).

- [ ] **Step 6: Commit**

```bash
git add Sources/IBatteryCore/DeviceBatteryInfo.swift Tests/IBatteryCoreTests/DeviceBatteryInfoTests.swift
git commit -m "Add lastUpdatedLocal timezone-aware timestamp to DeviceBatteryInfo"
```

---

### Task 2: Extract the subprocess helper into a shared, command-agnostic file

**Files:**
- Create: `Sources/IBatteryCore/DataSources/Subprocess.swift`
- Create: `Tests/IBatteryCoreTests/SubprocessTests.swift`
- Modify: `Sources/IBatteryCore/DataSources/IDeviceBattery.swift`
- Modify: `Sources/IBatteryCore/DataSources/WatchBattery.swift`
- Modify: `Tests/IBatteryCoreTests/IDeviceBatteryTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `runSubprocess(_ command: String, _ arguments: [String], timeoutSeconds: TimeInterval = defaultSubprocessTimeoutSeconds) -> (stdout: Data, exitCode: Int32)`, used by `IDeviceBatterySource`, `WatchBatterySource`, and (in Task 3) `AirPodsBatterySource`.

This is a pure rename-and-move refactor: no behavior changes to the two
existing call sites. It exists because `IDeviceBattery.swift`'s
`runLibimobiledeviceTool` is a general-purpose subprocess-with-timeout-
watchdog helper that has nothing libimobiledevice-specific about it (its own
existing tests already invoke `sleep`/`true`, not any libimobiledevice
binary) — Task 3 needs the identical guarantee for `system_profiler`.

- [ ] **Step 1: Create `Sources/IBatteryCore/DataSources/Subprocess.swift`**

```swift
// Sources/IBatteryCore/DataSources/Subprocess.swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Default wall-clock budget for a single `runSubprocess` invocation.
/// External CLI tools normally return in well under a second; this leaves
/// generous headroom for a slow-but-working call while still guaranteeing
/// the watchdog below fires long before anyone would consider the MCP
/// server "hung".
let defaultSubprocessTimeoutSeconds: TimeInterval = 5.0

/// Runs an external CLI tool (`idevice_id`, `ideviceinfo`, `system_profiler`,
/// ...) and captures its stdout/exit code, with a wall-clock watchdog.
///
/// Without this watchdog, a stalled child process (untrusted-but-connected
/// device, wedged `usbmuxd`, a WiFi-paired device dropping mid-call) would
/// block `readDataToEndOfFile()`/`waitUntilExit()` forever, hanging the whole
/// MCP process. That would violate the same "must never hang or crash
/// regardless of external device/hardware flakiness" invariant that
/// `BLEBatterySource`'s socket read-timeouts (`SO_RCVTIMEO`) already
/// guarantee for the Bluetooth path — this brings every subprocess-backed
/// data source to the same standard: if the child hasn't exited within
/// `timeoutSeconds`, it's terminated and treated as a failure (non-zero exit
/// code) instead of hanging the caller indefinitely. A short grace period
/// after `terminate()` escalates to `SIGKILL` in case the child ignores
/// `SIGTERM`, so the guarantee holds even for a misbehaving binary, not just
/// the well-behaved ones we expect in practice.
func runSubprocess(
    _ command: String,
    _ arguments: [String],
    timeoutSeconds: TimeInterval = defaultSubprocessTimeoutSeconds
) -> (stdout: Data, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
    } catch {
        return (Data(), -1)
    }

    let terminateWorkItem = DispatchWorkItem {
        if process.isRunning {
            process.terminate()
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: terminateWorkItem)

    // Grace period in case the child ignores SIGTERM; escalate to SIGKILL so
    // the watchdog's guarantee holds unconditionally.
    let killWorkItem = DispatchWorkItem {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds + 2.0, execute: killWorkItem)

    let errDrainThread = Thread {
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
    }
    errDrainThread.start()
    let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    terminateWorkItem.cancel()
    killWorkItem.cancel()
    return (stdoutData, process.terminationStatus)
}
```

- [ ] **Step 2: Move the watchdog tests to their own file**

Create `Tests/IBatteryCoreTests/SubprocessTests.swift`:

```swift
// Tests/IBatteryCoreTests/SubprocessTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class SubprocessTests: XCTestCase {
    func testRunSubprocess_hangingProcess_returnsPromptlyOnTimeout() {
        let start = Date()
        let result = runSubprocess("sleep", ["10"], timeoutSeconds: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertLessThan(elapsed, 5.0, "watchdog should terminate the hung process well before the full 10s sleep completes")
    }

    func testRunSubprocess_fastProcess_succeedsWithinTimeout() {
        let result = runSubprocess("true", [], timeoutSeconds: 5.0)
        XCTAssertEqual(result.exitCode, 0)
    }
}
```

In `Tests/IBatteryCoreTests/IDeviceBatteryTests.swift`, delete the now-moved
tests — remove this entire block (including its `MARK` comment):

```swift
    // MARK: - runLibimobiledeviceTool watchdog

    func testRunLibimobiledeviceTool_hangingProcess_returnsPromptlyOnTimeout() {
        let start = Date()
        let result = runLibimobiledeviceTool("sleep", ["10"], timeoutSeconds: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertLessThan(elapsed, 5.0, "watchdog should terminate the hung process well before the full 10s sleep completes")
    }

    func testRunLibimobiledeviceTool_fastProcess_succeedsWithinTimeout() {
        let result = runLibimobiledeviceTool("true", [], timeoutSeconds: 5.0)
        XCTAssertEqual(result.exitCode, 0)
    }
```

(This leaves `IDeviceBatteryTests.swift` ending right after the
`UnreadableCountCache` tests block.)

- [ ] **Step 3: Run the new/moved tests to verify they pass, and the deleted ones are gone**

Run: `swift test --filter SubprocessTests`
Expected: PASS (2 tests).

Run: `swift test --filter IDeviceBatteryTests`
Expected: PASS — no `runLibimobiledeviceTool` references remain in this
file at this point, so this will fail to compile until Step 4 renames the
production call sites. Do Step 4 now, then come back and re-run this.

- [ ] **Step 4: Update `IDeviceBattery.swift` to use the shared helper**

In `Sources/IBatteryCore/DataSources/IDeviceBattery.swift`:

Remove the `#if canImport(Darwin) import Darwin #endif` block at the top
(lines 2-4) — it's no longer needed here now that the only `kill()` call has
moved to `Subprocess.swift`. The file should start with just:

```swift
import Foundation
```

Remove the `defaultLibimobiledeviceTimeoutSeconds` constant and the entire
`runLibimobiledeviceTool` function (originally lines 34-100) — both now live
in `Subprocess.swift`.

Rename every remaining call site in this file from `runLibimobiledeviceTool`
to `runSubprocess` (4 call sites: `checkStatus()`, `fetchAllBlocking()` twice,
`fetchDeviceInfo(udid:viaNetwork:)` twice). For example:

```swift
    public static func checkStatus() -> IDeviceStatus {
        let idResult = runSubprocess("idevice_id", ["-l"])
        return iDeviceStatus(fromToolsProbeExitCode: idResult.exitCode, cachedUnreadableCount: unreadableCountCache.value)
    }
```

Also update the doc comments that mention `runLibimobiledeviceTool` by name
(lines 181, 190) to say `runSubprocess` instead, so they stay accurate.

- [ ] **Step 5: Update `WatchBattery.swift` to use the shared helper**

In `Sources/IBatteryCore/DataSources/WatchBattery.swift`, rename both call
sites in `fetchAllBlocking()`:

```swift
    private static func fetchAllBlocking() -> [DeviceBatteryInfo] {
        let usbResult = runSubprocess("idevice_id", ["-l"])
        let networkResult = runSubprocess("idevice_id", ["-n"])
```

And update the doc comment above it that mentions `runLibimobiledeviceTool`'s
watchdog (around line 66) to say `runSubprocess` instead.

- [ ] **Step 6: Run the full test suite**

Run: `swift test`
Expected: PASS — same 57 tests as before Task 1, plus this task's 2 moved
`SubprocessTests` (no net new test count from this task, since they were
moved, not added: 57 + 5 from Task 1 = 62, unchanged by this task's move).
Total: 62.

- [ ] **Step 7: Commit**

```bash
git add Sources/IBatteryCore/DataSources/Subprocess.swift \
        Sources/IBatteryCore/DataSources/IDeviceBattery.swift \
        Sources/IBatteryCore/DataSources/WatchBattery.swift \
        Tests/IBatteryCoreTests/SubprocessTests.swift \
        Tests/IBatteryCoreTests/IDeviceBatteryTests.swift
git commit -m "Extract runLibimobiledeviceTool into a shared, command-agnostic runSubprocess"
```

---

### Task 3: Implement `AirPodsBatterySource`

**Files:**
- Create: `Sources/IBatteryCore/DataSources/AirPodsBattery.swift`
- Create: `Tests/IBatteryCoreTests/AirPodsBatteryTests.swift`
- Modify: `Sources/ibattery-mcp/main.swift`

**Interfaces:**
- Consumes: `runSubprocess(_:_:timeoutSeconds:)` from Task 2;
  `DeviceBatteryInfo`/`DeviceBatteryInfo.Kind.airpods` from Task 1;
  `BatteryDataSource` protocol (`func fetchAll() async -> [DeviceBatteryInfo]`,
  already defined in `Sources/IBatteryCore/DeviceRegistry.swift`).
- Produces: `public func parseSystemProfilerBluetoothJSON(_ data: Data, fetchedAt: Date) -> [DeviceBatteryInfo]` (pure, unit-tested) and `public struct AirPodsBatterySource: BatteryDataSource`.

- [ ] **Step 1: Write the failing parsing tests**

Create `Tests/IBatteryCoreTests/AirPodsBatteryTests.swift`:

```swift
// Tests/IBatteryCoreTests/AirPodsBatteryTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class AirPodsBatteryTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testParse_allThreeFieldsPresent_emitsThreeEntries() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_not_connected": [
                {
                  "Someone's AirPods4": {
                    "device_address": "AA:BB:CC:DD:EE:FF",
                    "device_batteryLevelCase": "51%",
                    "device_batteryLevelLeft": "100%",
                    "device_batteryLevelRight": "97%",
                    "device_vendorID": "0x004C"
                  }
                }
              ]
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result.count, 3)

        let left = result.first { $0.id == "aa:bb:cc:dd:ee:ff-left" }
        XCTAssertEqual(left?.name, "Someone's AirPods4 (Left)")
        XCTAssertEqual(left?.kind, .airpods)
        XCTAssertEqual(left?.percentage, 100)
        XCTAssertNil(left?.isCharging)
        XCTAssertEqual(left?.lastUpdated, fixedDate)

        let right = result.first { $0.id == "aa:bb:cc:dd:ee:ff-right" }
        XCTAssertEqual(right?.name, "Someone's AirPods4 (Right)")
        XCTAssertEqual(right?.percentage, 97)

        let caseEntry = result.first { $0.id == "aa:bb:cc:dd:ee:ff-case" }
        XCTAssertEqual(caseEntry?.name, "Someone's AirPods4 (Case)")
        XCTAssertEqual(caseEntry?.percentage, 51)
    }

    func testParse_onlyCasePresent_emitsSingleCaseEntry() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_not_connected": [
                {
                  "Someone's AirPods4": {
                    "device_address": "AA:BB:CC:DD:EE:FF",
                    "device_batteryLevelCase": "51%",
                    "device_vendorID": "0x004C"
                  }
                }
              ]
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "aa:bb:cc:dd:ee:ff-case")
        XCTAssertEqual(result[0].percentage, 51)
    }

    func testParse_nonAppleVendorID_isSkipped() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_not_connected": [
                {
                  "Jabra Elite 75t": {
                    "device_address": "11:22:33:44:55:66",
                    "device_batteryLevelLeft": "80%",
                    "device_batteryLevelRight": "80%",
                    "device_vendorID": "0x0067"
                  }
                }
              ]
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result, [])
    }

    func testParse_malformedPercentageString_skipsThatFieldOnly() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_not_connected": [
                {
                  "Someone's AirPods4": {
                    "device_address": "AA:BB:CC:DD:EE:FF",
                    "device_batteryLevelLeft": "not-a-number",
                    "device_batteryLevelRight": "97%",
                    "device_vendorID": "0x004C"
                  }
                }
              ]
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "aa:bb:cc:dd:ee:ff-right")
    }

    func testParse_missingDeviceAddress_skipsEntry() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_not_connected": [
                {
                  "Someone's AirPods4": {
                    "device_batteryLevelLeft": "100%",
                    "device_vendorID": "0x004C"
                  }
                }
              ]
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result, [])
    }

    func testParse_missingConnectedAndNotConnectedKeys_returnsEmpty() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "controller_properties": { "controller_address": "D0:11:E5:87:61:EB" }
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result, [])
    }

    func testParse_emptyTopLevelArray_returnsEmpty() {
        let json = """
        { "SPBluetoothDataType": [] }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result, [])
    }

    func testParse_malformedJSON_returnsEmptyWithoutCrashing() {
        let result = parseSystemProfilerBluetoothJSON(Data("not json".utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result, [])
    }

    func testParse_bothConnectedAndNotConnectedDevicesAreIncluded() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "Connected AirPods": {
                    "device_address": "11:11:11:11:11:11",
                    "device_batteryLevelLeft": "60%",
                    "device_vendorID": "0x004C"
                  }
                }
              ],
              "device_not_connected": [
                {
                  "Cached AirPods": {
                    "device_address": "22:22:22:22:22:22",
                    "device_batteryLevelCase": "40%",
                    "device_vendorID": "0x004C"
                  }
                }
              ]
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains { $0.id == "11:11:11:11:11:11-left" })
        XCTAssertTrue(result.contains { $0.id == "22:22:22:22:22:22-case" })
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AirPodsBatteryTests`
Expected: FAIL to compile — `parseSystemProfilerBluetoothJSON` and
`DeviceBatteryInfo.Kind.airpods` (already added in Task 1) exist, but
`AirPodsBattery.swift` doesn't exist yet.

- [ ] **Step 3: Implement the parsing function and the data source**

Create `Sources/IBatteryCore/DataSources/AirPodsBattery.swift`:

```swift
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

        if let left = parsedBatteryPercentage(info["device_batteryLevelLeft"]) {
            results.append(DeviceBatteryInfo(
                id: "\(lowercasedAddress)-left",
                name: "\(name) (Left)",
                kind: .airpods,
                percentage: left,
                isCharging: nil,
                lastUpdated: fetchedAt
            ))
        }
        if let right = parsedBatteryPercentage(info["device_batteryLevelRight"]) {
            results.append(DeviceBatteryInfo(
                id: "\(lowercasedAddress)-right",
                name: "\(name) (Right)",
                kind: .airpods,
                percentage: right,
                isCharging: nil,
                lastUpdated: fetchedAt
            ))
        }
        if let caseLevel = parsedBatteryPercentage(info["device_batteryLevelCase"]) {
            results.append(DeviceBatteryInfo(
                id: "\(lowercasedAddress)-case",
                name: "\(name) (Case)",
                kind: .airpods,
                percentage: caseLevel,
                isCharging: nil,
                lastUpdated: fetchedAt
            ))
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AirPodsBatteryTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Register `AirPodsBatterySource` in the MCP server**

In `Sources/ibattery-mcp/main.swift`, change:

```swift
let registry = DeviceRegistry(sources: [MacBatterySource(), BLEBatterySource(), IDeviceBatterySource(), WatchBatterySource()])
```

to:

```swift
let registry = DeviceRegistry(sources: [MacBatterySource(), BLEBatterySource(), IDeviceBatterySource(), WatchBatterySource(), AirPodsBatterySource()])
```

- [ ] **Step 6: Run the full test suite**

Run: `swift test`
Expected: PASS — 62 tests from before this task + 9 new `AirPodsBatteryTests`
= 71 tests.

- [ ] **Step 7: Build the release binary and manually smoke-test against real `system_profiler` output**

Run: `swift build -c release`
Expected: builds cleanly.

Run:
```bash
(
  printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke-test","version":"0.0.1"}}}\n'
  printf '{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
  printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_all_devices_status","arguments":{}}}\n'
  sleep 5
) | ./.build/release/ibattery-mcp
```
Expected: the JSON-RPC response for id 2 includes `"kind":"airpods"` entries
if any Apple-vendor earbuds are currently known to this Mac (via
`system_profiler SPBluetoothDataType -json`), each with a `lastUpdatedLocal`
key. This is real-hardware verification, not a unit test — record the actual
output in the task report.

- [ ] **Step 8: Commit**

```bash
git add Sources/IBatteryCore/DataSources/AirPodsBattery.swift \
        Tests/IBatteryCoreTests/AirPodsBatteryTests.swift \
        Sources/ibattery-mcp/main.swift
git commit -m "Add AirPodsBatterySource via system_profiler SPBluetoothDataType"
```

---

### Task 4: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `README_zh.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: nothing (documentation-only task).
- Produces: nothing consumed by later tasks (this is the last task in this plan).

- [ ] **Step 1: Update `README.md`'s status table**

Change:

```markdown
| AirPods | 🚧 Not implemented yet (planned) |
```

to:

```markdown
| AirPods | ⚠️ Implemented, unit-tested — not yet confirmed against real hardware |
```

- [ ] **Step 2: Update `README_zh.md`'s status table**

Change:

```markdown
| AirPods | 🚧 尚未实现（计划中） |
```

to:

```markdown
| AirPods | ⚠️ 已实现、有单元测试 — 但还没有在真实硬件上验证过 |
```

- [ ] **Step 3: Update `CHANGELOG.md`**

In the `### Added` section, add a new bullet (after the Apple Watch bullet):

```markdown
- AirPods (and other Apple-vendor truly-wireless earbuds with a case)
  battery via `system_profiler SPBluetoothDataType -json` — reports Left,
  Right, and Case battery as separate entries; works even when the AirPods
  are connected to a different device on the same iCloud account, not just
  this Mac. **Implemented, unit-tested, not yet verified against real
  hardware** — see the project README's Status section.
- `lastUpdatedLocal`: every device entry's JSON now also includes an
  ISO8601 timestamp in this Mac's local UTC offset, alongside the existing
  UTC `lastUpdated`, so a caller doesn't need to separately know the user's
  timezone to reason about how fresh a reading is.
```

In the `### Known limitations` section, remove this now-outdated bullet
entirely:

```markdown
- AirPods (and Apple's proprietary Continuity BLE protocol generally) are not
  yet supported — planned for a future release once independently verified
  against real hardware.
```

- [ ] **Step 4: Commit**

```bash
git add README.md README_zh.md CHANGELOG.md
git commit -m "Document AirPods battery support and lastUpdatedLocal in README/CHANGELOG"
```
