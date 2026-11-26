# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Releases are
tagged `v<build>`, where `<build>` is the build number `YYMMDDNNN`: it is the `<version>` of the
driver, so a release, its `.c4z` file and the *Driver Version* shown in Composer carry the same
number.

## [Unreleased]

## [v261126006] - 2026-11-26

### Added
- **Events `APP_OPENED` / `APP_CLOSED` and variables `CURRENT_APP` / `LAST_APP`** for Composer Programming. After
  an app is launched (tile or `LAUNCH_APP`) the driver reads its state from the TV every 3 s: `visible` turning
  true fires `APP_OPENED`, turning false fires `APP_CLOSED` (also when the TV turns off or stops answering).
- **Reset Room Source On App Exit** (default `On`): Control4 only sends a source selection when the room source
  changes, so after leaving an app with the TV remote the tile did nothing. When the app leaves the foreground
  the driver selects its own TV as the room's video device (`SELECT_VIDEO_DEVICE`) and the tile works again. It
  does nothing when the TV is off, the room is off, a new app was launched meanwhile or the room source is
  not behind the App Switcher.
- **Room Off When TV Turns Off** (default `Off`): also turns the Control4 room off (`ROOM_OFF`) when the TV is
  turned off with its remote or timer, only if the room is on and using this TV. Mind any *Room Off* programming.
- Diagnostic commands for the driver's Lua field: `APP_STATUS` (`AppName`) and `APP_STATUS_ALL` log the state
  the TV reports for an app (`running`, `visible`, HTTP code).
- `[SYNC]` log tag for the room alignment.

### Fixed
- Two HTTPS requests to the TV in quick succession shared one network binding, and the timer of the first could
  release the binding of the second. Only one request is active at a time now.

### Updating
- Update the driver in Composer: the new events, variables and properties appear on their own and no binding has
  to be redone. **Reset Room Source On App Exit** is `On` by default, **Room Off When TV Turns Off** is `Off`.

## [v261126002] - 2026-11-26

### Added
- **Choose the app of every MiniApp slot**: new properties **MiniApp 1 App** … **MiniApp 9 App**, each with the
  list of supported apps (or `Not used`). Defaults are the previous fixed assignments, so existing installations
  behave as before. The Watch experience only tells the driver which slot was selected, so this is how an
  app other than the default one (for example Plex instead of Disney+) is launched from a tile.
- **Plex** as a supported app, for the MiniApp properties and for `LAUNCH_APP`. The app id (`3201512006963`)
  comes from community references, not from Samsung, and was verified on a Samsung UE55CU7170: if the app does
  not start on your TV model, open an issue with the log lines tagged `[APP]`.

### Updating
- Update the driver in Composer: the **MiniApp N App** properties appear with the previous assignments, so
  nothing has to be rebound. To launch another app from a slot (for example Plex from the slot where the Plex
  minidriver is bound), change that slot's property.
- Control4 only sends the slot to the driver when the room's source changes. If you leave an app with the TV
  remote, Control4 still considers it selected and pressing the same tile again does nothing: select another
  tile first, turn the room off, or use `LAUNCH_APP`.

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

[Unreleased]: https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/compare/v261126006...HEAD
[v261126006]: https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/compare/v261126002...v261126006
[v261126002]: https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/compare/v261021001...v261126002
[v261021001]: https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/releases/tag/v261021001
