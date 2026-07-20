# ibattery-mcp — Engineering Principles

## Official tools first; plaintext-broadcast parsing only to fill data gaps

Three tiers, in order:

1. **Official first.** When a data source needs to talk to Apple hardware
   or software and an already-vetted official tool or library exposes the
   needed data, use it — never reimplement protocol-level, pairing, or
   cryptographic work. Established examples:
   - iPhone/iPad battery: `idevice_id` / `ideviceinfo` — libimobiledevice's
     public CLI tools.
   - Apple Watch battery: `companion_proxy` — libimobiledevice's public,
     documented C API.
   - AirPods cached battery levels: `system_profiler SPBluetoothDataType
     -json` — Apple's own system tool.

2. **Plaintext-broadcast parsing — permitted only as a supplement.** When
   the official path *cannot provide a specific piece of data at all*,
   parsing plaintext broadcast payloads (e.g. BLE advertisements) is
   allowed. The design doc must name the exact data gap that justifies the
   exception, and the official path stays as the fallback wherever it does
   have the data. Approved cases (see
   `docs/superpowers/specs/2026-07-20-ble-advertisement-design.md`):
   - AirPods per-bud in-case status, true charging state, and real-time
     levels — none exposed by `system_profiler` (which serves cached levels
     only, no charging field, no in-case data) → plaintext Proximity
     Pairing advertisement parsing, with `system_profiler` as fallback.
   - iPhone/iPad battery while the phone is locked — lockdownd/WiFi-sync is
     unreachable then. Note the shape of this precedent: the battery data
     itself is read via the Bluetooth SIG standard GATT Battery Service
     (an official, documented protocol); the only Apple-proprietary input
     is one plaintext manufacturer-data type byte used to identify nearby
     iOS devices. Cite it accurately — it is not a blanket license for
     proprietary-payload parsing.

3. **Still banned.** Implementing decryption of any protocol, using private
   frameworks, or hand-rolling undocumented pairing/crypto handshakes —
   even when third parties document them well. If a design seems to require
   any of these, look harder for an official tool, or for a plaintext
   supplement that qualifies under tier 2.

Our own code should only ever be "call the tool/API, then parse its
output" (tier 1) or "receive broadcast bytes, then parse them" (tier 2).
