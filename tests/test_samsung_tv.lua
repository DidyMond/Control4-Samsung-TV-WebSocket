-- Test di tv/samsung_tv.lua: polling REST, WebSocket, pairing, coda comandi, lancio app
local t = require "tests.support.harness"
local fake = require "tests.support.fake_c4"
local server = require "tests.support.ws_server"

local TOKEN = "12345678"
local ON_BODY = 'HTTP/1.1 200 OK\r\n\r\n{"device":{"PowerState":"on"}}'
local STANDBY_BODY = 'HTTP/1.1 200 OK\r\n\r\n{"device":{"PowerState":"standby"}}'

local function setup(opts)
	opts = opts or {}
	local env = fake.install()
	if opts.paired ~= false then env.persist.AuthToken = TOKEN end
	local tv = require "tv.samsung_tv"
	tv.set_clock(function() return math.floor(env.now / 1000) end)
	return env, tv
end

-- Esegue un check REST completo; body = nil -> connessione rifiutata (OFFLINE)
local function run_check(env, tv, body)
	tv.check_reachability()
	if body then
		env.deliver_status(6099, "ONLINE")
		env.deliver_data(6099, body)
		env.advance(200)
	else
		env.deliver_status(6099, "OFFLINE")
	end
end

local function notifications(env)
	local out = {}
	for _, p in ipairs(env.proxy) do out[#out + 1] = p.command end
	return out
end

local function count_connects(env, binding)
	local n = 0
	for _, c in ipairs(env.connects) do
		if c.binding == binding then n = n + 1 end
	end
	return n
end

local function logged(env)
	return table.concat(env.printed, "\n")
end

-- Porta il WebSocket fino a "autorizzato" (ms.channel.connect ricevuto)
local function connect_ws(env, tv, connect_message)
	tv.connect()
	local binding = 6100
	env.deliver_status(binding, "ONLINE")
	local request = env.last_sent(binding)
	env.deliver_data(binding, server.upgrade_response(request))
	env.deliver_data(binding, server.text(connect_message or '{"event":"ms.channel.connect","data":{"token":"' .. TOKEN .. '"}}'))
	return binding, request
end

-- ------------------------------------------------------------
-- REST
-- ------------------------------------------------------------
t.test("REST: richiesta GET /api/v2/ sulla 8001 e stato ON; al primo check nessuna notifica", function()
	local env, tv = setup()
	tv.check_reachability()
	t.eq(env.conns[6099].host, "192.168.1.50")
	t.eq(env.connects[1].port, 8001)
	env.deliver_status(6099, "ONLINE")
	t.contains(env.last_sent(6099), "GET /api/v2/ HTTP/1.1\r\nHost: 192.168.1.50:8001\r\nConnection: close")
	env.deliver_data(6099, ON_BODY)
	env.advance(200)
	t.eq(tv.power(), "ON")
	t.eq(#env.proxy, 0, "stato iniziale sincronizzato senza notifica")
end)

t.test("REST: polling adattivo, 2 s a TV accesa e 10 s a TV spenta", function()
	local env, tv = setup()
	run_check(env, tv, ON_BODY)
	local n = count_connects(env, 6099)
	env.advance(1999)
	t.eq(count_connects(env, 6099), n)
	env.advance(1)
	t.eq(count_connects(env, 6099), n + 1, "nuovo check dopo 2 s")

	local env2, tv2 = setup()
	run_check(env2, tv2, STANDBY_BODY)
	t.eq(tv2.power(), "OFF")
	n = count_connects(env2, 6099)
	env2.advance(9999)
	t.eq(count_connects(env2, 6099), n)
	env2.advance(1)
	t.eq(count_connects(env2, 6099), n + 1, "nuovo check dopo 10 s")
end)

t.test("REST: primo check OFF -> stato OFF senza notifica", function()
	local env, tv = setup()
	run_check(env, tv, STANDBY_BODY)
	t.eq(tv.power(), "OFF")
	t.eq(#env.proxy, 0)
end)

t.test("REST: OFF -> ON notifica subito; ON -> OFF solo alla seconda lettura OFF", function()
	local env, tv = setup()
	run_check(env, tv, STANDBY_BODY)
	run_check(env, tv, ON_BODY)
	t.same(notifications(env), { "ON" })

	run_check(env, tv, STANDBY_BODY)
	t.eq(tv.power(), "ON", "una lettura OFF isolata non spegne")
	t.same(notifications(env), { "ON" })
	run_check(env, tv, STANDBY_BODY)
	t.eq(tv.power(), "OFF")
	t.same(notifications(env), { "ON", "OFF" })
	t.eq(env.proxy[2].binding, 5000)
	t.eq(env.proxy[2].notify, "NOTIFY")
end)

t.test("REST: una lettura ON azzera la conferma OFF (OFF, ON, OFF non spegne)", function()
	local env, tv = setup()
	run_check(env, tv, ON_BODY)
	run_check(env, tv, nil)
	run_check(env, tv, ON_BODY)
	run_check(env, tv, nil)
	t.eq(tv.power(), "ON")
	t.eq(#env.proxy, 0)
end)

t.test("REST: connessione rifiutata (TV spenta del tutto) conta come OFF", function()
	local env, tv = setup()
	run_check(env, tv, ON_BODY)
	run_check(env, tv, nil)
	run_check(env, tv, nil)
	t.eq(tv.power(), "OFF")
	t.same(notifications(env), { "OFF" })
end)

t.test("REST: finito un check non resta nessun timer di guardia orfano (regressione falsi OFF)", function()
	local env, tv = setup()
	run_check(env, tv, ON_BODY)
	-- prima il timer di guardia a 10 s restava vivo e poteva far fallire il check successivo
	t.eq(env.pending_timers(), 1, "solo il timer del prossimo poll")
end)

t.test("REST: connessione appesa senza eventi -> guardia a 10 s, il polling riparte", function()
	local env, tv = setup()
	run_check(env, tv, ON_BODY)
	env.advance(2000) -- parte il check successivo e non riceve nessun evento
	local n = count_connects(env, 6099)
	env.advance(9999)
	t.eq(count_connects(env, 6099), n)
	env.advance(1)
	t.contains(logged(env), "timed out")
	-- il ciclo non si e' fermato: il poll successivo parte da solo
	env.advance(2000)
	t.eq(count_connects(env, 6099), n + 1)
end)

t.test("REST: nessuna risposta entro 3 s dopo ONLINE", function()
	local env, tv = setup()
	run_check(env, tv, ON_BODY)
	env.advance(2000)
	env.deliver_status(6099, "ONLINE")
	env.advance(2999)
	t.falsy(logged(env):find("no response within 3 s", 1, true))
	env.advance(1)
	t.contains(logged(env), "no response within 3 s")
end)

t.test("REST: la risposta in arrivo a 2,9 s non viene scambiata per timeout", function()
	local env, tv = setup()
	tv.check_reachability()
	env.deliver_status(6099, "ONLINE")
	env.advance(2900)
	env.deliver_data(6099, ON_BODY)
	env.advance(200)
	t.eq(tv.power(), "ON")
	t.falsy(logged(env):find("no response", 1, true))
end)

t.test("REST: risposta a pezzi viene riunita (silenzio di 200 ms = fine)", function()
	local env, tv = setup()
	tv.check_reachability()
	env.deliver_status(6099, "ONLINE")
	env.deliver_data(6099, "HTTP/1.1 200 OK\r\n\r\n{\"device\":{\"Pow")
	env.advance(50)
	env.deliver_data(6099, "erState\":\"on\"}}")
	env.advance(200)
	t.eq(tv.power(), "ON")
end)

t.test("REST: dati e stati in ritardo di un check chiuso vengono ignorati", function()
	local env, tv = setup()
	run_check(env, tv, ON_BODY)
	t.falsy(env.deliver_data(6099, STANDBY_BODY), "nessun handler dopo la chiusura")
	t.falsy(env.deliver_status(6099, "OFFLINE"))
	t.eq(tv.power(), "ON")
end)

t.test("REST: IP non configurato -> nessun check e polling fermo", function()
	local env, tv = setup()
	Properties["IP Address"] = ""
	tv.check_reachability()
	t.eq(#env.connects, 0)
	t.eq(env.pending_timers(), 0)
end)

t.test("reset_power: dopo un cambio di IP il primo check non notifica", function()
	local env, tv = setup()
	run_check(env, tv, ON_BODY)
	tv.reset_power()
	run_check(env, tv, STANDBY_BODY)
	t.eq(tv.power(), "OFF")
	t.eq(#env.proxy, 0)
end)

-- ------------------------------------------------------------
-- WebSocket, coda comandi, pairing
-- ------------------------------------------------------------
t.test("WS: URL con nome in Base64 e token; wss sulla 8002 con opzioni SSL", function()
	local env, tv = setup()
	tv.connect()
	t.eq(env.conns[6100].ssl, "SSL")
	t.eq(env.conns[6100].options.verify_mode, "none")
	env.deliver_status(6100, "ONLINE")
	local request = env.last_sent(6100)
	t.contains(request, "GET /api/v2/channels/samsung.remote.control?name=" .. fake.base64("Control4-TV")
		.. "&token=" .. TOKEN .. " HTTP/1.1")
end)

t.test("WS: porta 8001 -> ws:// senza SSL", function()
	local env, tv = setup()
	Properties["Port"] = "8001"
	tv.connect()
	t.eq(env.conns[6100].ssl, nil)
	t.eq(env.connects[1].port, 8001)
end)

t.test("WS: invio tasto: payload ms.remote.control nel frame", function()
	local env, tv = setup()
	local binding = connect_ws(env, tv)
	t.truthy(tv.send_key("KEY_VOLUP"))
	local opcode, payload = server.decode_client_frame(env.last_sent(binding))
	t.eq(opcode, 1)
	t.contains(payload, '"DataOfCmd": "KEY_VOLUP"')
	t.contains(payload, '"method": "ms.remote.control"')
end)

t.test("coda: tasto messo in coda parte appena la TV autorizza; piu' tasti a 200 ms", function()
	local env, tv = setup()
	t.truthy(tv.send_key("KEY_MUTE"))
	t.truthy(tv.send_key("KEY_VOLUP"))
	t.eq(#env.connects, 1, "una sola connessione WS")
	local binding = 6100
	env.deliver_status(binding, "ONLINE")
	env.deliver_data(binding, server.upgrade_response(env.last_sent(binding)))
	local sent_before = #env.sent[binding]
	env.deliver_data(binding, server.text('{"event":"ms.channel.connect"}'))
	t.eq(#env.sent[binding], sent_before + 1, "primo tasto subito")
	env.advance(200)
	t.eq(#env.sent[binding], sent_before + 2, "secondo tasto dopo 200 ms")
	local _, payload = server.decode_client_frame(env.last_sent(binding))
	t.contains(payload, "KEY_VOLUP")
end)

t.test("coda: un tasto non inviabile entro 5 s viene scartato e i timer finiscono", function()
	local env, tv = setup()
	tv.send_key("KEY_MUTE") -- la TV non risponde mai
	env.advance(5000)
	t.falsy(logged(env):find("dropped KEY_MUTE", 1, true), "ancora dentro i 5 s")
	env.advance(1500)
	t.contains(logged(env), "dropped KEY_MUTE")
	-- resta solo il timeout di connessione WS (15 s): niente cicli di retry
	env.advance(1000)
	t.eq(env.pending_timers() <= 1, true)
end)

t.test("coda: chiamate ravvicinate non moltiplicano i cicli di retry", function()
	local env, tv = setup()
	for _ = 1, 10 do tv.send_key("KEY_VOLUP") end
	-- un timer di retry della coda + il timeout di connessione
	t.eq(env.pending_timers(), 2)
end)

t.test("coda: dimensione massima", function()
	local env, tv = setup()
	for i = 1, 20 do t.truthy(tv.send_key("KEY_VOLUP"), "tasto " .. i) end
	t.falsy(tv.send_key("KEY_VOLUP"))
	t.contains(logged(env), "queue full")
end)

t.test("coda: codice tasto non valido rifiutato (niente JSON rotto verso la TV)", function()
	local env, tv = setup()
	t.falsy(tv.send_key('KEY_X"}'))
	t.falsy(tv.send_key(nil))
	t.contains(logged(env), "invalid key code")
	t.eq(#env.connects, 0)
end)

t.test("coda: driver non abbinato -> comando scartato subito, nessun retry infinito", function()
	local env, tv = setup({ paired = false })
	tv.send_key("KEY_MUTE")
	t.eq(#env.connects, 0)
	t.contains(logged(env), "dropped 1 queued command")
	t.eq(env.pending_timers(), 0)
end)

t.test("WS: chiusura dalla TV -> controllo REST immediato", function()
	local env, tv = setup()
	local binding = connect_ws(env, tv)
	local before = count_connects(env, 6099)
	env.deliver_data(binding, server.frame(0x8, "\3\232"))
	t.eq(count_connects(env, 6099), before + 1)
end)

t.test("WS: timeout di connessione a 15 s chiude il socket; un tentativo riuscito non lo subisce", function()
	local env, tv = setup()
	tv.connect() -- nessun evento dalla rete
	env.advance(14999)
	t.falsy(logged(env):find("timed out after 15 s", 1, true))
	env.advance(1)
	t.contains(logged(env), "timed out after 15 s")
	t.eq(env.disconnects[#env.disconnects].binding, 6100)

	local env2, tv2 = setup()
	connect_ws(env2, tv2) -- si apre regolarmente
	env2.advance(30000)
	t.falsy(logged(env2):find("timed out after 15 s", 1, true))
end)

t.test("WS: token respinto (ms.channel.unauthorized) -> token cancellato, coda svuotata", function()
	local env, tv = setup()
	tv.send_key("KEY_MUTE")
	tv.connect()
	env.deliver_status(6100, "ONLINE")
	env.deliver_data(6100, server.upgrade_response(env.last_sent(6100)))
	env.deliver_data(6100, server.text('{"event":"ms.channel.unauthorized"}'))
	t.eq(env.persist.AuthToken, "")
	t.eq(Properties["Pairing Status"], "Not paired")
	t.falsy(tv.is_paired())
	env.advance(1000)
	t.eq(#env.sent[6100], 1, "solo l'handshake, nessun tasto inviato")
end)

t.test("pairing: connessione senza token, token salvato, stato Paired, finestra chiusa", function()
	local env, tv = setup({ paired = false })
	tv.pair()
	env.deliver_status(6100, "ONLINE")
	local request = env.last_sent(6100)
	t.falsy(request:find("token=", 1, true), "in pairing si connette senza token")
	env.deliver_data(6100, server.upgrade_response(request))
	env.deliver_data(6100, server.text('{"event":"ms.channel.connect","data":{"token":"' .. TOKEN .. '"}}'))
	t.eq(env.persist.AuthToken, TOKEN)
	t.eq(Properties["Pairing Status"], "Paired")
	t.truthy(tv.is_paired())

	-- le connessioni successive portano il token
	env.deliver_data(6100, server.frame(0x8, "\3\232")) -- la TV chiude
	env.advance(1000)
	tv.connect() -- il binding 6100 e' stato liberato ed e' di nuovo disponibile
	env.deliver_status(6100, "ONLINE")
	t.contains(env.last_sent(6100), "&token=" .. TOKEN)
end)

t.test("pairing: la finestra scade dopo 60 s senza conferma", function()
	local env, tv = setup({ paired = false })
	tv.pair()
	env.advance(60000)
	t.contains(logged(env), "pairing window expired")
	local before = #env.connects
	tv.connect() -- ora senza token e fuori dal pairing: non si connette
	t.eq(#env.connects, before)
end)

t.test("unpair: token e stato azzerati, socket chiuso", function()
	local env, tv = setup()
	local binding = connect_ws(env, tv)
	tv.unpair()
	t.eq(env.persist.AuthToken, "")
	t.eq(Properties["Pairing Status"], "Not paired")
	env.advance(1000)
	t.eq(env.disconnects[#env.disconnects].binding, binding)
end)

t.test("il token non compare mai nei log, nemmeno a livello Debug", function()
	local env, tv = setup()
	connect_ws(env, tv)
	tv.send_key("KEY_MUTE")
	local env2, tv2 = setup({ paired = false })
	tv2.pair()
	env2.deliver_status(6100, "ONLINE")
	env2.deliver_data(6100, server.upgrade_response(env2.last_sent(6100)))
	env2.deliver_data(6100, server.text('{"event":"ms.channel.connect","data":{"token":"' .. TOKEN .. '"}}'))
	for _, e in ipairs({ env, env2 }) do
		t.falsy(logged(e):find(TOKEN, 1, true), "token nei log")
		for _, line in ipairs(e.errorlog) do t.falsy(line:find(TOKEN, 1, true)) end
	end
	t.contains(logged(env2), "token received and saved")
end)

-- ------------------------------------------------------------
-- Lancio app
-- ------------------------------------------------------------
t.test("launch_app: POST HTTPS sulla 8002 con l'id dell'app, poi binding liberato", function()
	local env, tv = setup()
	t.truthy(tv.launch_app("Netflix"))
	t.eq(env.conns[6098].ssl, "SSL")
	t.eq(env.conns[6098].options.method, "tlsv1_2")
	t.eq(env.connects[1].port, 8002)
	env.deliver_status(6098, "ONLINE")
	t.contains(env.last_sent(6098), "POST /api/v2/applications/3201907018807 HTTP/1.1\r\nHost: 192.168.1.50:8002\r\n")
	env.deliver_data(6098, "HTTP/1.1 200 OK\r\n\r\n")
	t.eq(env.disconnects[#env.disconnects].binding, 6098)
	t.falsy(require("lib.net").is_registered(6098))
	t.eq(env.pending_timers(), 0, "il timer di timeout e' stato cancellato")
end)

t.test("launch_app: app sconosciuta, IP mancante, risposta d'errore, timeout, connessione rifiutata", function()
	local env, tv = setup()
	t.falsy(tv.launch_app("Sconosciuta"))
	t.contains(logged(env), "not mapped")

	tv.launch_app("YouTube")
	env.deliver_status(6098, "ONLINE")
	env.deliver_data(6098, "HTTP/1.1 500 Internal Server Error\r\n\r\n")
	t.contains(logged(env), "HTTP 500")

	tv.launch_app("YouTube")
	env.deliver_status(6098, "ONLINE")
	env.advance(5000)
	t.contains(logged(env), "timed out")

	tv.launch_app("YouTube")
	env.deliver_status(6098, "OFFLINE")
	t.contains(logged(env), "connection refused")

	Properties["IP Address"] = ""
	t.falsy(tv.launch_app("YouTube"))
end)

t.test("launch_app_when_on: TV accesa -> subito", function()
	local env, tv = setup()
	run_check(env, tv, ON_BODY)
	local before = #env.connects
	tv.launch_app_when_on("Netflix")
	t.eq(env.conns[6098].host, "192.168.1.50")
	t.eq(#env.connects, before + 1)
end)

t.test("launch_app_when_on: TV spenta -> attende l'accensione e poi lancia", function()
	local env, tv = setup()
	run_check(env, tv, STANDBY_BODY)
	tv.launch_app_when_on("Netflix")
	t.eq(env.conns[6098], nil)
	env.advance(1500) -- primo tentativo: forza un check REST
	run_check(env, tv, ON_BODY)
	env.advance(1500)
	t.truthy(env.conns[6098], "app lanciata dopo l'accensione")
end)

t.test("launch_app_when_on: rinuncia dopo 10 tentativi", function()
	local env, tv = setup()
	run_check(env, tv, STANDBY_BODY)
	tv.launch_app_when_on("Netflix")
	for _ = 1, 12 do
		env.advance(1500)
		if env.conns[6099] and env.deliver_status(6099, "OFFLINE") then end
	end
	t.eq(env.conns[6098], nil)
	t.contains(logged(env), "did not turn on in time")
end)

-- ------------------------------------------------------------
t.test("shutdown: nessun timer rimasto", function()
	local env, tv = setup()
	run_check(env, tv, ON_BODY)
	tv.send_key("KEY_MUTE")
	tv.pair()
	tv.shutdown()
	t.eq(env.pending_timers(), 0)
end)

t.test("start: avvia subito il polling REST e, se abbinati, la connessione WebSocket", function()
	local env, tv = setup()
	tv.start()
	t.eq(count_connects(env, 6099), 1)
	t.eq(count_connects(env, 6100), 1)
	t.eq(Properties["Pairing Status"], "Paired")

	local env2, tv2 = setup({ paired = false })
	tv2.start()
	t.eq(count_connects(env2, 6099), 1)
	t.eq(count_connects(env2, 6100), 0)
	t.eq(Properties["Pairing Status"], "Not paired")
end)

t.finish()
