# flatline

A small, fast menu bar monitor for Apple Silicon Macs. It shows **CPU**, **memory**, and **network** and nothing else.

> Keep an eye on the trace. Hope it never goes flat.

flatline is a deliberately narrow alternative to all-in-one monitors like [eul](https://github.com/gao-sun/eul). It drops Intel and older macOS support completely, so it can use what Apple Silicon offers (load per Performance and Efficiency core cluster, memory pressure the way macOS calculates it) while staying almost invisible in Activity Monitor.

**Status:** pre-alpha. The app builds and runs; signed releases and auto-updates are next. See the [PRD](PRD.md).

## Features (planned for 1.0)

- **CPU**: total, user/system, **per-cluster (P / E)** and per-core load, load average
- **Memory**: used / app / wired / compressed / cached with Activity Monitor's definitions, **memory pressure**, swap
- **Network**: live down/up rates using 64-bit counters (no false spikes at 4 GiB), session totals, active interface
- Fixed-width menu bar that doesn't jump around, with `text`, `trace`, or `text+trace` styles
- Popover with 60-second traces and a per-core grid
- Terminal-style monospaced look with a phosphor accent; native light and dark mode
- Launch at login, automatic updates via [Sparkle](https://sparkle-project.org)
- No telemetry, no root helper, no kernel extensions, no SMC access

## Requirements

- macOS 27 or later
- Apple Silicon (M1 or newer)

## Install

Not released yet. When it is, downloads will be at **[flatline.banast.as](https://flatline.banast.as)**.

## Building from source

Requires Xcode 27+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open Flatline.xcodeproj
```

Sampler unit tests run without Xcode:

```bash
swift test --package-path Packages/FlatlineKit
```

Debug builds are ad-hoc signed and run on any Mac. Release builds are signed with the maintainer's Developer ID.

## Releasing

```bash
scripts/bump-version.sh 0.2.0   # sets the version, increments the build number
scripts/release.sh              # test, archive, sign, notarize, staple → dist/flatline-0.2.0.dmg
```

`release.sh --skip-notarize` makes a signed but un-notarized DMG for a quick check. Notarization reads Apple ID credentials from a keychain profile, created once with `xcrun notarytool store-credentials flatline --team-id F87BNUZAVJ`.

## License

[MIT](LICENSE)
