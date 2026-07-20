# BLE Advertisement Parsing (AirPods in-case status + iPhone over BT) — Design Doc

Date: 2026-07-20
Status: Approved (brainstorming phase)

## 1. Overview and decision change

Two new capabilities, both hosted inside the existing `ibattery-ble-helper`:

1. **AirPods advertisement parsing** — parse the plaintext Proximity Pairing
   BLE advertisements AirPods broadcast, yielding real-time battery levels, a
   *true* charging flag (today's `system_profiler` path always reports
   `isCharging: null`), and — the headline feature — **per-bud in-case
   status**, which no official tool exposes at all.
2. **iPhone/iPad over BT** — use Apple manufacturer advertisement data only
   to *identify* nearby iOS devices, then connect and read the **Bluetooth
   SIG standard GATT Battery Service (180F/2A19)** — an official, documented
   protocol. This provides battery for a locked iPhone, which the
   libimobiledevice/WiFi-sync path cannot reach (verified empirically
   2026-07-20: `idevice_id -l`/`-n` both return nothing once the phone
   locks, so the iPhone and Watch silently vanish from tool results).

**This partially reverses the decision recorded in
[2026-07-20-airpods-battery-design.md](./2026-07-20-airpods-battery-design.md)
§1 ("Rejected approach")** and amends the `CLAUDE.md` engineering principle
accordingly (see §8). The data gaps that justify the reversal, per the
amended principle's requirement to name them explicitly:

| Data gap | Official path status |
|---|---|
| Per-bud in-case status | Not exposed by any official tool |
| AirPods charging state | Not exposed (`system_profiler` has no charging field) |
| Real-time (non-cached) AirPods levels | `system_profiler` serves cached values only |
| iPhone/Watch battery while phone is locked | lockdownd unreachable when locked |

**Prior art and clean-room status:** byte-layout knowledge comes from
AirBattery's published source comments (`AirBattery/BatteryInfo/
BLEBattery.swift`, read as protocol documentation) and the furiousMAC
`continuity` research project. No AirBattery code is reused; all parsing is
implemented fresh against the documented byte layout, consistent with the
clean-room stance in the
[main design doc](./2026-07-19-ibattery-mcp-design.md).

## 2. Architecture

```
                 ibattery-ble-helper (persistent .app, existing)
┌────────────────────────────────────────────────────────────────┐
│ existing: BLEBatteryScanner        (on-demand 180F scan)       │
│ existing: BLEBluetoothStatusChecker(status check)              │
│                                                                │
│ new: BLEAdvertisementMonitor (persistent, own CBCentralManager)│
│  ├─ periodic passive scan: 15s at startup, then 5s every 30s   │
│  │    scanForPeripherals(withServices: nil)                    │
│  ├─ Apple manufacturer data (company ID 0x004C) routing:       │
│  │    ├─ 29-byte, type 0x07 → AirPods "open" msg → parse+cache │
│  │    ├─ 25-byte, type 0x12 → AirPods "close" msg → parse+cache│
│  │    └─ type 0x10 or 0x0c  → iOS-device candidate → remember  │
│  └─ in-memory cache: latest parsed state per device display    │
│       name + last-seen timestamp                               │
└────────────────────────────────────────────────────────────────┘
               ▲ Unix socket (existing IPC, one new request)
               │   "scan"     → unchanged (generic BLE devices)
               │   "status"   → unchanged
               │   "snapshot" → new: cached AirPods state
               │                + on-demand GATT reads of iOS
               │                  candidates
