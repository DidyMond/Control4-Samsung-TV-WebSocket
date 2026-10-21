# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Releases are
tagged `v<build>`, where `<build>` is the build number `YYMMDDNNN`: it is the `<version>` of the
driver, so a release, its `.c4z` file and the *Driver Version* shown in Composer carry the same
number.

## [Unreleased]

## [v261021001] - 2026-10-21

First public release.

### Driver (`samsung_tv_websocket`)
- Remote control of Samsung Tizen Smart TVs over the TV's local APIs: WebSocket for keys, REST for the
  power state, HTTPS REST for launching apps. No cloud, no licensing, unencrypted Lua.
- Real power state with adaptive polling (2 s while on, 10 s while off); *Power On* / *Power Off* events
  for Composer Programming. Power Off needs two consecutive readings, so one network glitch cannot
  trigger it; the initial state at startup is read without raising events.
- State-aware ON/OFF, volume and channel keys with auto-repeat (stops on release or after 20 s),
  mute, numbers, navigation, transport, colour keys, HDMI 1–3 input selection.
- Watch experience: 9 MiniApp slots (Netflix, YouTube, Prime Video, Disney+, Spotify, Apple TV, DAZN,
  RaiPlay, Paramount+) on the *Samsung App Switcher* proxy; if the TV is off, the app is launched once
  it has turned on. PASSTHROUGH keypad support, `EJECT` closes the app.
- Composer commands `SEND_KEY` and `LAUNCH_APP`.
- One-time pairing from the **Pairing** property (`Pair with TV` / `Unpair`), with a 60 s pairing window
  and a read-only **Pairing Status** property (`Paired` / `Not paired`). The token is kept in persistent
  storage, is never shown in Composer and is masked in every log line.
- Command queue with a 5 s expiry and a size limit: keys that cannot be delivered are dropped instead of
  firing minutes later.
- **Log Mode** (default `Off`) and **Log Level** (default `3 - Info`); every line carries a tag
  (`[REST]`, `[WS]`, `[PAIR]`, `[CMD]`, `[APP]`, `[LIFECYCLE]`, `[DRIVER]`); unhandled errors are always
  visible.
- Bilingual (IT / EN) guide inside the driver (`www/documentation.rtf`) and in the README.

### Internals
- WebSocket client written from RFC 6455 (handshake validation, masked frames, fragmentation, short
  reads, ping/pong, clean close); no code from other drivers.
- Code split into `lib/` (logging, timers, network dispatch, WebSocket) and `tv/` (protocol, TV logic,
  command mapping); `driver.lua` is only the Director entry point and wraps every callback in `pcall`.
- Offline test suite (LuaJIT, Lua 5.1 semantics) with a simulated DriverWorks environment; GitHub
  Actions runs it on every push and pull request.

### Requirements
- Samsung Smart TV with Tizen (2016 or later), on the same subnet as the Control4 controller.
- On the TV: *Device Connection Manager* → *Access Notification* = *First Time Only*.
- Tested on Control4 OS 3.4.3 with Composer Pro 3.4.3 and a Samsung UE55CU7170.

### Known limitations
- The protocol is not official and may change with TV firmware updates.
- Other TV models and Control4 OS versions are not verified.
- No Wake-on-LAN: a TV that has lost power cannot be turned on over the network.

[Unreleased]: https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/compare/v261021001...HEAD
[v261021001]: https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/releases/tag/v261021001
