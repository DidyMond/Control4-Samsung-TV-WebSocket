# Contribuire a Control4-Samsung-TV-WebSocket

Grazie dell'interesse. Il progetto è open source (MIT) e punta a un driver Control4 affidabile per le
Smart TV Samsung Tizen, senza cloud e senza driver cifrati.

## Prima di iniziare

1. Leggi [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): canali di comunicazione, pairing, protocollo Samsung
   e le guardie sui casi limite (ognuna è nata da un problema reale).
2. Apri una issue prima di una modifica grande o di una nuova feature, per concordarla.
3. Lingua: **italiano tecnico** per documenti e commenti; **inglese** per tutto ciò che Control4 vede
   (proprietà, comandi, eventi, binding), per i messaggi di log, il codice e gli identificatori.

## Regole clean-room (obbligatorie)

I driver ufficiali Samsung per Control4 e la libreria `drivers-common-public` di Control4 / Snap One sono
proprietari ("All rights reserved"): il loro codice non si può ridistribuire con licenza MIT.

- **Non** copiare, incollare né "riscrivere a somiglianza" codice di `drivers-common-public` o di altri
  driver (comprese le librerie WebSocket, timer, log).
- **Non** decifrare, aprire o analizzare Lua cifrato (`encryption="2"`, `driver.lua.encrypted` o simili).
- Sono ammessi solo materiali pubblici: `driver.xml`, documentazione ufficiale, RFC (il client WebSocket
  segue la RFC 6455) e documentazione del protocollo Samsung della community.

Una PR che contiene codice derivato da quel materiale verrà rifiutata.

## Sviluppo

### Test e build
- Test: `./tools/run_tests.ps1` (controllo di sintassi, lint dei moduli puri e tutti i test; opzioni
  `-Filter <testo>`, `-Quiet`). Richiede **LuaJIT** (Lua 5.1, come il runtime di DriverWorks): su Windows
  `winget install --id DEVCOM.LuaJIT -e`. Deve essere verde prima di ogni PR.
- Build: `./tools/build.ps1` con Windows PowerShell 5.1. Output in `releases/samsung_tv_websocket.c4z`
  (ignorato da git). Il `.c4z` è uno zip con `driver.xml`, `driver.lua`, `lib/`, `tv/`, `www/` **nella
  radice**, solo file, separatore `/`. Il `<version>` (`YYMMDDNNN`) si incrementa a ogni build installata:
  Composer non ricarica un driver con la stessa versione. `-NoBump` per costruire senza incrementarla.
- Installazione per test: copia il `.c4z` in `Documents\Control4\Drivers`, aggiungi il driver in Composer
  Pro, *Refresh Navigators*. Il dialogo reale con la TV non si testa offline: prova sempre su una TV.

### Lua
- `driver.lua` è solo entrypoint (handler Director, wiring). La logica sta in `lib/` e `tv/`, caricata con
  `require "lib.<modulo>"` / `require "tv.<modulo>"`.
- Moduli **puri** (`lib/util`, `lib/net`, `lib/ws_frame`, `tv/protocol`): **Lua 5.1 puro**, nessun
  riferimento a `C4`; niente `//`, `goto`, operatori bit a bit, `table.unpack`, `bit32`, `utf8`. Lo verifica
  il lint di `run_tests.ps1`. Gli altri moduli usano `C4` ma si provano senza TV con l'ambiente finto di
  `tests/support/fake_c4.lua` (timer simulati, rete, persistenza).
- Ogni modulo ha un `tests/test_*.lua`. Un bug corretto si accompagna a un test che lo riproduce.
- Nomi `snake_case`; costanti `UPPER_SNAKE_CASE`; gli handler obbligati dal framework mantengono il loro
  nome (`OnDriverInit`, `OnPropertyChanged`, `ExecuteCommand`, `ReceivedFromProxy`…).
- Ogni callback invocata da Director passa da `safe()` (`pcall` che logga l'errore): un errore non gestito
  in un timer fermerebbe in silenzio il polling dello stato.
- Niente `sleep`: solo timer DriverWorks (`lib/timer`). Lo stato durevole passa da `PersistSetValue/GetValue`.
- Lua **non cifrato**: nel `<script>` sempre `encryption="0"`.
- Il token di abbinamento **non si logga mai**: `lib/log` lo oscura, ma non costruire messaggi che lo
  contengano di proposito.
- Il payload `ms.remote.control` (`tv/protocol.lua`) ha spazi e a-capo che la TV accetta da sempre: non
  riformattarlo.
- Prima di usare un comando o un parametro Control4 controlla il nome esatto nella
  [documentazione ufficiale](https://control4.github.io/docs-driverworks-api/) e dei
  [proxy TV](https://snap-one.github.io/docs-driverworks-proxyprotocol-tv/); niente nomi a memoria.

### `driver.xml`
- Proprietà: inglese, Title Case (`IP Address`, `Pairing Status`). Comandi ed eventi: `UPPER_SNAKE_CASE`.
- Ogni proprietà usata dal Lua deve essere dichiarata nell'XML, e ogni ingresso HDMI / slot MiniApp mappato
  in `tv/protocol.lua` deve avere la sua `<connection>`: lo verifica `tests/test_driver_xml.lua`.
- La guida del driver è `src/www/documentation.rtf` (IT + EN). Se cambi configurazione o comportamento,
  aggiorna anche il README: le due guide devono dire la stessa cosa.

### Debug
Il driver ha **Log Mode** (`Off` / `Print` / `Log` / `Print and Log`, default `Off`) e **Log Level**
(`0 - Alert` … `5 - Debug`, default `3 - Info`): un messaggio di severità *S* è emesso se *S* ≤ livello.
Ogni messaggio ha un tag tra parentesi (`[REST]`, `[WS]`, `[PAIR]`, `[CMD]`, `[APP]`, `[LIFECYCLE]`,
`[DRIVER]`). Gli errori non gestiti sono sempre visibili, anche con Log Mode `Off`.

## Pull request

- Una PR = un obiettivo; descrizione chiara e collegamento alla issue.
- Indica cosa hai provato e su quale hardware (Control4 OS, Composer Pro, modello di TV, porta 8001/8002).
- La CI (GitHub Actions) lancia `tools/run_tests.ps1` su ogni push e PR; deve essere verde.
- Aggiorna la documentazione toccata (README, guida RTF, `docs/ARCHITECTURE.md` se cambia il flusso) e il
  [CHANGELOG](CHANGELOG.md) (`[Unreleased]`).
- Nessun token, IP o dato personale in log, test o documentazione.
- Contribuendo accetti che il tuo lavoro sia rilasciato con licenza MIT.

## Git workflow

- Branch da `main`: `feat/<slug>`, `fix/<slug>`, `docs/<slug>`. **Conventional commits**: `feat:`, `fix:`,
  `docs:`, `test:`, `build:`, `refactor:`, `chore:` (scope opzionale, es. `fix(rest): …`).
- **Mai push diretto su `main`**: `main` riceve solo merge.
- **Release**: tag `v<build>`, dove `<build>` è il `<version>` (`YYMMDDNNN`) di `driver.xml`; si costruisce
  il `.c4z` con `./tools/build.ps1 -NoBump` e lo si allega alla Release. Il `.c4z` non si committa mai.
