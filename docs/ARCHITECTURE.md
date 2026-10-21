# Architettura

Driver DriverWorks `samsung_tv_websocket` per Smart TV Samsung con Tizen. Questo documento spiega come
parla con la TV, perché è fatto così e quali guardie proteggono dai casi limite. Chi modifica il
codice dovrebbe leggerlo prima: quasi ogni riga "strana" nasce da un problema reale visto su hardware.

## 1. Panoramica

```
Director ──► driver.lua ──► safe() / pcall ──┬─► lib/timer      timer DriverWorks con callback
 (handler)   (entrypoint)                    ├─► lib/net        dispatch eventi di rete per binding
                                             ├─► tv/commands    comando proxy / Composer ─► azione
                                             └─► tv/samsung_tv  REST, WebSocket, pairing, coda, app
                                                    ├─► lib/websocket + lib/ws_frame   client RFC 6455
                                                    ├─► tv/protocol                     mappe e parsing (puro)
                                                    └─► lib/log, lib/util               log con tag, redazione token
```

| Modulo | Ruolo | Tocca `C4` |
|---|---|---|
| `driver.lua` | Handler Director, wiring, `safe()` attorno a ogni callback | sì |
| `lib/log.lua` | Log Mode / Log Level, tag, oscuramento del token | solo per `C4:ErrorLog` |
| `lib/timer.lua` | `after` / `every` / `cancel` sopra `C4:AddTimer` | sì |
| `lib/net.lua` | Registro `binding → callback` per status e dati di rete | no |
| `lib/websocket.lua` | Client WebSocket su binding dinamici 6100–6199 | sì |
| `lib/ws_frame.lua` | Codifica/parsing dei frame RFC 6455 | no |
| `lib/util.lua` | `redact`, `is_blank` | no |
| `tv/protocol.lua` | Token, stato REST, mappe tasti / HDMI / MiniApp / app, payload | no |
| `tv/samsung_tv.lua` | Logica di comunicazione con la TV | sì |
| `tv/commands.lua` | Da `ReceivedFromProxy` / `ExecuteCommand` a tasti e app | no (TV iniettata) |

I moduli che non toccano `C4` sono Lua 5.1 puro e lo verifica il lint di `tools/run_tests.ps1`.

## 2. I tre canali verso la TV

| Canale | Porta | Uso | Binding |
|---|---|---|---|
| REST http | 8001 | stato ON/OFF (`GET /api/v2/` → `device.PowerState`) | 6099 |
| WebSocket | 8002 (wss) o 8001 (ws), proprietà `Port` | telecomando (`ms.remote.control`) | 6100–6199 |
| REST https | 8002 | lancio app (`POST /api/v2/applications/<id>`) | 6098 |

I binding 6098, 6099 e 6100–6199 sono dinamici (`C4:CreateNetworkConnection`), quelli del driver sono
5000 (proxy TV) e 5002 (proxy avswitch).

### 2.1 Stato ON/OFF: REST (fonte unica di verità)

`GET http://<ip>:8001/api/v2/` con `Connection: close` risponde con JSON contenente `device.PowerState`:
`"on"` → accesa; `"standby"` (o altro) → spenta; nessuna risposta o connessione rifiutata → spenta del tutto.

**Il WebSocket non può dire se la TV è accesa**: una TV in standby con la rete attiva accetta comunque TCP e
handshake WebSocket e risponde ai ping. Solo `PowerState` dice la verità.

Ciclo di un check (`samsung_tv.lua`, `check_reachability`):

1. Si apre il binding 6099 e si registrano le callback in `lib/net`; `NetConnect` sulla 8001.
2. `ONLINE` → si invia la richiesta e si arma il **timeout di risposta (3 s)**, solo ora: armarlo prima
   dava falsi OFF.
3. Al primo byte si annulla quel timeout e si arma un'**attesa di 200 ms** di silenzio: allo scadere la
   risposta è completa e si decide. Una risposta a pezzi viene riunita.
4. `OFFLINE` senza dati → si decide subito con "nessuna risposta" (TV spenta o irraggiungibile).
5. **Guardia di 10 s**: se la connessione resta appesa senza mai arrivare a `ONLINE` / `OFFLINE`, nessun
   altro timeout parte. Alla scadenza il check si chiude e il polling si riprogramma. Senza questa guardia
   il ciclo si fermava per sempre in silenzio (visto in produzione).
6. Alla chiusura di un check si cancellano **tutti** i suoi timer e si libera il binding.

Ogni check ha un numero progressivo (`rest.gen`): callback e timer di un check già chiuso o sostituito
vengono ignorati. Senza, il timer di guardia di un check finito poteva scattare in mezzo a quello successivo,
abortirlo e contarlo come lettura OFF.

