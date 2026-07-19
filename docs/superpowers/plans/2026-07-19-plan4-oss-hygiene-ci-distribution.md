# ibattery-mcp Plan 4: Open-Source Hygiene, CI, and Homebrew Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `ibattery-mcp` up to standard open-source project hygiene — license, bilingual README, contribution docs, issue/PR templates, automated CI, and a Homebrew tap formula — so it's ready to be made public and installed by others.

**Architecture:** Pure documentation/config-file work plus two GitHub Actions workflows (CI on push/PR, release automation on tag) and a Homebrew formula in a new companion tap repository. No changes to `Sources/`/`Tests/` in this plan.

**Tech Stack:** Markdown, GitHub Actions YAML, Ruby (Homebrew formula DSL), SwiftLint.

## Global Constraints

- Repo: `China-Drummond/ibattery-mcp` on GitHub, currently **private**. This plan does not change its visibility — that's an explicit, separate decision the user will make after reviewing this plan's output, not something any task in this plan should do.
- License: **MIT**, copyright holder **Domo**, year **2026** (per the design doc's licensing decision from brainstorming — clean-room code, no AGPL inheritance from AirBattery).
- Security contact: **GitHub Security Advisories** ("Report a vulnerability" button under the repo's Security tab) — no public email address is used anywhere in this plan's files.
- Documentation language: **English is the default/primary language everywhere** (README.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md, CHANGELOG.md, issue/PR templates, code comments). **Chinese is a secondary, explicitly-linked translation** — only `README_zh.md` gets one in this plan (matching the project's original bilingual-docs requirement from brainstorming); other docs are English-only for now, translatable later if requested.
- Lint: **SwiftLint** is added to this project (a `.swiftlint.yml` config plus a CI step) — this plan adds its baseline config and CI gate but does not attempt to make 100% of the existing codebase pass a strict ruleset; use SwiftLint's default/recommended rule set and fix any violations it flags in the *existing* codebase as part of this plan's CI task (so CI starts green), rather than disabling rules to force a pass.
- **This plan must accurately reflect the current, real feature/verification status of the project** — do not write marketing copy that overstates what's confirmed working. Specifically:
  - Mac battery (IOKit), generic BLE Battery Service devices (via the `ibattery-ble-helper` companion app), and iPhone/iPad battery (via `libimobiledevice`) are implemented, unit-tested, and have each had at least some manual verification against real hardware/tools during their respective plans.
  - Apple Watch battery (via `companion_proxy`) is implemented and unit-tested, but **has never been exercised against real hardware** (documented explicitly in Plan 3's final review) — the README/CHANGELOG must say this plainly (e.g., "implemented, pending real-hardware verification"), not present it as a fully proven feature.
  - **AirPods (and the wider Apple Continuity BLE protocol) are not implemented at all** — explicitly out of scope for Plans 1-3, deferred to its own future research-first plan per the design doc. The README must list this as a roadmap item, not imply it works.
  - LAN multi-Mac companion functionality is not implemented — also a roadmap item.
- Distribution model (from the design doc, confirmed during Plan 1 brainstorming): Homebrew formula **builds from source** on the user's machine (standard pattern for OSS CLI formulas) — no code signing/notarization pipeline is needed for the `ibattery-mcp`/`ibattery-ble-helper` binaries themselves. The formula's own `depends_on` list must include, per the empirically-verified facts from Plans 2 and 3:
  - `depends_on "libimobiledevice"` (runtime: provides `idevice_id`/`ideviceinfo` CLI tools used by `IDeviceBatterySource`/`WatchBatterySource`; also build-time: provides the headers/dylib the `CLibimobiledevice` SwiftPM system-library target links against).
  - `depends_on "pkg-config" => :build` (build-time only: required to resolve `CLibimobiledevice`'s `pkgConfig` target).
  - `depends_on :xcode` (Homebrew's standard way to require a working Swift toolchain for `swift build`).
- The `ibattery-ble-helper.app` bundle (built by the existing `Scripts/build-ble-helper-app.sh`) needs to be installed *somewhere* by the formula and be launchable by the user — Homebrew formulas conventionally install non-CLI app bundles under `libexec` or the formula's own `prefix`, with a `caveats` message telling the user how to launch it (`open`), since Homebrew does not auto-register `.app` bundles as Launch-Services-visible applications the way a `/Applications`-installed app would be.

---

### Task 1: Legal/policy baseline — `LICENSE`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CHANGELOG.md`

**Files:**
- Create: `LICENSE`
- Create: `CODE_OF_CONDUCT.md`
- Create: `SECURITY.md`
- Create: `CHANGELOG.md`

- [ ] **Step 1: Add the MIT license**

```text
MIT License

Copyright (c) 2026 Domo

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Save as `LICENSE` at the repo root (no file extension).

- [ ] **Step 2: Add a Code of Conduct**

Use the standard Contributor Covenant v2.1 (the most widely adopted OSS code of conduct — using the canonical text rather than a custom one is itself the convention):

```markdown
# Contributor Covenant Code of Conduct

## Our Pledge

We as members, contributors, and leaders pledge to make participation in our
community a harassment-free experience for everyone, regardless of age, body
size, visible or invisible disability, ethnicity, sex characteristics, gender
identity and expression, level of experience, education, socio-economic status,
nationality, personal appearance, race, religion, or sexual identity
and orientation.

We pledge to act and interact in ways that contribute to an open, welcoming,
diverse, inclusive, and healthy community.

## Our Standards

Examples of behavior that contributes to a positive environment for our
community include:

* Demonstrating empathy and kindness toward other people
* Being respectful of differing opinions, viewpoints, and experiences
* Giving and gracefully accepting constructive feedback
* Accepting responsibility and apologizing to those affected by our mistakes,
  and learning from the experience
* Focusing on what is best not just for us as individuals, but for the
  overall community

Examples of unacceptable behavior include:

* The use of sexualized language or imagery, and sexual attention or
  advances of any kind
* Trolling, insulting or derogatory comments, and personal or political attacks
* Public or private harassment
* Publishing others' private information, such as a physical or email
  address, without their explicit permission
* Other conduct which could reasonably be considered inappropriate in a
  professional setting

## Enforcement Responsibilities

Community leaders are responsible for clarifying and enforcing our standards of
acceptable behavior and will take appropriate and fair corrective action in
response to any behavior that they deem inappropriate, threatening, offensive,
or harmful.

## Scope

This Code of Conduct applies within all community spaces, and also applies when
an individual is officially representing the community in public spaces.

## Enforcement

Instances of abusive, harassing, or otherwise unacceptable behavior may be
reported to the community leaders responsible for enforcement via a private
report on the repository (see `SECURITY.md` for how to reach maintainers
privately; for non-security conduct issues, open a GitHub issue or contact a
maintainer directly). All complaints will be reviewed and investigated promptly
and fairly.

All community leaders are obligated to respect the privacy and security of the
reporter of any incident.

## Attribution

This Code of Conduct is adapted from the [Contributor Covenant][homepage],
version 2.1, available at
[https://www.contributor-covenant.org/version/2/1/code_of_conduct.html][v2.1].

[homepage]: https://www.contributor-covenant.org
[v2.1]: https://www.contributor-covenant.org/version/2/1/code_of_conduct.html
```

Save as `CODE_OF_CONDUCT.md`.

- [ ] **Step 3: Add a security policy**

```markdown
# Security Policy

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Instead, use GitHub's private vulnerability reporting: go to the
[Security tab](../../security) of this repository and click **"Report a
vulnerability"**. This opens a private advisory visible only to you and the
maintainers, where you can describe the issue and, if applicable, propose a fix.

We'll acknowledge new reports as quickly as we can and keep you updated as we
work through the issue.

## Supported Versions

`ibattery-mcp` is pre-1.0 and does not yet have a formal long-term-support
policy. Security fixes are applied to the latest released version; please
make sure you're running the latest release before reporting an issue that
might already be fixed.

## Scope Notes

`ibattery-mcp` shells out to and links against external tools/libraries
(`libimobiledevice`) and runs a local, unauthenticated Unix-domain-socket IPC
channel between its two processes (`ibattery-mcp` and `ibattery-ble-helper`),
scoped to the current user's local filesystem permissions. If you find a way
to exploit this local IPC channel from another local user/process in a way
that shouldn't be possible, that's exactly the kind of report we want — please
report it privately as described above.
```

Save as `SECURITY.md`.

- [ ] **Step 4: Add a changelog**

```markdown
# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- MCP server (`ibattery-mcp`) exposing three tools: `get_all_devices_status`,
  `get_device_battery`, `list_known_devices`.
- Mac's own battery via IOKit.
- Generic Bluetooth devices exposing the standard GATT Battery Service, via a
  separate persistent helper app (`ibattery-ble-helper`) that owns all
  CoreBluetooth access (required due to macOS TCC responsible-process rules —
  see the design doc for why a plain MCP subprocess can't touch CoreBluetooth
  directly).
- iPhone/iPad battery via `libimobiledevice` CLI tools.
- Apple Watch battery via `libimobiledevice`'s `companion_proxy` API, reached
  through an already-connected iPhone. **Implemented and unit-tested, but not
  yet verified against real hardware** — see the project README's Status
  section.

### Known limitations
- AirPods (and Apple's proprietary Continuity BLE protocol generally) are not
  yet supported — planned for a future release once independently verified
  against real hardware.
- Querying another Mac's devices over the local network (LAN multi-Mac) is not
  yet implemented.
```

Save as `CHANGELOG.md`.

- [ ] **Step 5: Commit**

```bash
git add LICENSE CODE_OF_CONDUCT.md SECURITY.md CHANGELOG.md
git commit -m "Add LICENSE, Code of Conduct, security policy, and changelog"
```

---

### Task 2: README (English default + Chinese translation)

**Files:**
- Create: `README.md`
- Create: `README_zh.md`

- [ ] **Step 1: Write the English README**

```markdown
# ibattery-mcp

An [MCP](https://modelcontextprotocol.io) (Model Context Protocol) server that
exposes battery and charging status for your Apple devices — this Mac, nearby
Bluetooth accessories, your iPhone/iPad, and your Apple Watch — as tools an AI
assistant (Claude Code, Claude Desktop, [Work Buddy](https://docs.work-buddy.ai/),
or any other MCP client) can call.

[中文版本](./README_zh.md)

## Status

| Device | Status |
|---|---|
| This Mac's own battery | ✅ Implemented, verified |
| Generic Bluetooth devices (standard Battery Service — most Bluetooth mice/keyboards) | ✅ Implemented, verified |
| iPhone / iPad | ✅ Implemented, verified |
| Apple Watch (via a paired iPhone) | ⚠️ Implemented, unit-tested, **not yet verified against real hardware** |
| AirPods | 🚧 Not implemented yet (planned) |
| Another Mac on the same network | 🚧 Not implemented yet (planned) |

This project is pre-1.0 and under active development. See
[CHANGELOG.md](./CHANGELOG.md) for details.

## Why a separate helper app for Bluetooth?

macOS attributes CoreBluetooth's privacy (TCC) check to the *responsible
process*, not to whichever binary actually calls the API. An MCP server is,
by construction, a subprocess spawned directly by its host (Claude Code,
Claude Desktop, etc.) — never launched via macOS LaunchServices (`open`). That
means a bare MCP server can never itself be its own "responsible process" for
Bluetooth access, and will be killed by the OS the instant it tries. `ibattery-mcp`
works around this the same way a normal Mac app would: a small companion app,
`ibattery-ble-helper`, owns all Bluetooth access and is launched normally
(`open`, or as a login item); the stateless MCP server talks to it over a
local Unix domain socket. See the [design doc](./docs/superpowers/specs/2026-07-19-ibattery-mcp-design.md)
for the full story, including how this was discovered.

## Installation

### Prerequisites

- macOS 13 (Ventura) or later
- [Homebrew](https://brew.sh)

### Install

```bash
brew install China-Drummond/tap/ibattery-mcp
```

This also installs `libimobiledevice` and `pkg-config` as dependencies
(needed for iPhone/iPad/Apple Watch support) and builds `ibattery-mcp` from
source on your machine.

### One-time setup for Bluetooth device support

Bluetooth devices (generic BLE accessories) require the companion helper app
to be running:

```bash
open "$(brew --prefix ibattery-mcp)/libexec/ibattery-ble-helper.app"
```

The first launch will prompt for Bluetooth permission — grant it. The helper
app then keeps running in the background; you only need to do this once (or
again after a reboot, unless you set it up as a login item).

### One-time setup for iPhone/iPad/Apple Watch support

Connect your iPhone or iPad to this Mac via USB at least once and tap "Trust"
when prompted. This establishes the pairing libimobiledevice needs; after
that, it can also work over WiFi if you have WiFi sync enabled on the device.

## Configuration

Add `ibattery-mcp` to your MCP host's configuration. For example, for a host
that reads a JSON config with a `command`/`args` shape:

```json
{
  "mcpServers": {
    "ibattery-mcp": {
      "command": "ibattery-mcp"
    }
  }
}
```

## Available tools

- **`get_all_devices_status()`** — battery/status for every device discoverable
  from this Mac right now. The main tool for a "how are my devices doing"
  summary (e.g., a morning briefing).
- **`get_device_battery(query)`** — battery status for one device matching a
  name or type substring (e.g. `"iPhone"`, `"MacBook"`).
- **`list_known_devices()`** — devices seen so far this session, without
  triggering a fresh scan.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for how to set up a development
environment, run the test suite, and submit changes.

## License

[MIT](./LICENSE)

## Acknowledgments

- [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) —
  the official Swift SDK this project's MCP protocol layer is built on.
- [libimobiledevice](https://libimobiledevice.org) — the open-source library
  this project uses (as an external dependency, not bundled) for iPhone/iPad
  and Apple Watch communication.
- [AirBattery](https://github.com/lihaoyun6/AirBattery) — prior art that
  inspired this project. `ibattery-mcp` is an independent, clean-room
  reimplementation (see the [design doc](./docs/superpowers/specs/2026-07-19-ibattery-mcp-design.md)
  for why) and shares no code with it.
```

- [ ] **Step 2: Write the Chinese README**

```markdown
# ibattery-mcp

一个 [MCP](https://modelcontextprotocol.io)（Model Context Protocol）服务器，
把你的苹果设备——这台 Mac、附近的蓝牙外设、iPhone/iPad、Apple Watch——的电量和
充电状态，暴露成 AI 助手（Claude Code、Claude Desktop、[Work Buddy](https://docs.work-buddy.ai/)
或其他任何 MCP 客户端）可以调用的工具。

[English](./README.md)

## 当前状态

| 设备 | 状态 |
|---|---|
| 本机 Mac 电量 | ✅ 已实现，已验证 |
| 通用蓝牙设备（标准 Battery Service，大部分蓝牙鼠标/键盘） | ✅ 已实现，已验证 |
| iPhone / iPad | ✅ 已实现，已验证 |
| Apple Watch（通过配对的 iPhone） | ⚠️ 已实现、有单元测试，**但还没有在真机上验证过** |
| AirPods | 🚧 尚未实现（计划中） |
| 局域网内其他 Mac | 🚧 尚未实现（计划中） |

本项目仍处于 1.0 之前的活跃开发阶段，详见 [CHANGELOG.md](./CHANGELOG.md)。

## 为什么蓝牙功能需要一个单独的辅助 App？

macOS 会把 CoreBluetooth 的隐私（TCC）检查归属到"负责的进程"身上，而不是实际
调用 API 的那个二进制文件。MCP server 本质上就是被宿主（Claude Code、Claude
Desktop 等）直接 fork 出来的子进程——从来不是通过 macOS 的 LaunchServices
（`open`）启动的。这意味着一个裸的 MCP server 永远没法成为自己的"负责进程"，
一碰蓝牙就会被系统杀掉。`ibattery-mcp` 用了跟普通 Mac App 一样的解决办法：一个
小的伴生 App，`ibattery-ble-helper`，专门持有所有蓝牙访问权限，用正常方式启动
（`open`，或设成登录项）；无状态的 MCP server 通过本地 Unix socket 跟它通信。
完整来龙去脉见[设计文档](./docs/superpowers/specs/2026-07-19-ibattery-mcp-design.md)。

## 安装

### 前置条件

- macOS 13 (Ventura) 或更新版本
- [Homebrew](https://brew.sh)

### 安装

```bash
brew install China-Drummond/tap/ibattery-mcp
```

这会同时安装 `libimobiledevice` 和 `pkg-config` 依赖（iPhone/iPad/Apple Watch
支持需要），并在你的机器上从源码构建 `ibattery-mcp`。

### 蓝牙设备支持的一次性设置

蓝牙设备（通用 BLE 外设）需要辅助 App 处于运行状态：

```bash
open "$(brew --prefix ibattery-mcp)/libexec/ibattery-ble-helper.app"
```

第一次启动会弹出蓝牙权限申请，点允许。之后辅助 App 会一直在后台运行，只需要
做一次（重启电脑后需要再开一次，除非你把它设成登录项）。

### iPhone/iPad/Apple Watch 支持的一次性设置

用数据线把 iPhone/iPad 连接到这台 Mac 一次，在弹出的提示上点"信任"。这样就
建立了 libimobiledevice 需要的配对关系；之后如果设备开启了 Wi-Fi 同步，也可以
无线连接。

## 配置

把 `ibattery-mcp` 加到你的 MCP 宿主配置里。比如，对于读取 `command`/`args`
形式 JSON 配置的宿主：

```json
{
  "mcpServers": {
    "ibattery-mcp": {
      "command": "ibattery-mcp"
    }
  }
}
```

## 可用工具

- **`get_all_devices_status()`** —— 一次性返回当前这台 Mac 能发现的所有设备的
  电量/状态。适合做"设备状态总览"（比如晨间简报）的主力工具。
- **`get_device_battery(query)`** —— 查询名字或类型匹配某个关键词的单个设备
  （比如 `"iPhone"`、`"MacBook"`）。
- **`list_known_devices()`** —— 列出本次会话里已经看到过的设备，不触发新的扫描。

## 参与贡献

开发环境搭建、跑测试、提交改动的流程见 [CONTRIBUTING.md](./CONTRIBUTING.md)。

## 许可证

[MIT](./LICENSE)

## 致谢

- [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) ——
  本项目 MCP 协议层基于的官方 Swift SDK。
- [libimobiledevice](https://libimobiledevice.org) —— 本项目用于 iPhone/iPad
  和 Apple Watch 通信的开源库（作为外部依赖使用，未打包捆绑）。
- [AirBattery](https://github.com/lihaoyun6/AirBattery) —— 启发本项目的前驱
  工作。`ibattery-mcp` 是独立的、干净重写的实现（原因见[设计文档](./docs/superpowers/specs/2026-07-19-ibattery-mcp-design.md)），
  与它不共享任何代码。
```

- [ ] **Step 3: Commit**

```bash
git add README.md README_zh.md
git commit -m "Add bilingual README"
```

---

### Task 3: Contribution docs + GitHub issue/PR templates

**Files:**
- Create: `CONTRIBUTING.md`
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`
- Create: `.github/ISSUE_TEMPLATE/feature_request.yml`
- Create: `.github/ISSUE_TEMPLATE/config.yml`
- Create: `.github/pull_request_template.md`

- [ ] **Step 1: Write CONTRIBUTING.md**

```markdown
# Contributing to ibattery-mcp

Thanks for considering a contribution! This project is under active
development — see [CHANGELOG.md](./CHANGELOG.md) for current status and
[README.md](./README.md) for what's implemented vs. planned.

## Development setup

You'll need:

- macOS 13+ with **full Xcode installed** (not just Command Line Tools — the
  test suite needs the full `XCTest` framework, which Command-Line-Tools-only
  installs don't provide). Check with `xcrun --find xctest`; if that errors,
  install Xcode from the App Store.
- [Homebrew](https://brew.sh)
- Build/runtime dependencies:
  ```bash
  brew install libimobiledevice pkg-config
  ```

Clone the repo and build:

```bash
git clone https://github.com/China-Drummond/ibattery-mcp.git
cd ibattery-mcp
swift build
swift test
```

## Project structure

- `Sources/IBatteryCore/` — the shared library: device models, all
  `BatteryDataSource` implementations (`MacBatterySource`, `BLEBatterySource`,
  `IDeviceBatterySource`, `WatchBatterySource`), the `DeviceRegistry`
  aggregator, and the MCP tool-handling code.
- `Sources/ibattery-mcp/` — the thin MCP server executable entry point.
- `Sources/ibattery-ble-helper/` — the separate helper app that owns all
  CoreBluetooth access (see the README's "Why a separate helper app" section
  for why this exists as its own process).
- `Sources/CLibimobiledevice/` — a SwiftPM system-library target exposing
  libimobiledevice's C headers to Swift.
- `Tests/IBatteryCoreTests/` — the test suite.
- `docs/superpowers/specs/` — the design doc.
- `docs/superpowers/plans/` — implementation plans, one per feature area, each
  written *before* the corresponding code and kept as a historical record of
  what was built and why (including empirically-verified facts discovered
  along the way — these are worth reading before touching a given subsystem).

## Testing philosophy

Pure logic (parsing functions, warning-message construction, cache/registry
behavior) is unit tested with synthetic fixtures and runs in CI. Code that
does real I/O against hardware or external processes (Bluetooth scanning,
`idevice_id`/`ideviceinfo` subprocess calls, the `companion_proxy` API) is
**not** unit tested — it can't be, without the real hardware attached — and is
manual-QA-only. If you're changing one of the `BatteryDataSource`
implementations, please note in your PR description what manual testing you
did (and on what hardware), since CI can't verify that part for you.

## Submitting changes

1. Open an issue first for anything beyond a small fix, so we can discuss
   the approach before you put in the work.
2. Keep PRs focused — one logical change per PR.
3. Add tests for any new pure-logic code; note manual hardware testing for
   anything that touches real devices.
4. Make sure `swift test` and `swiftlint` (see `.swiftlint.yml`) both pass
   locally before opening a PR — CI will run both.
5. Follow the existing code style (no forced abbreviations, `guard`-based
   early returns, `defer`-based cleanup for any C resource handles).
```

- [ ] **Step 2: Add the bug report issue template**

```yaml
name: Bug report
description: Something isn't working as expected
labels: ["bug"]
body:
  - type: textarea
    id: description
    attributes:
      label: What happened?
      description: A clear description of the bug.
    validations:
      required: true
  - type: textarea
    id: expected
    attributes:
      label: What did you expect to happen?
    validations:
      required: true
  - type: dropdown
    id: device-type
    attributes:
      label: Which device type is this about, if any?
      options:
        - Not device-specific
        - Mac's own battery
        - Generic Bluetooth device
        - iPhone/iPad
        - Apple Watch
        - Other/unsure
    validations:
      required: true
  - type: input
    id: macos-version
    attributes:
      label: macOS version
      placeholder: "e.g. 15.1"
    validations:
      required: true
  - type: input
    id: ibattery-mcp-version
    attributes:
      label: ibattery-mcp version
      placeholder: "e.g. 0.1.0, or a commit SHA if built from source"
    validations:
      required: true
  - type: textarea
    id: logs
    attributes:
      label: Relevant output/logs
      description: >-
        If applicable, paste any error output, crash reports, or MCP tool
        responses that show the problem.
      render: shell
```

Save as `.github/ISSUE_TEMPLATE/bug_report.yml`.

- [ ] **Step 3: Add the feature request issue template**

```yaml
name: Feature request
description: Suggest an idea for this project
labels: ["enhancement"]
body:
  - type: textarea
    id: problem
    attributes:
      label: What problem would this solve?
    validations:
      required: true
  - type: textarea
    id: solution
    attributes:
      label: What would you like to happen?
    validations:
      required: true
  - type: textarea
    id: alternatives
    attributes:
      label: Alternatives considered
      description: Any alternative solutions or features you've considered.
```

Save as `.github/ISSUE_TEMPLATE/feature_request.yml`.

- [ ] **Step 4: Add issue template config (points to Security Advisories for vulnerabilities)**

```yaml
blank_issues_enabled: true
contact_links:
  - name: Report a security vulnerability
    url: https://github.com/China-Drummond/ibattery-mcp/security/advisories/new
    about: Please do not report security vulnerabilities as public issues — use this private form instead.
```

Save as `.github/ISSUE_TEMPLATE/config.yml`.

- [ ] **Step 5: Add a PR template**

```markdown
## What does this change do?

<!-- Briefly describe the change and why it's needed. -->

## Testing

<!--
- What automated tests did you add/run (`swift test`)?
- If this touches a BatteryDataSource that does real hardware I/O, what
  manual testing did you do, and on what hardware?
-->

## Checklist

- [ ] `swift build` and `swift test` pass locally
- [ ] `swiftlint` passes locally (or violations are explained above)
- [ ] I added tests for any new pure-logic code
- [ ] I noted any manual hardware testing done (or explained why it wasn't possible)
```

Save as `.github/pull_request_template.md`.

- [ ] **Step 6: Commit**

```bash
git add CONTRIBUTING.md .github/ISSUE_TEMPLATE .github/pull_request_template.md
git commit -m "Add CONTRIBUTING guide and issue/PR templates"
```

---

### Task 4: GitHub Actions CI (build, test, lint)

**Files:**
- Create: `.swiftlint.yml`
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Add a SwiftLint config**

```yaml
excluded:
  - .build
  - Sources/CLibimobiledevice
  - docs

disabled_rules:
  - todo

opt_in_rules:
  - empty_count
  - closure_spacing

line_length:
  warning: 160
  error: 200
```

Save as `.swiftlint.yml` at the repo root.

- [ ] **Step 2: Install SwiftLint locally and fix any violations in the existing codebase**

Run: `brew install swiftlint` (if not already installed), then `swiftlint lint --strict`

Expected: this will likely report some violations against the existing code (written across Plans 1-3 without a linter in place). Fix them file-by-file until `swiftlint lint --strict` exits 0 — this is expected, real cleanup work for this step, not optional. Do not disable rules in `.swiftlint.yml` just to make violations disappear; only disable a rule if, after seeing what it flags, the team genuinely disagrees with that rule's premise (unlikely for this project's straightforward code) — prefer fixing the code.

- [ ] **Step 3: Add the CI workflow**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode.app

      - name: Install dependencies
        run: brew install libimobiledevice pkg-config swiftlint

      - name: Lint
        run: swiftlint lint --strict

      - name: Build
        run: swift build

      - name: Test
        run: swift test

      - name: Build BLE helper app bundle
        run: ./Scripts/build-ble-helper-app.sh
```

Save as `.github/workflows/ci.yml`.

- [ ] **Step 4: Verify the workflow syntax and push to trigger a real run**

Run: `git add .swiftlint.yml .github/workflows/ci.yml` plus whatever files were
fixed in Step 2, commit (see Step 5), then push and check the Actions tab on
GitHub to confirm the workflow actually runs and passes — this is the only way
to validate GitHub Actions YAML/runner behavior; it can't be fully verified
locally. If it fails on something environment-specific (e.g., a different
Xcode path on the runner than expected), fix and push again.

- [ ] **Step 5: Commit**

```bash
git add .swiftlint.yml .github/workflows/ci.yml
git commit -m "Add SwiftLint config and GitHub Actions CI workflow"
```

(If Step 2 required fixing existing source files, include those in this same
commit or a preceding one — your call on how to split it, but don't leave the
repo in a state where `swiftlint lint --strict` fails on `main`.)

---

### Task 5: Homebrew tap + release automation

**Files:**
- Create (new repo): `China-Drummond/homebrew-tap`, containing `Formula/ibattery-mcp.rb`
- Create: `.github/workflows/release.yml` (in the main `ibattery-mcp` repo)

**This task requires creating a new GitHub repository** (Homebrew's own
convention: a formula for `brew install <owner>/tap/<formula>` must live in a
repo literally named `homebrew-<tap>`, here `homebrew-tap`, under the same
GitHub account). Confirm with the user before creating it — don't create a new
public-facing repository silently.

- [ ] **Step 1: Confirm repo creation with the user, then create it**

Ask: "This task creates a new GitHub repo, `China-Drummond/homebrew-tap`, to
host the Homebrew formula. OK to create it?" Once confirmed:

```bash
gh repo create China-Drummond/homebrew-tap --public --description "Homebrew tap for China-Drummond's tools"
```

(Homebrew taps must be public for `brew install <owner>/tap/...` to work for
other users — a private tap only works for the owner's own authenticated
`gh`/git access. Confirm this with the user specifically, since it differs
from the main repo's current private visibility.)

- [ ] **Step 2: Write the formula**

```ruby
class IbatteryMcp < Formula
  desc "MCP server exposing Apple device battery status as AI-assistant tools"
  homepage "https://github.com/China-Drummond/ibattery-mcp"
  url "https://github.com/China-Drummond/ibattery-mcp/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_REAL_SHA256_AFTER_FIRST_TAG"
  license "MIT"

  depends_on "pkg-config" => :build
  depends_on :xcode => ["15.0", :build]
  depends_on "libimobiledevice"

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/ibattery-mcp"

    system "./Scripts/build-ble-helper-app.sh"
    libexec.install ".build/ibattery-ble-helper.app"
  end

  def caveats
    <<~EOS
      ibattery-mcp needs a companion helper app running for Bluetooth device
      support (macOS requires this to be a separately-launched app, not a
      bare subprocess — see the project README for why). Launch it once with:

        open "#{opt_libexec}/ibattery-ble-helper.app"

      It stays running in the background afterward. You'll also need to
      connect any iPhone/iPad you want battery info from via USB at least
      once, to establish trust.
    EOS
  end

  test do
    assert_match "ibattery-mcp", shell_output("#{bin}/ibattery-mcp --help 2>&1", 1)
  end
end
```

Save as `Formula/ibattery-mcp.rb` in the new `homebrew-tap` repo (clone it
locally first, add the file, commit, push).

**Note the placeholder `sha256` value and the `test do` block's assumption of
a `--help` flag** — these are flagged explicitly rather than silently guessed:
- `ibattery-mcp` doesn't currently implement a `--help` flag (it's a stdio MCP
  server that expects JSON-RPC on stdin, not a traditional CLI tool) — the
  `test do` block as written will fail. Either add a minimal `--help`/version
  flag to the `ibattery-mcp` executable in a follow-up (small, separate,
  non-plan-blocking change) or replace this test block with something that
  fits the tool's actual interface (e.g., piping a minimal JSON-RPC
  `initialize` request and checking for a response, mirroring this project's
  own manual-verification pattern from earlier plans) before this formula can
  actually pass `brew test`.
- The `sha256`/`url` reference a `v0.1.0` git tag that doesn't exist yet — this
  needs a real tagged release first (Step 3 below covers cutting one), and the
  real sha256 comes from that tarball, not from guessing.

- [ ] **Step 3: Cut the first real release and compute the real checksum**

In the main `ibattery-mcp` repo:
```bash
git tag v0.1.0
git push origin v0.1.0
```

Then, once GitHub has generated the tag's source tarball:
```bash
curl -sL https://github.com/China-Drummond/ibattery-mcp/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
```

Update `Formula/ibattery-mcp.rb`'s `sha256` field with the real value printed,
and address the `test do` block issue noted in Step 2. Commit and push the
formula update to `homebrew-tap`.

- [ ] **Step 4: Verify the formula actually installs**

Run: `brew install --build-from-source China-Drummond/tap/ibattery-mcp`
Expected: builds successfully, installs `ibattery-mcp` to `$(brew --prefix)/bin`,
and `brew test China-Drummond/tap/ibattery-mcp` passes (once Step 3's test-block
fix is in place). This is the only way to validate a Homebrew formula — it
can't be meaningfully verified by reading the Ruby alone.

- [ ] **Step 5: Add a release-automation workflow to the main repo**

```yaml
name: Release

on:
  push:
    tags:
      - "v*"

jobs:
  notify:
    runs-on: ubuntu-latest
    steps:
      - name: Print next steps
        run: |
          echo "Tag ${{ github.ref_name }} pushed."
          echo "Next: update China-Drummond/homebrew-tap's Formula/ibattery-mcp.rb"
          echo "with this tag's URL and sha256 (see Task 5, Step 3 of the plan"
          echo "this workflow came from for the exact commands)."
```

Save as `.github/workflows/release.yml` in the `ibattery-mcp` repo.

**This intentionally does not fully automate the Homebrew formula update** —
doing so safely (auto-editing a file in a *different* repo from a workflow,
including computing and trusting a checksum without human review) is real
scope beyond what this plan verified, and a wrong automated formula update
would break installation for every user silently. Automating this end-to-end
is reasonable **future** work, once the manual process above has been run
successfully at least once — flag it as a follow-up, don't build unverified
automation for something this consequential.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Add release workflow (tag-triggered reminder for the Homebrew formula update)"
```

---

## What This Plan Does Not Cover

- The GitHub Pages landing page (Plan 5 — separate, visual-design-focused plan).
- Making the main `ibattery-mcp` repository public (an explicit, separate
  decision for the user to make after reviewing this plan's output).
- Full end-to-end automation of the Homebrew formula update on release (see
  Task 5, Step 5 — deliberately deferred as unverified-automation risk).
- A `--help`/version CLI flag for `ibattery-mcp` — needed to make the Homebrew
  formula's `test do` block work as originally sketched; noted as a
  follow-up in Task 5, Step 2 rather than silently worked around.
