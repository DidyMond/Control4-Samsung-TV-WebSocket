-- ============================================================
-- tv/samsung_tv.lua - logica di comunicazione con la TV Samsung (Tizen)
--
-- Tre canali (vedi docs/ARCHITECTURE.md):
--   REST http  :8001  stato ON/OFF (PowerState), polling adattivo
--   WebSocket  :8001/:8002  telecomando, aperto on-demand
--   REST https :8002  lancio applicazioni
--
-- Lo stato interno e' locale al modulo; driver.lua e commands.lua usano
-- solo l'API pubblica (M.*).
-- ============================================================

local log = require "lib.log"
local timer = require "lib.timer"
local net = require "lib.net"
local util = require "lib.util"
local WebSocket = require "lib.websocket"
local protocol = require "tv.protocol"

local M = {}

-- Binding dinamici di rete riservati al driver (il WebSocket usa 6100-6199)
local REST_BINDING, REST_PORT = 6099, 8001
local APP_BINDING, APP_PORT = 6098, 8002

local POLL_ON_MS = 2000   -- TV accesa: controlla spesso per vedere lo spegnimento
local POLL_OFF_MS = 10000 -- TV spenta: basta vedere la riaccensione
local REST_RESPONSE_TIMEOUT_MS = 3000 -- dopo ONLINE e invio della richiesta
local REST_SETTLE_MS = 200            -- silenzio dopo il primo byte = risposta completa
local REST_GUARD_MS = 10000           -- rete bloccata senza ONLINE/OFFLINE
local APP_TIMEOUT_MS = 5000
local WS_CONNECT_TIMEOUT_MS = 15000
local PAIRING_WINDOW_MS = 60000

-- Dopo il lancio di un'app la si controlla ogni 3 s per sapere quando passa
-- in primo piano e quando ne esce (visible = false, running resta true).
local WATCH_INTERVAL_MS = 3000
local WATCH_GRACE_S = 30    -- tempo concesso all'app per arrivare in primo piano
local WATCH_MAX_MISSES = 3  -- risposte mancate di fila prima di darla per uscita

-- Una lettura "OFF" isolata (timeout, connessione rifiutata) non basta a
-- dichiarare spenta una TV accesa: un blip di rete accenderebbe le luci del
-- percorso notturno. Servono due letture OFF consecutive per ON -> OFF.
local REQUIRED_OFF_CONFIRMATIONS = 2

-- Coda comandi: un tasto che non parte entro 5 s viene scartato, cosi' un
-- "volume su" premuto a TV irraggiungibile non scatta minuti dopo.
local QUEUE_MAX_AGE_S = 5
local QUEUE_MAX_SIZE = 20
local QUEUE_RETRY_MS = 500
local QUEUE_SPACING_MS = 200

-- La TV usa certificati autofirmati
local SSL_OPTIONS = { verify_mode = "none", method = "tlsv1_2" }

-- ------------------------------------------------------------
-- Stato
-- ------------------------------------------------------------
local power = "UNKNOWN" -- UNKNOWN | ON | OFF

local rest = {
	busy = false, -- un check e' in corso
	gen = 0,      -- numero del check corrente: le callback di check vecchi si ignorano
	poll = nil,   -- timer del prossimo check
	timers = {},  -- timer del check in corso (guardia, timeout, attesa risposta)
	off_count = 0,
}

local conn = {
	ws = nil,
	connecting = false,
	authorized = false,
	pairing = false,
	gen = 0,
	timer = nil,
	pair_timer = nil,
}

local queue = {}
local pump_timer = nil

local foreground = nil -- app sotto controllo: { app, opened, since, misses, timer }
local stop_watch -- dichiarata sotto, serve a apply_reading

-- Orologio in secondi (sostituibile nei test: il tempo simulato non sposta os.time)
local now = os.time

function M.set_clock(fn)
	now = fn
end