**Polling adattivo**: ogni 2 s se la TV è accesa (o sconosciuta), ogni 10 s se è spenta. Lo spegnimento va
rilevato in pochi secondi (automazioni come l'accensione delle luci), la riaccensione ha meno fretta.

**Conferma dell'OFF**: una lettura OFF isolata (timeout, connessione rifiutata) non basta a passare da ON a OFF;
servono `REQUIRED_OFF_CONFIRMATIONS = 2` letture consecutive. Un blip di rete non deve produrre un evento
*Power Off*. Il contatore si azzera a ogni lettura ON.

**Notifica**: a ogni cambio di stato `C4:SendToProxy(5000, "ON" | "OFF", {}, "NOTIFY")`. Al **primo** check dopo
l'avvio (o dopo un cambio di IP, `reset_power`) lo stato si sincronizza senza notifica: niente eventi fantasma.

Il polling parte all'avvio del driver (`start`) se `IP Address` è impostato, abbinati o no.

### 2.2 Telecomando: WebSocket on-demand

URL: `wss://<ip>:8002/api/v2/channels/samsung.remote.control?name=<base64(Device Name)>[&token=<token>]`
(`ws://` sulla 8001). Sulla 8002 servono opzioni SSL `verify_mode = "none"`, `method = "tlsv1_2"`: la TV usa
certificati autofirmati.

**Perché on-demand**: il firmware chiude la sessione WebSocket ogni ~19–21 s anche con ping/pong regolari. È un
limite di sessione fisso lato TV, non un timeout di inattività: una connessione persistente è impossibile. Il
driver si connette quando c'è un tasto da inviare e, quando la TV chiude, controlla lo stato REST invece di
riconnettersi in loop.

Comando inviato: frame di testo con

```json
{ "method": "ms.remote.control", "params": { "Cmd": "Click", "DataOfCmd": "KEY_VOLUP",
  "Option": "false", "TypeOfRemote": "SendRemoteKey" } }
```

Il payload di `tv/protocol.lua` ha spazi e a-capo: la TV lo accetta da sempre, non va riformattato. Il codice
tasto è validato (`^[%w_]+$`): un `KeyCode` di Composer con virgolette romperebbe il JSON.

**Coda comandi** (`send_key` → `pump_queue`): il tasto va in coda; se il WebSocket non è pronto
(`open` e autorizzato da `ms.channel.connect`) si apre la connessione e si riprova ogni 500 ms.
- Un tasto che non parte entro **5 s** viene scartato: un "volume su" premuto a TV irraggiungibile non deve
  scattare minuti dopo, e la coda non deve riarmarsi all'infinito.
- C'è **un solo** timer di pompaggio: ogni chiamata annulla quello pendente. (Prima ogni tasto aggiungeva un
  ciclo di retry autonomo.)
- Tasti consecutivi sono distanziati di 200 ms; la coda tiene al massimo 20 elementi.
- Driver non configurato o non abbinato: la coda si svuota subito con un avviso, senza retry.

**Timeout di connessione**: 15 s. Il timer è legato al tentativo (`conn.gen`); alla scadenza il socket viene
chiuso e il binding liberato.

### 2.3 Lancio app: REST https

`POST https://<ip>:8002/api/v2/applications/<id>` con `Content-Length: 0`, sul binding 6098 con SSL (stesse
opzioni). Sui modelli 2022+ l'endpoint risponde solo su HTTPS 8002 (HTTP 8001 va in timeout). Gli id
applicazione sono in `tv/protocol.lua` (`APP_IDS`); un HTTP ≥ 400 nella risposta viene loggato come avviso.

Dalla Watch experience il lancio passa da `launch_app_when_on`: se la TV non è ancora `ON` il driver forza un
check REST e riprova ogni 1,5 s, fino a 10 volte. Director manda `SET_INPUT` due volte (audio + video):
`commands.lua` ignora lo stesso lancio entro 3 s.

## 3. Pairing e token

- La proprietà LIST `Pairing` (`Select...`, `Pair with TV`, `Unpair`) fa da trigger e torna a `Select...` dopo
  l'esecuzione. Più stabile delle `<actions>` di Composer.
- `Pair with TV` → connessione **senza token** → popup sulla TV → conferma → `ms.channel.connect` contiene il
  token numerico (~8 cifre, `data.token` o `data.clients[].token`, **con o senza virgolette**: le due forme
  sono gestite) → `C4:PersistSetValue("AuthToken", ...)` e `Pairing Status` = `Paired`.
- La **finestra di pairing dura 60 s**: senza conferma si chiude da sola. Altrimenti una connessione
  successiva senza token farebbe comparire un popup a sorpresa sulla TV.