┌──────────────┴─────────────────────────────────────────────────┐
│ ibattery-mcp (stdio, stateless)                                │
│  AirPodsBatterySource: BLE snapshot preferred,                 │
│                        system_profiler fallback (§4 merge)     │
│  IDeviceBatterySource: libimobiledevice preferred,             │
│                        BLE-GATT supplement (§5 dedup)          │
└────────────────────────────────────────────────────────────────┘
```

- `BLEAdvertisementMonitor` lives in `Sources/IBatteryCore/DataSources/`
  (parsing logic as pure, unit-testable functions) but is only instantiated
  inside the helper process — the same placement pattern as
  `BLEBatteryScanner`. It owns a dedicated long-lived `CBCentralManager`;
  the existing on-demand scanners keep creating their own per-request
  managers, and the instances do not interfere.
- **IPC grows exactly one request, `"snapshot"`.** `"scan"` and `"status"`
  are untouched. The response is the existing `[DeviceBatteryInfo]` wire
  shape, with the new optional fields of §4. Version-skew behavior is
  graceful in both directions (§6).
- **GATT reads happen only at snapshot time**, not during periodic scans —
  the monitor merely remembers which nearby peripherals look like iOS
  devices; connecting/reading is deferred until an MCP request actually
  asks, so the helper never repeatedly wakes phones on its own.

## 3. AirPods advertisement parsing

All multi-byte references are indices into the manufacturer-data payload
(`CBAdvertisementDataManufacturerDataKey`), which starts with the little-
endian company ID `4c 00`.

**"Open" message** (29 bytes, `data[2] == 0x07`; broadcast continuously
while the lid is open or buds are in use):

- `data[5..6]`: model ID (little-endian pairs, e.g. `0x2214` = AirPods
  Pro 2) — used only for display/model classification, never as a gate.
- `data[7]` low nibble: coarse in-case state — `5` = both buds in case,
  `1` = at least one bud out.
- `data[7]` high nibble bit `0x02` (AirBattery's "flip" bit): when unset,
  the left/right battery byte positions below are swapped.
- `data[14]` / `data[15]` (subject to flip): left / right bud battery byte.
- `data[16]`: case battery byte.
- Battery byte encoding (shared): `0xff` = component absent/unreachable;
  otherwise bit 7 = charging flag, low 7 bits = percentage
  (e.g. `0x85` = charging, 5%; `0x40` = not charging, 64%).

**"Close" message** (25 bytes, `data[2] == 0x12`; broadcast briefly by the
case at the moment the lid closes):

- `data[4]`: exact per-bud state — `0x2e` = both in case, `0x2c` = only
  left taken out, `0x26` = only right taken out, `0x24` = both out.
- `data[12]`: case battery byte; `data[13]` / `data[14]`: left / right
  battery bytes (same encoding as above).

**In-case confidence rules** (populate the `inCase` field; never guess):

| Evidence | Conclusion | Confidence |
|---|---|---|
| Last message is "close": `data[4]` decoded | Exact per-bud in-case | Certain |
| Last message is "open", nibble = `5` | Both buds in case | Certain |
| Last message is "open", nibble = `1`, bud's charging bit set | That bud in case | Certain |
| Last message is "open", nibble = `1`, bud not charging | Unknown (may be out; may be full and idle in case) | `null` |

`lidOpen` on the case entry derives from the type of the most recent
message seen ("open" → `true`, "close" → `false`).

A bud byte of `0xff` (unreachable) omits that component from the BLE-derived
result; the merge in §4 then falls back to `system_profiler`'s cached value
for that component, mirroring AirBattery's own fallback structure.

## 4. `DeviceBatteryInfo` field additions and merge strategy

New optional fields, meaningful only on `.airpods` entries and omitted from
JSON when `nil` (same `Codable` backward-compatibility approach as
`lastUpdatedLocal` — old payloads without the keys must keep decoding):

- `inCase: Bool?` — left/right bud entries, per the confidence rules above.
- `lidOpen: Bool?` — case entry only.
- `isCharging` on AirPods entries now carries the real advertisement-derived
  value whenever BLE data is present (previously always `nil` on this path).

**Merge (AirPodsBatterySource):** merge key is the device display name,
which is identical on both paths (BLE `peripheral.name` vs
`system_profiler`'s entry key — AirPods' BLE MAC is randomized, so the name
is the only stable cross-path key). Per component (left/right/case):

1. BLE cache has a fresher value → use BLE values (level, charging,
   inCase/lidOpen); `lastUpdated` = advertisement last-seen time.
2. BLE silent (e.g. lid closed a while ago — AirPods stop advertising) →
   `system_profiler` cached level, `isCharging: nil`, but `inCase`/`lidOpen`
   retain the monitor's last-known state with the honest last-seen
   timestamp; the registry's existing `stale` mechanism applies unchanged.
3. `id` keeps the `system_profiler` MAC-derived form
   (`<address>-left/-right/-case`) when available, since it is stable;
   BLE-only devices (never seen by `system_profiler`) fall back to
   CoreBluetooth peripheral UUID.

## 5. iPhone/iPad over BT

- **Identify:** manufacturer data company ID `0x004C` and `data[2] ∈
  {0x10, 0x0c}` and `peripheral.name` present. The type byte is the *only*
  Apple-proprietary input, used purely as a "this nearby peripheral is an
  iOS device" filter.
- **Read (snapshot time):** connect → discover `180F` (Battery) + `180A`
  (Device Information) → read `2A19` (battery level), `2A24` (model
  number), `2A29` (vendor). All standard Bluetooth SIG services.
- **Watch exclusion:** model string from `2A24` containing `"Watch"` is
  skipped (mirrors AirBattery; Watch GATT battery is not reliable). A
  locked-phone scenario therefore still loses the Watch — known limitation,
  documented in README.
- **Timeouts:** 5s per device, 10s total for the snapshot request.
- **Emitted entry:** `kind: .iosDevice`, `id: "ble-" + peripheral UUID`,
  `isCharging: nil` (2A19 carries no charging bit), `percentage` from 2A19.
- **Dedup vs libimobiledevice:** merge key is device name (lockdownd
  `DeviceName` and BLE GAP name match for the same phone). When both paths
  return the same name, the libimobiledevice entry wins outright (exact
  percentage + real charging flag); the BLE entry is only used when the
  official path returned nothing — i.e. precisely the locked-phone case.
- **Real-hardware caveat (must verify before "✅ Verified"):** whether the
  GATT read succeeds against a *locked* phone (and whether it requires the
  same-iCloud bonding relationship) is empirically unconfirmed for our
  implementation. On any failure the entry is simply absent and behavior
  degrades to today's.

## 6. Error handling

Guiding rule: every new-path failure degrades to exactly today's behavior.

- Bluetooth off / permission missing → monitor idles and resumes on state
  change; the existing `"status"` warning strings continue to cover user
  remediation.
- Malformed/short/wrong-type advertisement → packet dropped, no parse, no
  crash.
- `snapshot` before the first scan completes → empty array; MCP side falls
  back to `system_profiler` / libimobiledevice, output identical to today.
- GATT failures (connect timeout, authentication rejected while locked,
  service absent) → that device omitted from the snapshot.
- **Version skew:** an old helper receiving `"snapshot"` executes its
  existing "anything not `status` is a scan" branch and returns generic-BLE
  entries — the MCP merge finds no `.airpods`/`.iosDevice` entries in it and
  falls back normally, while the registry's id-based dedup absorbs the
  duplicate generic entries. A new helper with an old MCP client only ever
  receives `"scan"`/`"status"`, both unchanged.

## 7. Testing

- Pure-function unit tests (no CoreBluetooth), extending the established
  fixture pattern:
  - open/close message parsing: model IDs, flip-bit byte swap, charging
    bits, `0xff` sentinels, malformed/truncated data, non-Apple company ID,
    type-byte routing (0x07/0x12/0x10/0x0c).
  - the in-case confidence table in §3, row by row — especially
    "cannot conclude → `null`".
  - merge strategy (§4): BLE-fresh vs profiler-fallback per component, name
    keying, id stability, timestamp/stale propagation.
  - iOS-candidate filter + Watch exclusion (§5).
  - IPC round-trip with new optional fields, and decoding old JSON without
    them.
- CoreBluetooth delegate layers stay thin and unit-untested, same as
  `BLEBatteryScanner` today. README rows stay at "⚠️ Implemented,
  unit-tested" until real-hardware verification (locked-iPhone GATT read,
  real lid-close capture) upgrades them.
- Synthesized hex fixtures only — no real MAC addresses or serials in the
  repo (existing fixture policy).

## 8. `CLAUDE.md` principle amendment

The absolute ban is replaced by a three-tier rule (committed together with
this doc):

1. **Official first, unchanged:** when an official tool/API exposes the
   needed data, use it — never reimplement.
2. **Plaintext-broadcast parsing, newly permitted as a supplement only:**
   when the official path *cannot provide a specific piece of data at all*,
   parsing plaintext broadcast payloads is allowed. The design doc must name
   the exact data gap (this doc's §1 table is the required example), and the
   official path remains the fallback wherever it does have data.
3. **Still banned:** implementing decryption, private frameworks, or
   undocumented pairing/crypto handshakes ourselves.

The AirPods example in `CLAUDE.md` is rewritten to record `system_profiler`
as fallback + plaintext advertisement parsing as the approved supplement,
and the iPhone-over-BT example spells out that battery data itself travels
over the official GATT Battery Service with only one plaintext type byte of
Apple-proprietary input — so the precedent is cited accurately, not as a
blanket license.

## 9. Documentation

- README/README_zh status table: AirPods row gains in-case status wording;
  iPhone/iPad row notes locked-phone support via BT; both marked
  "⚠️ Implemented, unit-tested" until hardware verification.
- CHANGELOG entry.
- This doc is the durable record of the decision reversal.

## 10. Out of scope

- **In-ear detection** (worn-in-ear vs merely out-of-case): further status
  bits exist per furiousMAC research but are not covered by AirBattery's
  verified analysis; revisit only after real-hardware capture.
- **AirPods Max / single-battery models** via advertisement — consistent
  with the prior AirPods doc's exclusion.
- **Apple Watch over BT** (excluded in §5; Watch battery still requires the
  unlocked-iPhone path).
- **LAN multi-Mac** — stays rejected per
  [2026-07-20-lan-multi-mac-design.md](./2026-07-20-lan-multi-mac-design.md).
- **Any decryption or private-framework use** — banned by the amended
  principle.
