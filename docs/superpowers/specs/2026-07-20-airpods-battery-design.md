# AirPods Battery Support — Design Doc

Date: 2026-07-20
Status: Approved (brainstorming phase)

## 1. Overview

Add AirPods (and any other Apple-vendor truly-wireless earbuds with a case —
e.g. Beats) as a battery data source, matching the scenario the user actually
wants: see battery for AirPods regardless of which device they're currently
connected to (iPhone, this Mac, or nothing), not just when paired directly to
this Mac.

**Relationship to AirBattery:** AirBattery's own implementation
(`AirBattery/BatteryInfo/MagicBattery.swift`, read for reference only, no code
reused — see the main [design doc](./2026-07-19-ibattery-mcp-design.md) for
the clean-room rationale) does **not** parse raw Bluetooth advertisements for
this. It shells out to `/usr/sbin/system_profiler SPBluetoothDataType -json`
and reads `device_batteryLevelLeft`/`device_batteryLevelRight`/
`device_batteryLevelCase` fields from the JSON. This was independently
confirmed against the user's real AirPods 4 during design: even with the
AirPods not connected to anything, `system_profiler` still reported cached
`device_batteryLevelCase: "51%"`, `device_batteryLevelLeft: "100%"`,
`device_batteryLevelRight: "100%"` under the `device_not_connected` array —
identical to AirBattery's own menu-bar display at the time.