- Connessioni successive con `&token=<token>`: silenziose.
- `ms.channel.unauthorized` → token respinto: si cancella, si svuota la coda, serve un nuovo pairing.
- Cambiare `IP Address` cancella il token (vale solo per la TV con cui si è fatto il pairing) e azzera lo
  stato noto. Cambiare `Device Name` può invalidare il token lato TV (la TV riconosce i client per nome): se i comandi smettono di funzionare si ripete il pairing.
- Il token **non è mai visibile**: la proprietà mostra solo `Paired` / `Not paired` e `lib/log` oscura
  `token=…` e `"token": …` in ogni riga.

## 4. Il client WebSocket (`lib/websocket.lua`, `lib/ws_frame.lua`)

Scritto a partire dalla RFC 6455 e dalla documentazione DriverWorks, senza codice di terzi.

- **Handshake**: `Sec-WebSocket-Key` = Base64 di 16 byte casuali; la risposta deve essere `101` con `Upgrade`,
  `Connection` e `Sec-WebSocket-Accept` = Base64(SHA1(chiave + GUID)), calcolato con
  `C4:Hash('SHA1', …, {return_encoding = 'BASE64'})` — **`'SHA1'` maiuscolo**, il minuscolo non è riconosciuto.
  I confronti sugli header non distinguono maiuscole.
- **Frame**: client → server sempre mascherati; il parser (`ws_frame.new_parser`) accetta byte a pezzi
  (anche un PING di 2 byte da solo), più frame in un pacchetto, messaggi frammentati con PING in mezzo, e
  segnala errori di protocollo (RSV, opcode, lunghezza enorme, frame di controllo frammentati).
- **Chiusura pulita**: si invia CLOSE e il TCP si abbatte dopo ~1 s; il binding resta occupato fino ad
  allora (`owners[binding]`) e la liberazione controlla di esserne ancora il proprietario. Il teardown
  immediato lasciava sulla TV una sessione "zombie" che faceva cadere subito la connessione successiva.
- `on_close` è chiamata una volta sola, con motivo `"remote"`, `"offline"` o `"error: …"`; non è chiamata
  per una `close()` voluta dal chiamante. Le callback utente sono in `pcall`.
- Un binding libero si cerca in 6100–6199 (`C4:GetBindingAddress` vuoto e non posseduto).

## 5. Protocollo Samsung: cosa abbiamo imparato

1. Il firmware chiude la sessione WebSocket ogni ~20 s (vedi 2.2).
2. Il WebSocket non distingue ON da standby (vedi 2.1).
3. Il token è numerico e va riusato come `&token=`.
4. Porta 8001 = ws plain + REST; 8002 = wss (TLS). Senza token sulla 8001 la TV risponde
   `ms.channel.unauthorized` (niente popup); il popup di pairing compare sulla 8002.
5. TV e controller nella stessa subnet: le TV rifiutano il WebSocket da subnet diverse.
6. I driver ufficiali Samsung per Control4 usano una connessione SSL sulla 1515 (protocollo proprietario non
   documentato) più IR: non è replicabile, da qui la scelta delle API della community.

## 6. DriverWorks: cose da sapere

- `require "modulo"` usa il path del driver: i file stanno alla **radice** del `.c4z` (`lib/`, `tv/`).
  `dofile` cerca nella working directory del controller e fallisce.
- Non esiste `sleep` e `C4:Let()` non blocca: ogni attesa è un timer (`lib/timer`), `OnTimerExpired` li chiude.
- Nomi dei comandi del proxy TV (con underscore): `ON`, `OFF`, `PULSE_VOL_UP/DOWN`, `START_VOL_*`, `MUTE_*`,
  `PULSE_CH_*`, `UP/DOWN/LEFT/RIGHT`, `START_*`, `START_PAGE_LEFT/RIGHT`, `ENTER`, `CANCEL`, `MENU`, `GUIDE`,
  `INFO`, `PROGRAM_A..D`, `PLAY/PAUSE/STOP/SKIP_*/SCAN_*/RECORD/PVR`, `NUMBER_0..9`. Mappa in `tv/protocol.lua`.
- Un errore non gestito in una callback interrompe in silenzio quella catena (es. il timer che riarma il
  polling): `driver.lua` avvolge ogni handler in `safe()`.

## 7. `driver.xml`: connessioni per il Navigator

Per far comparire la TV nella stanza (Watch experience), oltre al proxy TV (5000):

- **7000** `Room Selection - Output` (type 7, classi `AUDIO_SELECTION` / `AUDIO_VOLUME` / `VIDEO_SELECTION`);
- **1001–1003** ingressi HDMI (type 5): abilitano `SET_INPUT` (mappa → `KEY_HDMI1..3`);
- **4000** `Audio Output` (type 6);
- capability `reports_offline = true`, `power_management_method = ToggleCode`.

