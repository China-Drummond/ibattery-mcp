# ibattery-mcp Plan 3: Apple Watch Battery via companion_proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Apple Watch battery reporting to `ibattery-mcp`, read through a paired-and-connected iPhone's `com.apple.companion_proxy` lockdownd service.

**Architecture:** Unlike AirBattery (which shells out to a bundled third-party binary, `comptest`, whose source isn't distributed with that project), this plan calls libimobiledevice's own official, documented, LGPL-licensed `companion_proxy.h` C API **directly from Swift**, via a new SwiftPM `systemLibrary` target resolved through `pkg-config`. No new CLI tool is written or bundled — `companion_proxy_get_device_registry`/`companion_proxy_get_value_from_registry` are called natively. This was a deliberate choice over writing a separate C helper executable (simpler: no extra compiled artifact, direct type-checked calls) and over `dlopen`/`dlsym` dynamic loading (simpler code, at the cost of a new **build-time**, not just runtime, dependency — see Global Constraints).

**Tech Stack:** Same package (`ibattery-mcp`), `swift-tools-version: 5.9`, `.macOS(.v13)`. New: a `systemLibrary` target wrapping `libimobiledevice`'s C headers (via `pkg-config`), used only by `IBatteryCore`/`ibattery-mcp` (not by `ibattery-ble-helper`, which has no reason to need it).

## Global Constraints

- Same repo, same package (`ibattery-mcp`), same existing targets (`IBatteryCore`, `ibattery-mcp`, `ibattery-ble-helper`, `IBatteryCoreTests`) from Plan 1/1b/2 — this plan adds one new target (`CLibimobiledevice`) and files, it does not restructure existing ones.
- `swift-tools-version: 5.9`, platform floor `.macOS(.v13)` (unchanged).
- No code or bundled binaries from AirBattery (AGPLv3) copied anywhere. This plan also does **not** reuse AirBattery's `comptest` gist (a separate, third-party tool by a different author, itself not part of this project's dependency graph) — it calls libimobiledevice's own public API instead, which is a cleaner dependency story than either.
- **New build-time dependency, not just runtime (unlike Plan 2's CLI-shelling approach):** building this project now requires `pkg-config` and `libimobiledevice`'s headers/dylib to be present at **build time**, not only at runtime. Both are Homebrew-installable (`brew install pkg-config libimobiledevice`) and were installed and verified on this machine before writing this plan. This must be called out in this project's future build documentation/Homebrew formula (Plan 4) as a `depends_on ... => :build` requirement in addition to the existing runtime dependency on `libimobiledevice`'s CLI tools from Plan 2.
- **Empirically verified facts, not guesses** (confirmed on this machine by installing `libimobiledevice`+`pkg-config` via Homebrew, writing a scratch SwiftPM package with a `systemLibrary` target, and successfully compiling, linking, and running real calls against the actual library before writing this plan):
  - A `systemLibrary` target with `pkgConfig: "libimobiledevice-1.0"` and a `module.modulemap` exposing `libimobiledevice/libimobiledevice.h`, `libimobiledevice/lockdown.h`, and `libimobiledevice/companion_proxy.h` compiles and links correctly against the Homebrew-installed library, and its C types/functions (`idevice_t`, `idevice_new`, `idevice_free`, `companion_proxy_client_t`, `companion_proxy_client_start_service`, `companion_proxy_client_free`, `companion_proxy_get_device_registry`, `companion_proxy_get_value_from_registry`, and libplist's `plist_t`/`plist_array_get_size`/`plist_array_get_item`/`plist_get_string_val`/`plist_get_uint_val`/`plist_get_bool_val`/`plist_new_*`/`plist_free`) are directly callable from Swift with the exact signatures documented in the installed headers.
  - `companion_proxy_get_device_registry`/`companion_proxy_get_value_from_registry` use the **same plist key names already used for iPhone battery in Plan 2** — `BatteryCurrentCapacity` (uint), `BatteryIsCharging` (bool) — plus `ProductType` (string, e.g. `"Watch6,6"`) for identifying the watch. Source: libimobiledevice's own `comptest`-equivalent usage pattern (the gist AirBattery credits, read for research purposes only — no code from it is reused) and the installed header's own doc comments.
  - libplist's construction functions (`plist_new_array`, `plist_new_string`, `plist_new_uint`, `plist_new_bool`, `plist_array_append_item`) can build realistic synthetic fixtures for unit tests without needing real hardware — verified directly, since the same library used at runtime is available at test time too.
  - Building against the Homebrew-installed dylib emits a harmless linker warning (`building for macOS-13.0, but linking with dylib ... built for newer version`) — cosmetic, not a build failure, safe to ignore.
- This plan's scope is Apple Watch battery **only**, reached through an already-connected iPhone (reusing Plan 2's existing `idevice_id -l` enumeration — no changes to `IDeviceBatterySource`). It does not attempt to support a Watch connected without an intermediary trusted iPhone (not how the companion_proxy protocol works) and does not add a dedicated "watch unreachable" warning — a paired iPhone with no Watch, or a Watch that's out of range, is the ordinary/common case (most users don't have a Watch at all) and should degrade to an empty result silently, consistent with how "no BLE devices found" isn't itself a warning-worthy condition elsewhere in this codebase.
- AirPods' proprietary Continuity BLE protocol remains explicitly out of scope for this plan too (its own future plan, per the design doc and Plan 1's constraints — the byte-level format is still genuinely disputed across public sources and needs its own research-first pass, ideally validated against real hardware the user has confirmed they own).
- Testing philosophy (unchanged from Plan 1/1b/2): pure parsing/logic functions (including ones that consume `plist_t` fixtures constructed via libplist's own API) are unit tested; the actual `idevice_new`/`companion_proxy_client_start_service` calls against a real iPhone+Watk require real hardware and are manual-QA-only.

---

### Task 1: `CLibimobiledevice` system library target + `WatchBatterySource`

**Files:**
- Modify: `Package.swift` (add the `systemLibrary` target, add it as a dependency of `IBatteryCore`)
- Modify: `Sources/IBatteryCore/DeviceBatteryInfo.swift` (add `.watch` to `Kind`)
- Create: `Sources/CLibimobiledevice/module.modulemap`
- Create: `Sources/CLibimobiledevice/shim.h`
- Create: `Sources/IBatteryCore/DataSources/WatchBattery.swift`
- Create: `Tests/IBatteryCoreTests/WatchBatteryTests.swift`

**Interfaces:**
- Consumes: `DeviceBatteryInfo`, `BatteryDataSource` (Plan 1 Tasks 2 and 4); `runLibimobiledeviceTool`, `parseDeviceIdList` (Plan 2 Task 1 — reused as-is, not modified).
- Produces: `public func parseUDIDList(fromPairedDevicesPlist plist: plist_t?) -> [String]`, `public func parseWatchBatteryValue(fromCapacityPlist capacityPlist: plist_t?, chargingPlist: plist_t?) -> (percentage: Int, isCharging: Bool)?`, `public func parseWatchProductType(fromPlist plist: plist_t?) -> String?`, `public struct WatchBatterySource: BatteryDataSource`.

- [ ] **Step 1: Add the `CLibimobiledevice` system library target**

Create `Sources/CLibimobiledevice/module.modulemap`:
```
module CLibimobiledevice {
    header "shim.h"
    link "imobiledevice-1.0"
    export *
}
```

Create `Sources/CLibimobiledevice/shim.h`:
```c
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/companion_proxy.h>
```

In `Package.swift`, add a new target to the `targets:` array (alongside the existing `IBatteryCore`/`ibattery-mcp`/`ibattery-ble-helper`/`IBatteryCoreTests` targets — do not remove or reorder the existing ones):
```swift
        .systemLibrary(
            name: "CLibimobiledevice",
            pkgConfig: "libimobiledevice-1.0",
            providers: [.brew(["libimobiledevice"])]
        ),
```

Change the existing `IBatteryCore` target's dependencies from:
```swift
        .target(
            name: "IBatteryCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
```
to:
```swift
        .target(
            name: "IBatteryCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                "CLibimobiledevice"
            ]
        ),
```

- [ ] **Step 2: Verify the prerequisites are installed and the new target builds**

Run: `pkg-config --exists libimobiledevice-1.0 && echo "found"`
Expected: `found`. If not, run `brew install pkg-config libimobiledevice` first (already done on this machine during planning; confirm on whichever machine implements this task).

Run: `swift build`
Expected: `Build complete!` — the new target should compile and link (a harmless `ld: warning: building for macOS-13.0, but linking with dylib ... built for newer version` may appear; this is not a build failure).

- [ ] **Step 3: Add the new device kind**

In `Sources/IBatteryCore/DeviceBatteryInfo.swift`, change:
```swift
    public enum Kind: String, Codable, Sendable {
        case mac
        case bleGeneric
        case iosDevice
    }
```
to:
```swift
    public enum Kind: String, Codable, Sendable {
        case mac
        case bleGeneric
        case iosDevice
        case watch
    }
```

- [ ] **Step 4: Write the failing tests for the pure parsing functions**

```swift
// Tests/IBatteryCoreTests/WatchBatteryTests.swift
import XCTest
import CLibimobiledevice
@testable import IBatteryCore

final class WatchBatteryTests: XCTestCase {
    func testParseUDIDList_multipleEntries() {
        let plist = plist_new_array()
        plist_array_append_item(plist, plist_new_string("00008310-001A2C3D4E5F001E"))
        plist_array_append_item(plist, plist_new_string("00008310-001A2C3D4E5F002F"))
        defer { plist_free(plist) }

        XCTAssertEqual(parseUDIDList(fromPairedDevicesPlist: plist), [
            "00008310-001A2C3D4E5F001E",
            "00008310-001A2C3D4E5F002F"
        ])
    }

    func testParseUDIDList_emptyArray_returnsEmpty() {
        let plist = plist_new_array()
        defer { plist_free(plist) }
        XCTAssertEqual(parseUDIDList(fromPairedDevicesPlist: plist), [])
    }

    func testParseUDIDList_nilPlist_returnsEmpty() {
        XCTAssertEqual(parseUDIDList(fromPairedDevicesPlist: nil), [])
    }

    func testParseWatchBatteryValue_validValues() {
        let capacityPlist = plist_new_uint(66)
        let chargingPlist = plist_new_bool(1)
        defer {
            plist_free(capacityPlist)
            plist_free(chargingPlist)
        }

        let result = parseWatchBatteryValue(fromCapacityPlist: capacityPlist, chargingPlist: chargingPlist)
        XCTAssertEqual(result?.percentage, 66)
        XCTAssertEqual(result?.isCharging, true)
    }

    func testParseWatchBatteryValue_nilCapacity_returnsNil() {
        XCTAssertNil(parseWatchBatteryValue(fromCapacityPlist: nil, chargingPlist: nil))
    }

    func testParseWatchBatteryValue_nilCharging_defaultsToFalse() {
        let capacityPlist = plist_new_uint(50)
        defer { plist_free(capacityPlist) }

        let result = parseWatchBatteryValue(fromCapacityPlist: capacityPlist, chargingPlist: nil)
        XCTAssertEqual(result?.percentage, 50)
        XCTAssertEqual(result?.isCharging, false)
    }

    func testParseWatchProductType_validString() {
        let plist = plist_new_string("Watch6,6")
        defer { plist_free(plist) }
        XCTAssertEqual(parseWatchProductType(fromPlist: plist), "Watch6,6")
    }

    func testParseWatchProductType_nilPlist_returnsNil() {
        XCTAssertNil(parseWatchProductType(fromPlist: nil))
    }
}
```

- [ ] **Step 5: Run the tests and verify they fail**

Run: `swift test --filter WatchBatteryTests`
Expected: FAIL to compile — `parseUDIDList`, `parseWatchBatteryValue`, `parseWatchProductType` not found.

- [ ] **Step 6: Implement the pure parsing functions**

```swift
// Sources/IBatteryCore/DataSources/WatchBattery.swift
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
            free(cstr)
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
    defer { free(cstr) }
    return String(cString: cstr)
}
```

- [ ] **Step 7: Run the tests and verify they pass**

Run: `swift test --filter WatchBatteryTests`
Expected: `Test Suite 'WatchBatteryTests' passed` (8 tests).

- [ ] **Step 8: Implement `WatchBatterySource`**

Add to the same file, `Sources/IBatteryCore/DataSources/WatchBattery.swift`:

```swift
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
```

- [ ] **Step 9: Build and run the full test suite**

Run: `swift build && swift test`
Expected: `Build complete!`, then all tests pass (52 tests: the prior 44 from Plan 1/1b/2 plus these 8 new `WatchBatteryTests`).

- [ ] **Step 10: Manual QA note**

`WatchBatterySource.fetchAll()`'s live `idevice_new`/`companion_proxy_*` calls cannot be unit-tested (a real, USB-or-WiFi-connected, trusted iPhone with a real paired Apple Watch is required). Before considering this task validated on real hardware:
1. Confirm `libimobiledevice` and `pkg-config` are installed (`brew install libimobiledevice pkg-config`).
2. Connect a real iPhone (with a paired Apple Watch) via USB, or ensure it's trusted and reachable over WiFi.
3. Manually verify via a throwaway `print(await WatchBatterySource().fetchAll())` in `main.swift`, `swift run`, confirm a real `DeviceBatteryInfo` with a plausible percentage/`ProductType`-derived name is printed, then revert the throwaway print before committing.
4. If this doesn't work as expected, capture the actual `idevice_error_t`/`companion_proxy_error_t` values returned at each step (they're meaningful — e.g. `COMPANION_PROXY_E_NO_DEVICES = -100` specifically means "no Watch paired," not a bug) before concluding something is broken.

