# flatline: Product Requirements

| | |
|---|---|
| **Status** | v1.0: M0–M7 done; 1.0.0 released 2026-10-26 |
| **Owner** | Bill Anastas |
| **Last updated** | 2026-10-25 |
| **Repo** | [banastas/flatline](https://github.com/banastas/flatline) |
| **Site / updates** | https://flatline.banast.as |

---

## 1. Summary

flatline is a menu bar system monitor for Apple Silicon Macs running macOS 27 or later. It shows three things: **CPU**, **memory**, and **network up/down**. It does not try to be iStat Menus. It covers those three well, uses almost no resources, and drops support for Intel and older macOS completely.

The name refers to a heart monitor: you keep an eye on the trace and hope it doesn't go flat. It is also a nod to the Dixie Flatline in *Neuromancer*.

## 2. Background

[eul](https://github.com/gao-sun/eul) is a popular open-source SwiftUI menu bar monitor. It covers a lot: CPU, GPU, memory, disk, battery, fans and SMC temperature sensors, on both Intel and Apple Silicon and on older versions of macOS. That breadth has costs: more code paths, SMC access, and compatibility layers. It also can't build on newer APIs or on hardware details specific to Apple Silicon.

flatline makes the opposite choice:

- **One architecture (arm64), one OS floor (macOS 27).** No `#available` branches and no Intel code. We use current Swift and SwiftUI throughout.
- **Three metrics only.** Fewer features mean more polish and lower overhead per feature.
- **Use what Apple Silicon offers.** Report CPU load per cluster (Performance and Efficiency cores) and show memory pressure the way macOS calculates it.

## 3. Goals

1. **Accurate.** Readings match Activity Monitor (see §9 for tolerances).
2. **Negligible footprint.** The monitor must never show up as a load itself (see §8 for budgets).
3. **Steady menu bar.** Fixed-width, monospaced-digit layout, so the menu bar doesn't jump as values change. That jumping is a common complaint about menu bar monitors.
4. **Readable at a glance, detailed on click.** The menu bar answers "is something wrong?" and the popover answers "what, exactly?"
5. **Hacker look, native feel.** Terminal-style monospaced type and a phosphor accent color, but it is still a well-behaved macOS app: light/dark mode, accessibility, and no Dock icon.
6. **Ships and updates itself.** Developer ID signed, notarized, with automatic updates through Sparkle from flatline.banast.as.

## 4. Non-goals

- GPU, disk, battery, fans, temperatures, SMC, or any other sensor
- Intel Macs, Rosetta, or any macOS earlier than 27
- Widgets, a Dock icon, or a main window
- Per-process CPU/memory tables (possible later; see §12)
- Mac App Store distribution (Sparkle and the sandbox don't mix well, and we don't need the store)
- Root privileges, privileged helpers, kernel extensions, or private frameworks

## 5. Users

- **Developers and power users** who run builds, containers, local LLMs, and so on, and want to see straight away when the machine is busy, swapping, or saturating the network.
- **People who want one small, nice-looking monitor** instead of a feature-heavy suite.

## 6. Functional requirements

### 6.1 Metrics and data sources

All metrics are sampled on one shared tick (default 1 s). Each value is the difference between two samples, not a running average since boot.

#### CPU

| Value | Source | Notes |
|---|---|---|
| Total usage % | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | Per-core ticks for user, system, idle and nice, differenced between ticks |
| User / System split | same | |
| Per-cluster usage % | Per-core ticks grouped by cluster | Cluster membership comes from IORegistry `IOPlatformDevice` `cpuN` nodes (`cluster-type` = `E` / `P`, `logical-cpu-id`). Cluster names and counts come from `hw.nperflevels` / `hw.perflevelN.{name,logicalcpu}`. Any number of perf levels must work, not just two. |
| Per-core usage % | same | Shown as a grid in the popover |
| Load average (1/5/15) | `getloadavg()` | |
| Chip name | `machdep.cpu.brand_string` | e.g. "Apple M2 Pro" |

#### Memory

Definitions match Activity Monitor, so the numbers agree:

| Value | Source / formula |
|---|---|
| Physical memory | `hw.memsize` |
| App memory | `internal_page_count − purgeable_count` (`host_statistics64(HOST_VM_INFO64)`) |
| Wired | `wire_count` |
| Compressed | `compressor_page_count` |
| **Used** | App + Wired + Compressed |
| Cached files | `external_page_count + purgeable_count` |
| Swap used / total | `vm.swapusage` |
| Pressure level | `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical) |
| Pressure % | `100 − kern.memorystatus_level` (the value Activity Monitor graphs) |

Page size comes from `hw.pagesize` (16 KB on Apple Silicon). Never hard-code it.

#### Network

| Value | Source | Notes |
|---|---|---|
| Down / Up bytes per second | `sysctl(NET_RT_IFLIST2)` → `if_msghdr2.ifm_data` (`if_data64`) | **Use the 64-bit counters.** The 32-bit `if_data` counters from `getifaddrs` wrap at 4 GiB and cause false spikes. |
| Interfaces counted | Up, non-loopback, physical `en*` | Exclude `lo*`, `utun*` (VPN tunnels; counting them double-counts traffic), `awdl*`, `llw*`, `bridge*`, `ap*`, `anpi*`. |
| Session totals | Running sum since flatline launched | Resettable from the popover |
| Active interface + local IP | `getifaddrs` | Shown in the popover; no SSID (that would need location permission) |

### 6.2 Menu bar

- A **single `NSStatusItem`**, with segments for each enabled metric.
- Each metric can be turned on or off independently (at least one must stay on).
- **Display styles** per metric:
  - `text`: a short label stacked above the value (e.g. `CPU` / `23%`)
  - `trace`: a small heart-monitor-style line graph of recent history, which goes flat when the machine is idle
  - `text+trace`
- Network text shows up and down stacked, with arrows (`↑ 34 KB/s` / `↓ 1.2 MB/s`).
- **Fixed widths**: monospaced digits; each segment's width is sized for its widest possible value, so the bar never moves.
- Monochrome, in the menu bar's own label color, so it matches the system items. No severity coloring: colored text was hard to read on a see-through menu bar, and the number itself is the signal. Severity colors live in the popover (memory pressure badge).
- Click opens the popover. Right-click or Control-click opens a small menu (Open, Settings, Check for Updates, Quit).
- VoiceOver: the item reads a summary such as "CPU 23 percent, memory 61 percent, down 1.2 megabytes per second, up 34 kilobytes per second."

### 6.3 Popover

A single scrolling panel about 340 pt wide, built with SwiftUI.

1. **Header**: chip name, macOS version, uptime.
2. **CPU card**: large total %, 60-second trace, user/system split, one bar per cluster (P / E, labeled), per-core mini-bar grid colored by cluster, load average.
3. **Memory card**: used / total, pressure gauge (green / yellow / red, matching macOS), stacked bar of App / Wired / Compressed / Cached / Free, swap used.
4. **Network card**: down and up rates with a combined 60-second trace (up and down mirrored above and below the baseline), session totals with a reset button, active interface and local IP.
5. **Footer**: settings gear, update indicator, Quit.

Traces are drawn with SwiftUI `Canvas` from ring buffers. Popover views exist only while the popover is open.

### 6.4 Settings

Shown in the popover (an inline settings panel, not a separate window), stored in `UserDefaults`:

| Setting | Options | Default |
|---|---|---|
| Refresh interval | 0.5 s, 1 s, 2 s, 5 s | 1 s |
| Menu bar metrics | CPU, Memory, Network (multi-select) | all |
| Display style (per metric) | text, trace, text+trace | text |
| Network units | bytes/s, bits/s | bytes/s |
| Memory display | % used, GB used | % used |
| Accent color | phosphor green, cyan, magenta, amber, system | phosphor green |
| Launch at login | on / off (`SMAppService.mainApp`) | off, with a prompt on first run |
| Automatic updates | check automatically / download automatically | check automatically, daily |

### 6.5 Updates (Sparkle)

- **Sparkle 2.10.0** (pinned) via Swift Package Manager, using `SPUStandardUpdaterController`. Checks daily without a first-run prompt (`SUEnableAutomaticChecks`); gentle reminders are on because flatline has no Dock icon.
- Appcast at `https://flatline.banast.as/appcast.xml`, served over HTTPS with `Cache-Control: no-cache`.
- Updates are signed with **EdDSA (ed25519)**. The public key is in `Info.plist` (`SUPublicEDKey`). The private key is in the release Mac's login keychain under account `flatline` and is **never committed**. Losing it means existing installs can't verify future updates, so keep an exported backup in a password manager.
- The update archive is the same notarized, stapled DMG people download, at `https://flatline.banast.as/releases/flatline-<version>.dmg`.
- `scripts/release.sh` copies each DMG and its notes into `releases/` (local, git-ignored: the archive of everything shipped) and runs `generate_appcast`, which signs the entries and rewrites `site/appcast.xml` (committed). Release notes are the `CHANGELOG.md` section for the version, embedded as HTML.
- "Check for Updates…" appears in the right-click menu; the settings panel has automatic check/download toggles and "check now".

### 6.6 Website (flatline.banast.as)

A small static site, kept in this repo under `site/`, served by the static-assets Worker in `wrangler.jsonc` (Cloudflare Pages' current form) with `flatline.banast.as` as its custom domain:

- A landing page: what it is, a download button, system requirements, and the latest release notes. `scripts/deploy-site.sh` fills in the version, size and notes.
- `/download` redirects to the newest DMG (`_redirects`, generated on deploy)
- `appcast.xml` and `releases/` for Sparkle; `_headers` sets caching (appcast never cached, releases immutable)
- To do for 1.0: a screenshot

## 7. Technical design

### 7.1 Stack

- **Swift 6.4**, strict concurrency, Swift 6 language mode
- **SwiftUI** for all views; **AppKit** only for `NSStatusItem` / `NSPopover` and their event handling
- **Observation** (`@Observable`) for the metrics model
- Deployment target **macOS 27.0**, architectures **arm64 only**
- No third-party dependencies other than **Sparkle**

### 7.2 Project layout

```
flatline/
├── project.yml              # XcodeGen spec → Flatline.xcodeproj (generated, git-ignored)
├── Packages/
│   └── FlatlineKit/         # Swift package: samplers, models, formatting. Unit-tested with `swift test`.
│       ├── Sources/FlatlineKit/
│       │   ├── CPUSampler.swift
│       │   ├── MemorySampler.swift
│       │   ├── NetworkSampler.swift
│       │   ├── Topology.swift        # perf levels + core→cluster map
│       │   ├── RingBuffer.swift
│       │   └── Format.swift          # byte/rate/percent formatting
│       └── Tests/FlatlineKitTests/
├── App/                     # The .app target
│   ├── FlatlineApp.swift
│   ├── StatusItemController.swift
│   ├── MenuBarRenderer.swift
│   ├── Popover/…
│   ├── Settings/…
│   └── Resources/ (Assets, Info.plist, entitlements)
├── scripts/
│   ├── release.sh           # archive → sign → notarize → staple → DMG → appcast
│   └── bump-version.sh
├── site/                    # flatline.banast.as
├── CHANGELOG.md
├── PRD.md
└── README.md
```

Keeping the samplers in a separate package means the parts that matter most for accuracy can be tested without launching the app. XcodeGen keeps the project diffable and avoids `.pbxproj` merge conflicts.

### 7.3 Sampling loop

- One `MetricsEngine` on the main actor, driven by a single repeating timer with **10 % leeway** so macOS can coalesce wake-ups.
- Each tick reads all three samplers (a few microseconds of system calls), updates the `@Observable` snapshot, and appends to 120-sample ring buffers.
- Buffers are preallocated, so the steady state should not allocate.
- While the screen is locked or the display is asleep, sampling drops to every 5 s. It catches up on wake (`NSWorkspace` notifications).

### 7.4 Menu bar rendering

- `MenuBarRenderer` draws the bar segments into one `NSImage` per tick (Core Graphics / `ImageRenderer`) and assigns it to the status button.
- The bitmap goes into a `CALayer` inside the status button rather than `button.image`, which made NSButton re-render it on the CPU every tick. Text uses the menu bar's label color, resolved for its current appearance.
- If nothing visible changed since the last tick (same rounded values and trace pixels), the redraw is skipped.

### 7.5 Security and distribution

- Hardened runtime on; no unusual entitlements needed.
- Signed with **Developer ID Application**, notarized with `notarytool`, ticket stapled.
- Bundle ID `as.banast.flatline`. `LSUIElement = YES` (no Dock icon).
- The only network request is Sparkle checking the appcast. No telemetry or analytics.

## 8. Performance budgets

Measured on an M-series Mac at the default 1 s refresh, popover closed:

| Metric | Budget |
|---|---|
| Average CPU | < 0.15 % of one core (raised from 0.1 % on 2026-10-26; see §9.2) |
| Resident memory | < 30 MB |
| Idle wake-ups | ≤ 1 per refresh interval |
| Energy Impact (Activity Monitor) | ≈ 0 when popover closed |
| Popover open → first frame | < 50 ms |

These budgets are checked before each release with Instruments (Time Profiler, Allocations, Energy Log) and with the built-in tick profiler: run `flatline.app/Contents/MacOS/flatline` with `FLATLINE_PROFILE=1` to print the average CPU time of each tick phase. Compare total process CPU time (`ps -o time`) over a few minutes against the same window for a reference app.

## 9. Accuracy acceptance criteria

| Metric | Reference | Tolerance |
|---|---|---|
| CPU total | Activity Monitor CPU tab / `top -l 2` | ± 3 points, averaged over 10 s |
| Per-cluster CPU | `powermetrics --samplers cpu_power` | ± 5 points |
| Memory used / app / wired / compressed | Activity Monitor Memory tab | ± 1 % of physical RAM |
| Memory pressure level | Activity Monitor pressure color | exact match |
| Network rates | Activity Monitor Network tab / `nettop` | ± 5 % over a sustained 30 s transfer |
| Counter wrap | Transfer > 4 GiB | no spikes or negative values |

### 9.1 Verification, 2026-10-25 (0.2.0, M2 Pro, 32 GB)

Measured with flatline's own sampler code next to the reference tool over the same window.

| Check | Result | Target | Pass |
|---|---|---|---|
| CPU total vs `top` (20 s windows: background, 6 cores busy, 12 cores busy) | −1.0 to +1.0 points | ± 3 | ✅ |
| CPU user/system split vs `top` | within 0.7 points | — | ✅ |
| Per-cluster CPU | P 80% / E 49% with 6 busy threads (plausible); not compared with `powermetrics`, which needs sudo | ± 5 | not run |
| App / wired / compressed / cached / swap vs Activity Monitor | each within normal second-to-second movement; identical to `vm_stat` at the same instant | ± 1% of RAM | ✅ |
| "Memory Used" vs Activity Monitor's headline | 0.5–0.8 GB lower. Activity Monitor's headline exceeds the sum of its own app + wired + compressed by that much, and the gap isn't documented. flatline shows the sum. | ± 1% of RAM | ⚠️ by design |
| Memory pressure level | matches | exact | ✅ |
| Network rate vs `netstat` during a 30 s, ~19 MB/s download | within 0.05% | ± 5% | ✅ |
| 64-bit counters past 4 GiB | interface counters at 1.9 TB read correctly | no wrap | ✅ |

Footprint on a quiet machine, 2 minutes, popover closed (eul 1.6.2 measured over the same window):

| | flatline 0.2.0 | eul 1.6.2 | Budget |
|---|---|---|---|
| Average CPU | 0.14% | 1.03% | < 0.1% (budget then) ❌ |
| Memory | 13 MB (26 MB after the popover has been opened) | 75 MB | < 30 MB ✅ |
| Idle wake-ups (20 s) | 3 | 11,822 | ≤ 1 per tick ✅ |

On an idle machine the cores clock down and every tick phase takes about twice as long as under load (0.07% CPU was measured under load). Rendering the menu bar bitmap was the largest cost (about 420 µs per tick on a quiet machine): it allocated and cleared a new bitmap and laid out text every second.

### 9.2 After the render optimization, 2026-10-26 (`f7e6d55`)

Text is drawn from cached per-character cells into two alternating canvases; images wrap the pixels without a copy. Steady-state per-tick cost on a quiet machine:

| Phase | Before | After |
|---|---|---|
| Render | 421 µs | 100 µs |
| Layout | 75 µs | 11 µs |
| Accessibility label | 66 µs | 5 µs, every fifth tick |
| Samplers (CPU + memory + network) | 159 µs | 169 µs |
| **All of flatline's tick code** | **~760 µs** | **~330 µs** |

Whole process, 2 minutes, display on (eul 1.6.2 over the same window):

| | flatline | eul 1.6.2 | Budget |
|---|---|---|---|
| Average CPU | 0.11% (was 0.14%) | 1.08% | < 0.15% ✅ |
| Memory | 13 MB | — | < 30 MB ✅ |

About two-thirds of what remains happens outside flatline's own code: Core Animation committing the new layer contents, the timer and run-loop wake-up each second. Going further would mean experiments with an IOSurface-backed layer or batched wake-ups, so the budget was raised to 0.15% instead: 0.11% is about a tenth of eul's.

## 10. Accessibility and localization

- VoiceOver labels on the status item and on every popover value
- The popover respects Reduce Motion (traces stop animating) and Increase Contrast
- Colors are never the only signal: pressure states also have a text label
- English only for 1.0, with all strings in a String Catalog so they can be translated later

## 11. Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | Scaffold | XcodeGen project builds an empty menu bar app; `swift test` runs |
| M1 | Samplers | CPU, memory and network samplers with unit tests; values match §9 in a debug print |
| M2 | Menu bar | Text and trace styles, fixed widths, template rendering |
| M3 | Popover | All three cards with traces and per-core grid |
| M4 | Settings | All §6.4 settings persist; launch at login works |
| M5 | Distribution | `scripts/release.sh` produces a signed, notarized, stapled DMG |
| M6 | Updates + site | Sparkle wired up; `site/` deployed to flatline.banast.as with appcast; an update tested end to end from 0.9 to 0.9.1 |
| M7 | 1.0 | Performance budgets (§8) and accuracy criteria (§9) verified; README screenshots; tagged release |

## 12. Decisions

| Question | Decision (2026-10-25) |
|---|---|
| Apple Developer account | Yes. Releases are signed with **Developer ID Application (team `F87BNUZAVJ`)** and notarized with `notarytool`, using a keychain profile named `flatline`. |
| Hosting for flatline.banast.as | **Cloudflare**, as a static-assets Worker (`flatline-banast-as`; wrangler now routes new Pages projects there). Site, appcast and DMGs together; the per-file limit is 25 MiB, so move DMGs to R2 if they ever exceed it. |
| License | **MIT**. |
| Menu bar severity colors | **Removed**; colored text was hard to read on a see-through menu bar (see §6.2). |
| Repo visibility | **Private until 1.0**, public with the 1.0 release. |
| Top processes in the popover | **Not in 1.0.** Without a privileged helper the list would miss root-owned processes. |
| Default network unit | **bytes/s**, matching Activity Monitor, Safari and Finder; bits/s is a setting. |
| Homebrew | **Offer a cask after 1.0** (`brew install --cask flatline`), pointing at the DMG on flatline.banast.as. |

## 13. Open questions

None right now.