La proxy `avswitch` (5002) ha connessioni "ponte" nascoste con autobind (1102/3101 lato TV, 2110/4110 lato
switch) e **9 slot MiniApp** (3201–3209, classe `RF_MINI_APP`) per i minidriver ufficiali. ON/OFF su 5002 sono
routing e non diventano `KEY_POWER` (spegnevano la TV alla pressione di una tile).

`tests/test_driver_xml.lua` verifica che ogni proprietà usata dal Lua, ogni HDMI e ogni slot MiniApp mappati
nel codice esistano nell'XML.

## 8. Guardie sui casi limite

| Sintomo | Causa | Guardia | Dove |
|---|---|---|---|
| Falso *Power Off* da un blip di rete | una sola lettura OFF | 2 letture consecutive per ON → OFF | `samsung_tv` `apply_reading` |
| Polling fermo per sempre | connessione REST appesa, nessun evento | guardia a 10 s che riprogramma il poll | `check_reachability` |
| Check che si abortisce da solo | timer di guardia del check precedente | numero di check + cancellazione dei timer | `complete_check` |
| Falso OFF a metà risposta | timeout armato prima di `ONLINE` | timeout di 3 s solo dopo l'invio | `check_reachability` |
| Eventi fantasma all'avvio | primo check notificato | primo check senza notifica | `apply_reading` |
| Tasto che scatta minuti dopo | coda che ritenta all'infinito | scadenza 5 s, un solo timer, max 20 | `pump_queue` |
| Volume che sale senza fine | `STOP_*` perso | limite di 20 s alla ripetizione | `commands.lua` |
| Popup a ogni tasto | token non salvato (formato senza virgolette) | doppia forma in `extract_token` | `tv/protocol` |
| Connessioni che si uccidono a vicenda | `NetDisconnect` ritardato su binding riusato | binding tenuto 1 s e proprietà verificata | `lib/websocket` |
| Parsing desincronizzato | frame spezzato dal TCP | buffer incrementale, attesa dei byte mancanti | `lib/ws_frame` |
| JSON rotto verso la TV | `KeyCode` con caratteri speciali | validazione `^[%w_]+$` | `tv/protocol` |
| Popup a sorpresa sulla TV | pairing lasciato aperto | finestra di 60 s | `samsung_tv` `pair` |
| Tile MiniApp che spegne la TV | `ON/OFF` di routing sulla avswitch | solo la proxy 5000 genera `KEY_POWER` | `commands.lua` |
| Lancio app doppio | Director manda `SET_INPUT` due volte | stesso lancio ignorato entro 3 s | `commands.lua` |
| Token nelle issue pubbliche | URL e messaggi loggati | `util.redact` in ogni riga di log | `lib/log` |
| Errore silenzioso in un timer | eccezione non gestita | `safe()` con `pcall`, sempre visibile | `driver.lua` |

## 9. Log

Livelli `0 Alert … 5 Debug` (un messaggio di severità *S* è emesso se *S* ≤ `Log Level`), modi `Off` / `Print` /
`Log` / `Print and Log`. Tag: `[REST]` stato, `[WS]` WebSocket, `[PAIR]` abbinamento, `[CMD]` comandi, `[APP]`
lancio app, `[LIFECYCLE]` ciclo di vita, `[DRIVER]` errori non gestiti. A livello Info compaiono solo gli
eventi rilevanti; il routing di Director è visibile da Trace, ogni check REST da Debug.

## 10. Test

`./tools/run_tests.ps1` (LuaJIT = Lua 5.1, come DriverWorks): sintassi di tutti i sorgenti, lint dei moduli
puri, poi un processo per ogni `tests/test_*.lua`. `tests/support/fake_c4.lua` simula `C4` (timer con orologio
simulato, rete, persistenza, SHA1/Base64 reali) e `tests/support/ws_server.lua` fa da "TV" per handshake e
frame. Non si testa offline il dialogo con una TV reale: prima di una release si prova su hardware.

## 11. Riferimenti

- [Documentazione DriverWorks API](https://control4.github.io/docs-driverworks-api/)
- [Comandi dei proxy TV](https://snap-one.github.io/docs-driverworks-proxyprotocol-tv/#tv-proxy-commands)
- [RFC 6455 — The WebSocket Protocol](https://www.rfc-editor.org/rfc/rfc6455)
- [Samsung Smart TV API references](https://developer.samsung.com/smarttv/develop/api-references/samsung-product-api-references.html)
- Community: [samsungtvws](https://github.com/xchwarze/samsung-tv-ws-api),
  [Home Assistant `samsungtv`](https://www.home-assistant.io/integrations/samsungtv/),
  [openHAB Samsung TV binding](https://community.openhab.org/t/samsung-tv-binding-beta/130551)