- [ ] **Step 11: Commit**

```bash
git add Package.swift Sources/IBatteryCore/DeviceBatteryInfo.swift Sources/CLibimobiledevice Sources/IBatteryCore/DataSources/WatchBattery.swift Tests/IBatteryCoreTests/WatchBatteryTests.swift
git commit -m "Add Apple Watch battery source via libimobiledevice companion_proxy API"
```

---

### Task 2: Wire `WatchBatterySource` into the registry

**Files:**
- Modify: `Sources/ibattery-mcp/main.swift` (add `WatchBatterySource()` to the registry's sources)

**Interfaces:**
- Consumes: `WatchBatterySource` (Task 1).

- [ ] **Step 1: Wire `WatchBatterySource` into the registry**

In `Sources/ibattery-mcp/main.swift`, change:
```swift
let registry = DeviceRegistry(sources: [MacBatterySource(), BLEBatterySource(), IDeviceBatterySource()])
```
to:
```swift
let registry = DeviceRegistry(sources: [MacBatterySource(), BLEBatterySource(), IDeviceBatterySource(), WatchBatterySource()])
```

- [ ] **Step 2: Build and run the full test suite**

Run: `swift build && swift test`
Expected: `Build complete!`, all 52 tests still pass (this change adds no new tests — it's pure wiring).

- [ ] **Step 3: Manual end-to-end verification**

```bash
BIN=$(swift build --show-bin-path)/ibattery-mcp
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe-client","version":"0.1"}}}'
  sleep 0.3
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  sleep 0.3
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_all_devices_status","arguments":{}}}'
  sleep 3
} | "$BIN" &
PID=$!
sleep 5
kill $PID 2>/dev/null
wait $PID 2>/dev/null
```
Expected: the process does not crash and returns a valid JSON array in the `tools/call` response — on a machine with a real, connected, trusted iPhone that has a paired Apple Watch, the array should include a `kind: "watch"` entry with a plausible percentage. On a machine with no iPhone/Watch connected (like the one used to write and initially test this plan), an empty result for this specific source is expected and correct, not a failure.

- [ ] **Step 4: Commit**

```bash
git add Sources/ibattery-mcp/main.swift
git commit -m "Wire WatchBatterySource into the device registry"
```

---

## What This Plan Does Not Cover

- AirPods' proprietary Apple Continuity BLE protocol: still its own future plan, per the design doc — the user has confirmed they own real AirPods (4th generation) and a separate MacBook running AirBattery for side-by-side comparison, which should make empirical byte-format verification much more tractable than pure desk research once that plan is taken up.
- A Homebrew formula `depends_on "libimobiledevice"` / `depends_on "pkg-config" => :build` declaration — part of the distribution plan (Plan 4).
- LAN multi-Mac companion (still deferred per the design doc, unrelated to this plan).
