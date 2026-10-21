# Control4-Samsung-TV-WebSocket

[![Release](https://img.shields.io/github/v/release/DidyMond/Control4-Samsung-TV-WebSocket?label=release)](https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/releases/latest)
[![Tests](https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/actions/workflows/tests.yml/badge.svg)](https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/actions/workflows/tests.yml)
![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Control4 OS](https://img.shields.io/badge/Control4%20OS-tested%203.4.3-informational)
[![Donate](https://img.shields.io/badge/Donate-PayPal-00457C?logo=paypal&logoColor=white)](https://paypal.me/DavideDimo)

**Open-source Control4 driver for Samsung Tizen Smart TVs — remote control, real power state and Watch experience over the TV's local network API**

**[Italiano](#italiano) · [English](#english)**

> Driver non ufficiale, non affiliato a Samsung, Snap One o Control4. / Unofficial driver, not affiliated with Samsung, Snap One or Control4.

---

## Italiano

Driver DriverWorks (`samsung_tv_websocket`) per Smart TV Samsung con Tizen (2016 e successive). Parla con la TV
attraverso le sue API locali, senza cloud e senza i driver cifrati ufficiali: telecomando completo, **stato
ON/OFF reale** (utile per automazioni come l'accensione delle luci quando la TV si spegne) e tile **MiniApp**
nella Watch experience del Navigator.

> **Stato:** ultima versione nelle [Releases](https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/releases/latest)
> ([CHANGELOG](CHANGELOG.md)). La documentazione tecnica è in italiano; le issue in inglese sono benvenute.

### Features

- **Stato ON/OFF reale** letto dalla TV via REST, con polling adattivo (2 s a TV accesa, 10 s a TV spenta):
  gli eventi *Power On* / *Power Off* in Programming sono affidabili. Lo spegnimento è confermato da due
  letture consecutive, quindi un singolo errore di rete non genera un falso *Power Off*.
- **ON/OFF consapevoli dello stato**: nessun toggle indesiderato se la TV è già nello stato richiesto.
- **Telecomando completo**: volume e canali con ripetizione alla pressione prolungata, mute, numeri,
  navigazione, trasporto, tasti colore, ingressi HDMI 1–3.
- **Watch experience**: 9 slot **MiniApp** (Netflix, YouTube, Prime Video, Disney+, Spotify, Apple TV, DAZN,
  RaiPlay, Paramount+) per i minidriver ufficiali Control4; se la TV è spenta il driver attende l'accensione
  e poi lancia l'app. Il tastierino a schermo del Navigator funziona con l'app aperta.
- **Pairing una tantum**: un popup sulla TV, poi connessioni silenziose. Il token è salvato nel progetto e
  **non compare mai nei log**.
- **Comandi per Composer Programming**: `SEND_KEY` (qualunque tasto Samsung) e `LAUNCH_APP`.
- **Robusto**: coda comandi con scadenza (niente tasti "in ritardo"), watchdog sul polling, isolamento degli
  errori in ogni callback, ripetizione dei tasti con limite di sicurezza.
- Nessun cloud, nessuna licenza, Lua **non cifrato**, log con tag e livelli.

### Quick Start

1. **Scarica** `samsung_tv_websocket.c4z` dalla
   [release più recente](https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/releases/latest) e copialo in
   `Documents\Control4\Drivers`. In alternativa generalo dal sorgente: `./tools/build.ps1`
   (vedi [CONTRIBUTING.md](CONTRIBUTING.md)).
2. **Sulla TV**: *Gestione connessione dispositivi* → *Notifica di accesso* = *Solo la prima volta*
   (*Device Connection Manager* → *Access Notification* = *First Time Only*). Dai alla TV un IP fisso o una
   DHCP reservation. TV e controller devono stare nella stessa subnet.
3. **In Composer Pro** aggiungi il driver e imposta `IP Address`. `Port`: **8002** (consigliata dai modelli 2018)
   o 8001. `Device Name` è il nome con cui il controller compare sulla TV.
4. **Pairing**: imposta `Pairing` = `Pair with TV` e conferma il popup sulla TV entro 60 secondi.
   `Pairing Status` diventa `Paired`.
5. **Binding**: collega la TV alla stanza (proxy *Samsung TV*, ingressi HDMI e audio). Per la Watch experience
   collega i minidriver ufficiali Control4 agli slot **MiniApp 1–9** del driver (proxy *Samsung App Switcher*).
6. **Automazioni**: in Programming usa gli eventi *Power On* / *Power Off* della TV e i comandi `SEND_KEY` /
   `LAUNCH_APP`.

### Comandi per Composer Programming

| Comando | Parametro | Esempio |
|---|---|---|
| `SEND_KEY` | `KeyCode` — codice tasto Samsung (`KEY_*`) | `KEY_HOME`, `KEY_HDMI1`, `KEY_MENU` |
| `LAUNCH_APP` | `AppName` | `Netflix`, `YouTube`, `Prime Video`, `Disney+`, `Apple TV`, `Spotify`, `DAZN`, `RaiPlay`, `Paramount+` |

Slot MiniApp, nell'ordine: Netflix, YouTube, Prime Video, Disney+, Spotify, Apple TV, DAZN, RaiPlay, Paramount+.

### Proprietà

| Proprietà | Significato |
|---|---|
| `Driver Version` | Versione del driver (da indicare nelle segnalazioni) |
| `IP Address` | IP della TV. Cambiarlo invalida il token |
| `Port` | `8002` (WSS) o `8001` (WS) per il telecomando |
| `Device Name` | Nome del controller mostrato sulla TV |
| `Pairing Status` | `Paired` / `Not paired` (sola lettura) |
| `Pairing` | `Pair with TV` avvia l'abbinamento, `Unpair` cancella il token |
| `Log Level`, `Log Mode` | Dettaglio e destinazione dei log (predefiniti `3 - Info`, `Off`) |

### Risoluzione problemi

- **Popup a ogni connessione**: il token non è stato salvato. `Pairing` = `Unpair`, poi `Pair with TV`.
- **Nessun popup in pairing**: TV accesa? IP corretto? Controlla i dispositivi bloccati in *Gestione
  connessione dispositivi*; prova a cambiare `Device Name`.
- **Cambio di IP o di Device Name**: il token può non valere più; se i comandi smettono di funzionare ripeti il pairing (con il cambio di IP il token viene azzerato da solo).
- **Il lancio app va in timeout**: sui modelli 2022+ l'endpoint risponde solo in HTTPS sulla 8002; il driver
  lo gestisce da solo, quindi controlla rete e IP.
- **La sessione WebSocket si chiude dopo ~20 s**: è normale (limite del firmware). Il driver si riconnette al
  comando successivo, senza popup.
- **Wake-on-LAN**: non serve. La TV resta in standby con la rete attiva e risponde ai comandi ON; se le si toglie
  corrente non si può riaccendere da rete.
- **Per una segnalazione**: `Log Mode` = `Print`, `Log Level` = `5 - Debug`, e usa il
  [template delle issue](https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/issues/new/choose).

### Compatibilità

| | |
|---|---|
| Testato su | Samsung UE55CU7170 (Crystal UHD 2023, Tizen), Control4 **OS 3.4.3** con Composer Pro 3.4.3 |
| TV | Smart TV Samsung Tizen dal 2016 (serie K/M/N/Q/T/A/B/C): le API sono quelle usate da `samsungtvws` e Home Assistant |
| Altri modelli | Probabilmente compatibili ma non verificati: segnala l'esito con una issue |
| Fuori scope | TV Samsung pre-Tizen (serie H e precedenti), Wake-on-LAN, controllo audio discreto |

### Documentazione

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — canali di comunicazione, pairing, protocollo Samsung, guardie sui casi limite, test.
- [CONTRIBUTING.md](CONTRIBUTING.md) — regole di sviluppo, clean-room, build, test, release.
- [CHANGELOG.md](CHANGELOG.md) — cambiamenti per release.
- La stessa guida è dentro il driver (`src/www/documentation.rtf`), visibile in Composer Pro.

### Support

Se il progetto ti è utile puoi sostenerne lo sviluppo con una donazione. Grazie!

[![Donate with PayPal](https://img.shields.io/badge/Donate-PayPal-00457C?logo=paypal&logoColor=white&style=for-the-badge)](https://paypal.me/DavideDimo)

### Contributing

Vedi [CONTRIBUTING.md](CONTRIBUTING.md). Per bug e idee usa i
[template delle issue](https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/issues/new/choose).

### Licenza e crediti

[MIT](LICENSE). Samsung, Tizen, Control4 e DriverWorks sono marchi dei rispettivi proprietari.

- **Community `samsungtvws` e Home Assistant (integrazione `samsungtv`)** — documentazione del protocollo
  locale delle TV Tizen (endpoint, formato dei messaggi, token). Nessun loro codice è stato riutilizzato.
- **Snap One / Control4** — DriverWorks SDK e documentazione dei proxy. Il client WebSocket di questo repo è
  scritto da zero a partire dalla RFC 6455: non contiene codice di `drivers-common-public`.

---

## English

DriverWorks driver (`samsung_tv_websocket`) for Samsung Smart TVs running Tizen (2016 and later). It talks to the
TV through its local APIs, with no cloud and none of the encrypted official drivers: full remote control, the
**real ON/OFF state** (useful for automations such as turning lights on when the TV goes off) and **MiniApp**
tiles in the Navigator's Watch experience.

> **Status:** latest version in [Releases](https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/releases/latest)
> ([CHANGELOG](CHANGELOG.md)). The technical documentation is in Italian; issues in English are welcome.

### Features

- **Real ON/OFF state** read from the TV over REST, with adaptive polling (2 s while on, 10 s while off): the
  *Power On* / *Power Off* events in Programming are reliable. Power Off is confirmed by two consecutive
  readings, so a single network glitch does not produce a false *Power Off*.
- **State-aware ON/OFF**: no unwanted toggle if the TV is already in the requested state.
- **Full remote**: volume and channels repeat while a button is held, mute, numbers, navigation, transport,
  colour keys, HDMI 1–3 inputs.
- **Watch experience**: 9 **MiniApp** slots (Netflix, YouTube, Prime Video, Disney+, Spotify, Apple TV, DAZN,
  RaiPlay, Paramount+) for the official Control4 minidrivers; if the TV is off, the driver waits for it to turn
  on and then launches the app. The Navigator's on-screen keypad works with the app open.
- **One-time pairing**: one popup on the TV, then silent connections. The token is stored in the project and
  **never appears in the logs**.
- **Composer Programming commands**: `SEND_KEY` (any Samsung key) and `LAUNCH_APP`.
- **Robust**: command queue with expiry (no "late" keys), watchdog on the polling, error isolation in every
  callback, key repeat with a safety limit.
- No cloud, no licensing, **unencrypted** Lua, logs with tags and levels.

### Quick Start

1. **Download** `samsung_tv_websocket.c4z` from the
   [latest release](https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/releases/latest) and copy it to
   `Documents\Control4\Drivers`. Alternatively build it from source: `./tools/build.ps1`
   (see [CONTRIBUTING.md](CONTRIBUTING.md)).
2. **On the TV**: *Device Connection Manager* → *Access Notification* = *First Time Only*. Give the TV a static
   IP or a DHCP reservation. TV and controller must be on the same subnet.
3. **In Composer Pro** add the driver and set `IP Address`. `Port`: **8002** (recommended for 2018+ models) or
   8001. `Device Name` is the name the controller shows on the TV.
4. **Pairing**: set `Pairing` = `Pair with TV` and accept the popup on the TV within 60 seconds.
   `Pairing Status` becomes `Paired`.
5. **Bindings**: connect the TV to the room (*Samsung TV* proxy, HDMI and audio inputs). For the Watch
   experience, bind the official Control4 minidrivers to the driver's **MiniApp 1–9** slots (*Samsung App
   Switcher* proxy).
6. **Automations**: in Programming use the TV's *Power On* / *Power Off* events and the `SEND_KEY` /
   `LAUNCH_APP` commands.

### Composer Programming commands

| Command | Parameter | Example |
|---|---|---|
| `SEND_KEY` | `KeyCode` — Samsung key code (`KEY_*`) | `KEY_HOME`, `KEY_HDMI1`, `KEY_MENU` |
| `LAUNCH_APP` | `AppName` | `Netflix`, `YouTube`, `Prime Video`, `Disney+`, `Apple TV`, `Spotify`, `DAZN`, `RaiPlay`, `Paramount+` |

MiniApp slots, in order: Netflix, YouTube, Prime Video, Disney+, Spotify, Apple TV, DAZN, RaiPlay, Paramount+.

### Properties

| Property | Meaning |
|---|---|
| `Driver Version` | Driver version (quote it in bug reports) |
| `IP Address` | The TV's IP. Changing it invalidates the token |
| `Port` | `8002` (WSS) or `8001` (WS) for the remote channel |
| `Device Name` | Controller name shown on the TV |
| `Pairing Status` | `Paired` / `Not paired` (read-only) |
| `Pairing` | `Pair with TV` starts pairing, `Unpair` deletes the token |
| `Log Level`, `Log Mode` | Log detail and destination (defaults `3 - Info`, `Off`) |

### Troubleshooting

- **Popup on every connection**: the token was not saved. `Pairing` = `Unpair`, then `Pair with TV`.
- **No popup while pairing**: is the TV on? Is the IP correct? Check blocked devices in *Device Connection
  Manager*; try changing `Device Name`.
- **Changed IP or Device Name**: the token may no longer be valid; if commands stop working, pair again (a changed IP clears the token automatically).
- **App launch times out**: on 2022+ models the endpoint only answers over HTTPS on 8002; the driver handles
  this by itself, so check network and IP.
- **The WebSocket session closes after ~20 s**: this is normal (firmware limit). The driver reconnects on the
  next command, with no popup.
- **Wake-on-LAN**: not needed. The TV stays in standby with the network active and answers ON commands; if
  power to the TV is cut it cannot be turned back on over the network.
- **For a bug report**: `Log Mode` = `Print`, `Log Level` = `5 - Debug`, and use the
  [issue template](https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/issues/new/choose).

### Compatibility

| | |
|---|---|
| Tested on | Samsung UE55CU7170 (Crystal UHD 2023, Tizen), Control4 **OS 3.4.3** with Composer Pro 3.4.3 |
| TVs | Samsung Tizen Smart TVs from 2016 (K/M/N/Q/T/A/B/C series): the APIs are the ones used by `samsungtvws` and Home Assistant |
| Other models | Probably compatible but not verified: report the result in an issue |
| Out of scope | Pre-Tizen Samsung TVs (H series and earlier), Wake-on-LAN, discrete volume control |

### Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — communication channels, pairing, Samsung protocol, edge-case guards, tests (Italian).
- [CONTRIBUTING.md](CONTRIBUTING.md) — development rules, clean-room, build, tests, release (Italian).
- [CHANGELOG.md](CHANGELOG.md) — changes per release (English).
- The same guide is inside the driver (`src/www/documentation.rtf`), visible in Composer Pro.

### Support

If this project is useful to you, you can support its development with a donation. Thank you!

[![Donate with PayPal](https://img.shields.io/badge/Donate-PayPal-00457C?logo=paypal&logoColor=white&style=for-the-badge)](https://paypal.me/DavideDimo)

### Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) (Italian). For bugs and ideas, use the
[issue templates](https://github.com/DidyMond/Control4-Samsung-TV-WebSocket/issues/new/choose) (bilingual).

### License and credits

[MIT](LICENSE). Samsung, Tizen, Control4 and DriverWorks are trademarks of their respective owners.

- **`samsungtvws` community and Home Assistant (`samsungtv` integration)** — documentation of the Tizen TVs'
  local protocol (endpoints, message format, token). None of their code was reused.
- **Snap One / Control4** — DriverWorks SDK and proxy documentation. This repo's WebSocket client is written
  from scratch from RFC 6455: it contains no code from `drivers-common-public`.
