# Changelog

## 1.0.1 (2026-10-29)

- Redrawn app icon: a single heartbeat that runs flat into the cursor

## 1.0.0 (2026-10-26)

The first stable release. If you're on 0.2.1, the app is unchanged; this marks it as 1.0.

- CPU: total load, user/system split, each Performance and Efficiency cluster, a per-core grid and the load average
- Memory: app, wired, compressed and cached memory with Activity Monitor's definitions, memory pressure and swap
- Network: upload and download from 64-bit counters, session totals and the active interface
- Menu bar shows text, a mini trace or both, at a fixed width so it never shifts
- Readings checked against top, Activity Monitor and netstat
- About 0.1% CPU and 13 MB of memory at idle
- Signed, notarized and updated automatically

## 0.2.1 (2026-10-26)

- Uses less CPU when idle: about 0.1%, down from 0.14%. Drawing the menu bar is about four times cheaper.

## 0.2.0 (2026-10-25)

- Redrawn app icon: a single heartbeat that runs flat into the cursor
- Offers to start at login the first time it runs from Applications
- Settings switches and pickers now use your accent color
- Uses about 5 MB less memory after the popover closes

## 0.1.1 (2026-10-25)

- First release delivered through automatic updates; no other changes.

## 0.1.0 (2026-10-25)

First build.

- Menu bar readout of CPU, memory and network, as text, a mini trace, or both
- Popover with 60-second traces, per-core load split by Performance and Efficiency clusters, memory breakdown with pressure, network totals and active interface
- Settings for metrics, styles, units, refresh rate, accent color and launch at login
- Automatic updates, checked daily
- About 0.07% CPU at a 1-second refresh