This works because AirPods paired to any Apple device signed into the same
iCloud account are automatically known to every other device on that account
(Apple's "Automatic Device Switching" key-sharing) — this Mac silently
maintains its own Bluetooth relationship with the AirPods even when audio is
routed elsewhere, and `system_profiler` surfaces its last-known state.

**Rejected approach:** parsing Apple's Continuity/Proximity Pairing BLE
advertisement (type 0x07) directly via CoreBluetooth, decrypting/decoding the
proprietary broadcast format documented by third-party reverse-engineering
projects (furiousMAC/continuity, librepods). Rejected per the principle now
recorded in [`CLAUDE.md`](../../../CLAUDE.md): prefer an official tool over a
reverse-engineered protocol when the official tool already exposes the same
data with far less risk and complexity.

## 2. Architecture

New `AirPodsBatterySource: BatteryDataSource`, in
`Sources/IBatteryCore/DataSources/AirPodsBattery.swift`, registered in
`Sources/ibattery-mcp/main.swift` alongside the four existing sources.

- Runs `/usr/sbin/system_profiler SPBluetoothDataType -json` via a subprocess
  helper with the same watchdog-timeout safety guarantee every other external
  process call in this codebase already has.
- **Refactor (serves this task directly):** generalize
  `IDeviceBattery.swift`'s `runLibimobiledeviceTool(_:_:timeoutSeconds:)` —
  currently named for its one caller — into a command-agnostic
  `runSubprocess(_:_:timeoutSeconds:)`, moved to its own file
  `Sources/IBatteryCore/DataSources/Subprocess.swift`. `IDeviceBatterySource`,
  `WatchBatterySource` (both already call it for `idevice_id`/`ideviceinfo`),
  and the new `AirPodsBatterySource` all use the same shared helper. Pure
  rename + move; no behavior change to the existing two call sites.
- Empirically measured `system_profiler SPBluetoothDataType -json` latency on
  the real dev machine: 60–112ms across three runs. The existing 5-second
  default timeout is kept as a safety ceiling, not a tuned expectation.

## 3. Parsing

`system_profiler SPBluetoothDataType -json` output shape (confirmed against
real output):

```json
{
  "SPBluetoothDataType": [
    {
      "controller_properties": { "...": "..." },
      "device_connected": [ /* same per-device shape as below; may be absent */ ],
      "device_not_connected": [
        {
          "Someone's AirPods4": {
            "device_address": "AA:BB:CC:DD:EE:FF",
            "device_batteryLevelCase": "51%",
            "device_batteryLevelLeft": "100%",
            "device_batteryLevelRight": "100%",
            "device_vendorID": "0x004C",
            "...": "..."
          }
        }
      ]
    }
  ]
}
```

Each device entry is a single-key dictionary: the key is the display name,
the value is the info dictionary. Parsing logic:

1. Decode top-level JSON, take `SPBluetoothDataType[0]` (a fixed singleton
   array — same assumption AirBattery's own code makes).
2. Concatenate `device_connected` and `device_not_connected` (either may be
   absent — treat as empty), so a device's last-known battery is picked up
   regardless of current connection state.
3. For each device entry: extract the display name and info dict. Skip
   unless `device_vendorID == "0x004C"`, `device_address` is present, **and**
   at least one of `device_batteryLevelLeft` / `device_batteryLevelRight` /
   `device_batteryLevelCase` is present. (Filtering by field presence, not by
   matching "AirPods" in the name, so Beats and other same-chipset earbuds
   are naturally covered without extra special-casing. `device_address` is
   required because it's the only stable identifier available for the `id`
   field in step 5 — an entry with battery fields but no address is treated
   as absent/skipped, same as any other malformed shape.)
4. Parse each present battery field: strip whitespace and a trailing `%`,
   parse as `Int` (e.g. `"51%"` → `51`). A field that fails to parse as an
   integer is treated as absent (no entry emitted for that component) rather
   than crashing or defaulting to 0.
5. Emit one `DeviceBatteryInfo` per present battery field (up to three:
   Left, Right, Case) — no merging, per the approved design:
   - `id`: `"<device_address>-left"` / `"-right"` / `"-case"` (address
     lowercased, hyphen-joined).
   - `name`: `"<display name> (Left)"` / `"(Right)"` / `"(Case)"` — plain
     text suffixes, not AirBattery's own 🄻/🅁 glyphs, since this is a
     tool-call return value read by an LLM, not a menu-bar UI read by a
     human.
   - `kind`: new `DeviceBatteryInfo.Kind` case `.airpods`.
   - `percentage`: the parsed integer.
   - `isCharging`: **`nil`**, not `false`. `system_profiler` does not report
     a charging flag for these fields at all (AirBattery's own code hardcodes
     `isCharging: 0`/false here, which asserts something it doesn't actually
     know). `DeviceBatteryInfo.isCharging` is already `Bool?` and
     `BLEBatterySource` already uses `nil` for the identical
     data-source-doesn't-report-this situation — this reuses that existing,
     tested precedent.
   - `lastUpdated`: `Date()` (current time — `system_profiler` doesn't
     expose a last-changed timestamp; matches how every other source in this
     codebase stamps its own fetch time).

## 4. Error handling

- `system_profiler` missing or erroring (exit code ≠ 0): return `[]`. Unlike
  libimobiledevice, `system_profiler` ships with every macOS install — there
  is no "install this dependency" remediation to surface, so no dedicated
  status-warning path (the `bleHelperStatusWarning`/`iDeviceStatusWarning`
  pattern) is added for this source. A silent empty result on failure matches
  how `WatchBatterySource`'s timeout path already behaves.
- Malformed/unexpected JSON shape at any level: treated as "no devices found"
  (empty result), never a crash.

## 5. Testing

- Pure parsing function(s) (JSON string/dict in, `[DeviceBatteryInfo]` out)
  are unit-testable without spawning a subprocess, matching the existing
  pattern (`parseDeviceIdList`, `parseBatteryPlist`, etc.).
- Test fixtures are built from the real JSON captured during design, but
  with the real MAC address and serial numbers replaced by obviously-fake
  placeholders (e.g. `AA:BB:CC:DD:EE:FF`, `FAKESERIAL0001`) before being
  committed — the real values must not end up in the public repo.
- Cases to cover: all three fields present; only Case present (pods not
  found, case nearby); non-Apple vendor ID with the same field names absent
  (should be skipped); malformed percentage string; empty/missing
  `device_connected` and/or `device_not_connected` keys; empty top-level
  array.

## 6. Documentation

- README (`README.md`/`README_zh.md`) status table: AirPods row moves from
  "🚧 Not implemented yet" to the same "⚠️ Implemented, unit-tested — not yet
  confirmed against real hardware" wording used for the other sources before
  their own hardware verification — this feature has not yet been run
  end-to-end via the real MCP server (only the underlying `system_profiler`
  mechanism has been manually verified during design). Hardware verification
  of the shipped code happens the same way it did for iPhone/Watch: run the
  real server against the real AirPods before upgrading the wording to
  "✅ Verified".
- `CLAUDE.md`'s official-tool-over-reverse-engineering principle (already
  committed) is the durable record of why this approach was chosen over BLE
  advertisement parsing — no separate rationale doc needed.

## 7a. Addendum: `lastUpdatedLocal` field (added after initial approval)

`system_profiler` reports a cached battery level with no timestamp of its
own — a value could be minutes or days old, and the JSON gave no way for a
caller to know without separately knowing the user's timezone to interpret
the existing UTC `lastUpdated` field. Per explicit follow-up request:
`DeviceBatteryInfo` gains a `lastUpdatedLocal: String` field — an ISO8601
timestamp of `lastUpdated` expressed in this machine's local UTC offset
(`TimeZone.current`), always derived from `lastUpdated` and never trusted
from decoded JSON. This applies to every device kind, not just AirPods,
since `DeviceBatteryInfo` is shared. See the implementation plan for the
exact `Codable` approach (needed to keep decoding old JSON payloads, e.g.
the BLE-helper IPC fixture, working without the new key).

## 7. Out of scope (for this feature)

- AirPods Max (single combined battery via `device_batteryLevelMain`,
  distinct shape from the Left/Right/Case fields here) — untested, no
  hardware available; would need its own follow-up if ever requested.
- LAN multi-Mac support — separate feature, separate design cycle (already
  agreed with the user).