-- ------------------------------------------------------------
-- Utility
-- ------------------------------------------------------------
local function get_ip()
	local ip = Properties["IP Address"]
	if util.is_blank(ip) then return nil end
	return (ip:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function get_token()
	local token = C4:PersistGetValue("AuthToken")
	if util.is_blank(token) then return nil end
	return token
end

local function refresh_pairing_status()
	C4:UpdateProperty("Pairing Status", get_token() and "Paired" or "Not paired")
end

local function set_token(token)
	C4:PersistSetValue("AuthToken", token or "")
	refresh_pairing_status()
end

local function cancel(handle)
	if handle then handle:cancel() end
	return nil
end

function M.power()
	return power
end

function M.is_paired()
	return get_token() ~= nil
end

-- Cambio di TV (IP): lo stato noto non vale piu' e il primo check del nuovo
-- indirizzo non deve generare eventi Power On / Power Off.
function M.reset_power()
	power = "UNKNOWN"
	rest.off_count = 0
end

function M.refresh_pairing_status()
	refresh_pairing_status()
end

-- ------------------------------------------------------------
-- REST: stato ON/OFF
-- ------------------------------------------------------------
local function cancel_rest_timers()
	for _, t in ipairs(rest.timers) do t:cancel() end
	rest.timers = {}
end

local function add_rest_timer(ms, fn)
	local t = timer.after(ms, fn)
	rest.timers[#rest.timers + 1] = t
	return t
end

local function release_rest_binding()
	net.unregister(REST_BINDING)
	C4:NetDisconnect(REST_BINDING, REST_PORT)
	C4:SetBindingAddress(REST_BINDING, "")
end

local function schedule_poll()
	rest.poll = cancel(rest.poll)
	local interval = (power == "OFF") and POLL_OFF_MS or POLL_ON_MS
	rest.poll = timer.after(interval, function()
		rest.poll = nil
		M.check_reachability()
	end)
end

local function apply_reading(body)
	local reading, reason = protocol.parse_power_state(body)

	if reading == "OFF" then
		rest.off_count = rest.off_count + 1
	else
		rest.off_count = 0
	end

	if reading == "OFF" and power == "ON" and rest.off_count < REQUIRED_OFF_CONFIRMATIONS then
		log.debug("REST", "possible OFF not confirmed (" .. rest.off_count .. "/" ..
			REQUIRED_OFF_CONFIRMATIONS .. "), staying ON")
		reading = "ON"
	end

	log.debug("REST", "check -> " .. reading .. " (" .. reason .. ")")

	if reading ~= power then
		local first = (power == "UNKNOWN")
		power = reading
		log.info("REST", "state -> " .. power)
		if power == "OFF" then stop_watch() end
		if first then
			-- al primo check (avvio del driver) si sincronizza lo stato senza
			-- notificarlo: niente eventi fantasma Power On / Power Off
			log.info("REST", "initial state synchronised (no notification)")
		else
			C4:SendToProxy(protocol.TV_PROXY, power, {}, "NOTIFY")
		end
	end

	schedule_poll()
end

-- Chiude il check `gen` con la risposta ricevuta ("" = nessuna risposta).
-- Ignora i check gia' chiusi o sostituiti: e' questo che impedisce a un
-- timer di un check vecchio di far fallire quello in corso.
local function complete_check(gen, body)
	if gen ~= rest.gen or not rest.busy then return end
	cancel_rest_timers()
	release_rest_binding()
	rest.busy = false
	apply_reading(body)
end

function M.check_reachability()
	if rest.busy then
		log.trace("REST", "check already running, skipped")
		return
	end

	local host = get_ip()
	if not host then
		log.warn("REST", "IP Address not set, polling stopped")
		rest.poll = cancel(rest.poll)
		return
	end

	rest.busy = true
	rest.gen = rest.gen + 1
	local gen = rest.gen
	local buffer = ""
	local response_timer

	-- Guardia: se la connessione resta appesa senza mai arrivare a ONLINE o
	-- OFFLINE, nessun altro timeout parte. Senza chiudere il check e
	-- riprogrammare il poll il ciclo si fermerebbe per sempre, in silenzio.
	add_rest_timer(REST_GUARD_MS, function()
		log.warn("REST", "check timed out (10 s, no network event), polling restarts")
		complete_check(gen, "")
	end)

	release_rest_binding()
	C4:CreateNetworkConnection(REST_BINDING, host)

	net.register(REST_BINDING,
		function(_, _, status)
			if gen ~= rest.gen then return end
			if status == "ONLINE" then
				C4:SendToNetwork(REST_BINDING, REST_PORT,
					"GET /api/v2/ HTTP/1.1\r\nHost: " .. host .. ":" .. REST_PORT ..
					"\r\nConnection: close\r\n\r\n")
				response_timer = add_rest_timer(REST_RESPONSE_TIMEOUT_MS, function()
					log.warn("REST", "no response within 3 s")
					complete_check(gen, "")
				end)
			elseif status == "OFFLINE" then
				log.debug("REST", "connection closed (TV off or unreachable)")
				complete_check(gen, buffer)
			end
		end,
		function(_, _, data)
			if gen ~= rest.gen then return end
			local first = (buffer == "")
			buffer = buffer .. data
			if first then
				if response_timer then response_timer:cancel() end
				add_rest_timer(REST_SETTLE_MS, function() complete_check(gen, buffer) end)
			end
		end)

	C4:NetConnect(REST_BINDING, REST_PORT)
end

-- ------------------------------------------------------------
-- WebSocket: telecomando e pairing
-- ------------------------------------------------------------
local function build_ws_url()
	local port = Properties["Port"]
	local scheme = (port == "8002") and "wss" or "ws"
	local url = scheme .. "://" .. get_ip() .. ":" .. port ..
		"/api/v2/channels/samsung.remote.control?name=" .. C4:Base64Encode(Properties["Device Name"])

	-- in pairing si connette senza token: e' cio' che fa comparire il popup
	local token = get_token()
	if token and not conn.pairing then
		url = url .. "&token=" .. token
	end
	return url
end

local function drop_ws()
	conn.timer = cancel(conn.timer)
	if conn.ws then
		conn.ws:close()
		conn.ws = nil
	end
	conn.connecting = false
	conn.authorized = false
end

local function end_pairing()
	conn.pairing = false
	conn.pair_timer = cancel(conn.pair_timer)
end

local function clear_queue(reason)
	if #queue > 0 then
		log.warn("CMD", "dropped " .. #queue .. " queued command(s): " .. reason)
	end
	queue = {}
	pump_timer = cancel(pump_timer)
end

local function on_ws_message(ws, data)
	if ws ~= conn.ws then return end
	log.trace("WS", "RX: " .. data)

	if data:find("ms.channel.connect", 1, true) then
		conn.authorized = true
		local token = protocol.extract_token(data)
		if token then
			set_token(token)
			log.info("PAIR", "token received and saved")
			if conn.pairing then
				end_pairing()
				log.info("PAIR", "pairing completed")
			end
		end
		M.pump_queue()
	elseif data:find("ms.channel.unauthorized", 1, true) then
		conn.authorized = false
		clear_queue("TV rejected the token")
		log.error("PAIR", "token rejected by the TV, pair again")
		set_token(nil)
		end_pairing()
	end
end

function M.connect()
	if conn.connecting then
		log.trace("WS", "connection already in progress")
		return
	end
	if not get_ip() then
		log.warn("WS", "IP Address not set, no WebSocket connection")
		return
	end
	if not conn.pairing and not get_token() then
		log.warn("PAIR", "not paired: set Pairing to 'Pair with TV'")
		return
	end

	drop_ws()
	conn.connecting = true
	conn.gen = conn.gen + 1
	local gen = conn.gen

	local url = build_ws_url()
	local ws, err = WebSocket.new(url, {
		ssl_options = (Properties["Port"] == "8002") and SSL_OPTIONS or nil,
		on_open = function(this)
			if this ~= conn.ws then return end
			conn.connecting = false
			conn.timer = cancel(conn.timer)
			log.info("WS", "handshake completed")
		end,
		on_message = on_ws_message,
		on_close = function(this, reason)
			if this ~= conn.ws then return end
			log.debug("WS", "closed (" .. tostring(reason) .. "), checking REST state")
			conn.ws = nil
			conn.connecting = false
			conn.authorized = false
			conn.timer = cancel(conn.timer)
			M.check_reachability()
		end,
	})
	if not ws then
		log.error("WS", tostring(err))
		conn.connecting = false
		return
	end

	conn.ws = ws
	log.info("WS", "connecting to " .. url)
	ws:connect()

	if conn.connecting and gen == conn.gen then
		conn.timer = timer.after(WS_CONNECT_TIMEOUT_MS, function()
			if gen == conn.gen and conn.connecting then
				log.error("WS", "connection timed out after 15 s")
				drop_ws()
			end
		end)
	end
end

-- Nuova connessione anche se una e' in corso (cambio IP, porta, nome...)
function M.reconnect()
	conn.connecting = false
	M.connect()
end

function M.pair()
	log.info("PAIR", "pairing requested")
	set_token(nil)
	conn.pairing = true
	conn.pair_timer = cancel(conn.pair_timer)
	-- la finestra di pairing si chiude da sola: senza, una connessione
	-- successiva senza token farebbe comparire un popup a sorpresa sulla TV
	conn.pair_timer = timer.after(PAIRING_WINDOW_MS, function()
		conn.pair_timer = nil
		if conn.pairing then
			conn.pairing = false
			log.warn("PAIR", "pairing window expired without confirmation on the TV")
		end
	end)
	M.reconnect()
end

function M.unpair()
	log.info("PAIR", "unpair requested")
	end_pairing()
	set_token(nil)
	drop_ws()
	clear_queue("unpaired")
	log.info("PAIR", "token removed; use 'Pair with TV' to pair again")
end

-- ------------------------------------------------------------
-- Invio tasti (coda)
-- ------------------------------------------------------------
local function ws_ready()
	return conn.ws ~= nil and conn.ws:is_open() and conn.authorized
end

local function send_key_now(keyCode)
	if conn.ws and conn.ws:send_text(protocol.remote_key_payload(keyCode)) then
		log.info("CMD", "key sent -> " .. keyCode)
	end
end

-- Svuota la coda un tasto alla volta. C'e' al piu' un timer attivo: ogni
-- chiamata annulla quello pendente, cosi' le richieste ravvicinate non
-- moltiplicano i cicli di ripetizione.
function M.pump_queue()
	pump_timer = cancel(pump_timer)

	local t = now()
	while queue[1] and (t - queue[1].at) > QUEUE_MAX_AGE_S do
		log.warn("CMD", "dropped " .. queue[1].key .. " (TV not ready within " .. QUEUE_MAX_AGE_S .. " s)")
		table.remove(queue, 1)
	end
	if #queue == 0 then return end

	if ws_ready() then
		local item = table.remove(queue, 1)
		send_key_now(item.key)
		if #queue > 0 then
			pump_timer = timer.after(QUEUE_SPACING_MS, M.pump_queue)
		end
		return
	end

	if not get_ip() or (not conn.pairing and not get_token()) then
		clear_queue("driver not configured or not paired")
		return
	end
	if not conn.connecting and not (conn.ws and conn.ws:is_connected()) then
		M.connect()
	end
	pump_timer = timer.after(QUEUE_RETRY_MS, M.pump_queue)
end

function M.send_key(keyCode)
	if not protocol.is_valid_key(keyCode) then
		log.warn("CMD", "invalid key code ignored: " .. tostring(keyCode))
		return false
	end
	if #queue >= QUEUE_MAX_SIZE then
		log.warn("CMD", "command queue full, " .. keyCode .. " dropped")
		return false
	end
	queue[#queue + 1] = { key = keyCode, at = now() }
	M.pump_queue()
	return true
end

-- ------------------------------------------------------------
-- HTTPS verso la TV (porta 8002, binding 6098): uno scambio per volta
--   opts.request     richiesta HTTP completa
--   opts.settle_ms   nil = la prima risposta chiude lo scambio; altrimenti si
--                    attende questo silenzio per riunire la risposta a pezzi
--   opts.on_response(data), opts.on_timeout(), opts.on_refused()
-- ------------------------------------------------------------
local active_exchange = nil

local function https_exchange(host, opts)
	local done = false
	local timers = {}
	local buffer = ""
	local handle = {}

	local function release()
		net.unregister(APP_BINDING)
		C4:NetDisconnect(APP_BINDING, APP_PORT)
		C4:SetBindingAddress(APP_BINDING, "")
	end

	local function stop_timers()
		for _, t in ipairs(timers) do t:cancel() end
		timers = {}
	end

	local function finish()
		done = true
		stop_timers()
		if active_exchange == handle then active_exchange = nil end
		release()
	end

	-- Un nuovo scambio sostituisce quello in corso: senza chiuderlo, il timer del
	-- vecchio potrebbe scattare in mezzo al nuovo e liberargli il binding.
	function handle.abort()
		if done then return end
		done = true
		stop_timers()
		if opts.on_aborted then opts.on_aborted() end
	end

	if active_exchange then active_exchange.abort() end
	active_exchange = handle

	-- pulizia preventiva del binding (uno scambio precedente ancora aperto)
	release()

	net.register(APP_BINDING,
		function(_, _, status)
			if done then return end
			if status == "ONLINE" then
				C4:SendToNetwork(APP_BINDING, APP_PORT, opts.request)
				timers[#timers + 1] = timer.after(APP_TIMEOUT_MS, function()
					if not done then
						finish()
						opts.on_timeout()
					end
				end)
			elseif status == "OFFLINE" then
				local received = buffer
				finish()
				if received ~= "" then
					opts.on_response(received) -- la TV ha chiuso dopo aver risposto
				else
					opts.on_refused()
				end
			end
		end,
		function(_, _, data)
			if done then return end
			if not opts.settle_ms then
				finish()
				opts.on_response(data)
				return
			end
			local first = (buffer == "")
			buffer = buffer .. data
			if first then
				timers[#timers + 1] = timer.after(opts.settle_ms, function()
					if not done then
						local received = buffer
						finish()
						opts.on_response(received)
					end
				end)
			end
		end)

	C4:CreateNetworkConnection(APP_BINDING, host, "SSL")
	C4:NetPortOptions(APP_BINDING, APP_PORT, "SSL", SSL_OPTIONS)
	C4:NetConnect(APP_BINDING, APP_PORT)
end

-- ------------------------------------------------------------
-- Lancio applicazioni: POST https://<ip>:8002/api/v2/applications/<id>
-- ------------------------------------------------------------
function M.launch_app(appName)
	local appId = protocol.APP_IDS[appName]
	if not appId then
		log.warn("APP", "app '" .. tostring(appName) .. "' not mapped")
		return false
	end
	local host = get_ip()
	if not host then
		log.warn("APP", "IP Address not set, cannot launch app")
		return false
	end

	log.info("APP", "launching '" .. appName .. "' (id=" .. appId .. ")")

	https_exchange(host, {
		request = "POST /api/v2/applications/" .. appId .. " HTTP/1.1\r\n" ..
			"Host: " .. host .. ":" .. APP_PORT .. "\r\n" ..
			"Content-Length: 0\r\nConnection: close\r\n\r\n",
		on_response = function(data)
			local code = protocol.http_status(data)
			if code and code >= 400 then
				log.warn("APP", "TV answered HTTP " .. code .. " launching '" .. appName .. "'")
			else
				log.debug("APP", "launch response received (HTTP " .. tostring(code) .. ")")
				M.watch_app(appName)
			end
		end,
		on_aborted = function()
			log.debug("APP", "launch of '" .. appName .. "' superseded by another HTTPS request")
		end,
		on_timeout = function()
			log.warn("APP", "launch of '" .. appName .. "' timed out")
		end,
		on_refused = function()
			log.warn("APP", "HTTPS connection refused (app launch)")
		end,
	})
	return true
end

-- Stato di un'app sulla TV: GET /api/v2/applications/<id>. Diagnostica per
-- capire se la TV dice quando si esce da un'app. `onResult(state, code)` e'
-- chiamata sempre; `state` e' nil se la TV non ha risposto.
function M.app_status(appName, onResult)
	local appId = protocol.APP_IDS[appName]
	if not appId then
		log.warn("APP", "app '" .. tostring(appName) .. "' not mapped")
		if onResult then onResult(nil) end
		return false
	end
	local host = get_ip()
	if not host then
		log.warn("APP", "IP Address not set, cannot query app")
		if onResult then onResult(nil) end
		return false
	end

	https_exchange(host, {
		request = "GET /api/v2/applications/" .. appId .. " HTTP/1.1\r\n" ..
			"Host: " .. host .. ":" .. APP_PORT .. "\r\nConnection: close\r\n\r\n",
		settle_ms = REST_SETTLE_MS,
		on_response = function(data)
			local code = protocol.http_status(data)
			local state = protocol.parse_app_state(data)
			log.info("APP", "status of '" .. appName .. "': HTTP " .. tostring(code) ..
				" running=" .. tostring(state.running) .. " visible=" .. tostring(state.visible))
			log.debug("APP", "status body: " .. (data:match("\r\n\r\n(.*)$") or data):sub(1, 300))
			if onResult then onResult(state, code) end
		end,
		on_aborted = function()
			if onResult then onResult(nil) end
		end,
		on_timeout = function()
			log.warn("APP", "status query of '" .. appName .. "' timed out")
			if onResult then onResult(nil) end
		end,
		on_refused = function()
			log.warn("APP", "HTTPS connection refused (status query)")
			if onResult then onResult(nil) end
		end,
	})
	return true
end

-- Stato di tutte le app note, una dopo l'altra (il binding e' uno solo).
function M.app_status_all()
	local names = protocol.APP_NAMES
	local function step(index)
		if index > #names then
			log.info("APP", "status of all apps read")
			return
		end
		local started = M.app_status(names[index], function() step(index + 1) end)
		if not started then step(index + 1) end
	end
	step(1)
end

-- ------------------------------------------------------------
-- App in primo piano: variabili ed eventi per le programmazioni
--   variabili  CURRENT_APP (app in primo piano o vuota), LAST_APP (app dell'ultimo evento)
--   eventi     APP_OPENED, APP_CLOSED
-- Si controlla solo l'app lanciata dal driver (tile o LAUNCH_APP): sapere quale
-- app e' aperta, se la si apre col telecomando, richiederebbe di interrogarle tutte.
-- ------------------------------------------------------------
function M.init_variables()
	C4:AddVariable("CURRENT_APP", "", "STRING")
	C4:AddVariable("LAST_APP", "", "STRING")
end

local function announce(event, appName)
	C4:SetVariable("LAST_APP", appName)
	C4:SetVariable("CURRENT_APP", event == "APP_OPENED" and appName or "")
	log.info("APP", event .. " -> " .. appName)
	C4:FireEvent(event)
end

-- Smette di controllare l'app; se era in primo piano annuncia che e' uscita.
function stop_watch()
	local w = foreground
	if not w then return end
	foreground = nil
	w.timer = cancel(w.timer)
	if w.opened then announce("APP_CLOSED", w.app) end
end

local function watch_tick(w)
	if foreground ~= w then return end
	w.timer = nil

	M.app_status(w.app, function(state, code)
		if foreground ~= w then return end

		local gone = false
		if state == nil then
			w.misses = w.misses + 1
			gone = (w.misses >= WATCH_MAX_MISSES)
		elseif code ~= 200 then
			log.warn("APP", "'" .. w.app .. "' is not available on the TV (HTTP " .. tostring(code) .. ")")
			gone = true
		else
			w.misses = 0
			if state.visible == true then
				if not w.opened then
					w.opened = true
					announce("APP_OPENED", w.app)
				end
			elseif state.visible == false then
				if w.opened then
					gone = true
				elseif (now() - w.since) > WATCH_GRACE_S then
					log.warn("APP", "'" .. w.app .. "' did not come to the foreground, no longer watched")
					gone = true
				end
			end
		end

		if gone then
			stop_watch()
		else
			w.timer = timer.after(WATCH_INTERVAL_MS, function() watch_tick(w) end)
		end
	end)
end

-- Da chiamare dopo un lancio riuscito. Un nuovo lancio sostituisce il controllo
-- precedente (e, se quell'app era in primo piano, la dichiara chiusa).
function M.watch_app(appName)
	stop_watch()
	local w = { app = appName, opened = false, since = now(), misses = 0 }
	foreground = w
	w.timer = timer.after(WATCH_INTERVAL_MS, function() watch_tick(w) end)
end

-- Se la TV e' accesa lancia subito; altrimenti aspetta che il REST confermi
-- l'accensione (Director ha gia' mandato ON): fino a 10 tentativi ogni 1,5 s.
function M.launch_app_when_on(appName)
	if power == "ON" then
		M.launch_app(appName)
		return
	end
	local attempts = 0
	local function check()
		attempts = attempts + 1
		if power == "ON" then
			M.launch_app(appName)
		elseif attempts < 10 then
			M.check_reachability() -- forza un controllo REST fresco
			timer.after(1500, check)
		else
			log.warn("APP", "TV did not turn on in time, launch of '" .. appName .. "' cancelled")
		end
	end
	timer.after(1500, check)
end

-- ------------------------------------------------------------
-- Ciclo di vita
-- ------------------------------------------------------------

-- Avvia il polling REST (e, se abbinati, la connessione WebSocket).
function M.start()
	refresh_pairing_status()
	M.check_reachability()
	if get_token() then M.connect() end
end

function M.shutdown()
	rest.poll = cancel(rest.poll)
	cancel_rest_timers()
	rest.busy = false
	rest.gen = rest.gen + 1
	if foreground then
		foreground.timer = cancel(foreground.timer)
		foreground = nil -- niente eventi durante lo spegnimento del driver
	end
	if active_exchange then active_exchange.abort() end
	release_rest_binding()
	end_pairing()
	drop_ws()
	clear_queue("driver shutting down")
end

return M
