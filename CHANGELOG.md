# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- MCP server (`ibattery-mcp`) exposing three tools: `get_all_devices_status`,
  `get_device_battery`, `list_known_devices`.
- Mac's own battery via IOKit. **Implemented and unit-tested, but not yet
  verified against real hardware** — see the project README's Status section.
- Generic Bluetooth devices exposing the standard GATT Battery Service, via a
  separate persistent helper app (`ibattery-ble-helper`) that owns all
  CoreBluetooth access (required due to macOS TCC responsible-process rules —
  see the design doc for why a plain MCP subprocess can't touch CoreBluetooth
  directly). **Implemented and unit-tested, but not yet verified against real
  hardware** — see the project README's Status section.
- iPhone/iPad battery via `libimobiledevice` CLI tools. **Verified against a
  real device.**
- Apple Watch battery via `libimobiledevice`'s `companion_proxy` API, reached
  through an already-connected iPhone. **Verified against real hardware.**

### Fixed
- Apple Watch battery reading failed against real hardware in two ways: (1)
  a `companion_proxy` client was reused across requests, but the service
  closes its connection after every reply, so the second and later requests
  failed with `COMPANION_PROXY_E_SSL_ERROR`; (2)
  `companion_proxy_get_value_from_registry` returns the requested value
  wrapped in a one-entry dict keyed by the request key, not as a bare scalar,
  so the capacity value was silently misread as 0. Both are fixed.

### Known limitations
- AirPods (and Apple's proprietary Continuity BLE protocol generally) are not
  yet supported — planned for a future release once independently verified
  against real hardware.
- Querying another Mac's devices over the local network (LAN multi-Mac) is not
  yet implemented.