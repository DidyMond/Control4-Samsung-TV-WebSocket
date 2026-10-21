-- Smoke test di driver.lua: gli handler Director invocati come farebbe Director
local t = require "tests.support.harness"
local fake = require "tests.support.fake_c4"
local server = require "tests.support.ws_server"

local function load_driver(opts)
	opts = opts or {}
	local env = fake.install()
	if opts.paired then env.persist.AuthToken = "12345678" end
	for _, name in ipairs({ "OnDriverInit", "OnDriverLateInit", "OnDriverDestroyed", "OnTimerExpired",
		"OnConnectionStatusChanged", "ReceivedFromNetwork", "OnPropertyChanged",
		"ReceivedFromProxy", "ExecuteCommand" }) do
		_G[name] = nil
	end
	dofile("src/driver.lua")
	return env
end

local function logged(env) return table.concat(env.printed, "\n") end

t.test("il driver espone tutti gli handler Director", function()
	load_driver()
	for _, name in ipairs({ "OnDriverInit", "OnDriverLateInit", "OnDriverDestroyed", "OnTimerExpired",
		"OnConnectionStatusChanged", "ReceivedFromNetwork", "OnPropertyChanged",
		"ReceivedFromProxy", "ExecuteCommand" }) do
		t.eq(type(_G[name]), "function", name)
	end
end)

t.test("avvio non abbinato: polling REST subito, nessun WebSocket, invito al pairing", function()
	local env = load_driver()
	OnDriverInit()
	OnDriverLateInit()
	t.eq(env.connects[1].binding, 6099)
	t.eq(#env.connects, 1)
	t.contains(logged(env), "not paired")
	t.eq(Properties["Pairing Status"], "Not paired")
end)

t.test("avvio abbinato: REST + WebSocket", function()
	local env = load_driver({ paired = true })
	OnDriverInit()
	OnDriverLateInit()
	t.eq(#env.connects, 2)
	t.eq(Properties["Pairing Status"], "Paired")
end)

t.test("rete e timer: gli eventi arrivano alla logica attraverso Director", function()
	local env = load_driver()
	OnDriverInit()
	OnDriverLateInit()
	OnConnectionStatusChanged(6099, 8001, "ONLINE")
	t.contains(env.last_sent(6099), "GET /api/v2/ HTTP/1.1")
	ReceivedFromNetwork(6099, 8001, 'HTTP/1.1 200 OK\r\n\r\n{"device":{"PowerState":"on"}}')
	-- il timer di attesa risposta e' un timer del driver: passa da OnTimerExpired
	local last_id = 0
	for id in pairs(env.timers) do
		if id > last_id then last_id = id end
	end
	OnTimerExpired(last_id)
	t.contains(logged(env), "state -> ON")
end)

t.test("comando proxy -> tasto Samsung inviato sul WebSocket", function()
	local env = load_driver({ paired = true })
	OnDriverInit()
	OnDriverLateInit()
	OnConnectionStatusChanged(6100, 8002, "ONLINE")
	ReceivedFromNetwork(6100, 8002, server.upgrade_response(env.last_sent(6100)))
	ReceivedFromNetwork(6100, 8002, server.text('{"event":"ms.channel.connect"}'))
	ReceivedFromProxy(5000, "PULSE_VOL_UP", {})
	local _, payload = server.decode_client_frame(env.last_sent(6100))
	t.contains(payload, "KEY_VOLUP")
end)

t.test("ExecuteCommand SEND_KEY arriva alla coda comandi", function()
	local env = load_driver({ paired = true })
	OnDriverInit()
	ExecuteCommand("SEND_KEY", { KeyCode = "KEY_HOME" })
	t.contains(logged(env), "ExecuteCommand -> SEND_KEY")
	t.eq(env.connects[1].binding, 6100, "il tasto in coda apre il WebSocket")
end)

t.test("proprieta' Pairing: 'Pair with TV' e 'Unpair' eseguono e tornano a 'Select...'", function()
	local env = load_driver()
	OnDriverInit()

	Properties["Pairing"] = "Pair with TV"
	OnPropertyChanged("Pairing")
	t.eq(Properties["Pairing"], "Select...")
	t.eq(env.connects[#env.connects].binding, 6100, "connessione in pairing aperta")

	env.persist.AuthToken = "12345678"
	Properties["Pairing"] = "Unpair"
	OnPropertyChanged("Pairing")
	t.eq(Properties["Pairing"], "Select...")
	t.eq(env.persist.AuthToken, "")

	-- il reset a 'Select...' non rilancia nulla
	local before = #env.connects
	OnPropertyChanged("Pairing")
	t.eq(#env.connects, before)
end)

t.test("proprieta' IP Address: token invalidato e nuovo check REST", function()
	local env = load_driver({ paired = true })
	OnDriverInit()
	Properties["IP Address"] = "192.168.1.77"
	OnPropertyChanged("IP Address")
	t.eq(env.persist.AuthToken, "")
	t.eq(env.conns[6099].host, "192.168.1.77")
end)

t.test("proprieta' Log Mode e Log Level si applicano subito", function()
	local env = load_driver()
	Properties["Log Mode"] = "Off"
	OnDriverInit()
	local before = #env.printed
	Properties["Log Level"] = "3 - Info"
	OnPropertyChanged("Log Level")
	ExecuteCommand("ALTRO", {})
	t.eq(#env.printed, before, "Log Mode Off: nessuna riga")

	Properties["Log Mode"] = "Print"
	OnPropertyChanged("Log Mode")
	ExecuteCommand("ALTRO", {})
	t.contains(logged(env), "ExecuteCommand -> ALTRO")
	t.falsy(logged(env):find("unhandled command", 1, true), "livello Info: niente debug")
end)

t.test("un errore in una callback non esce verso Director ed e' sempre loggato", function()
	local env = load_driver()
	Properties["Log Mode"] = "Off"
	OnDriverInit()
	require("lib.net").register(7000, function() error("boom di test") end, nil)
	OnConnectionStatusChanged(7000, 0, "ONLINE") -- non deve sollevare
	t.contains(logged(env), "unhandled error in OnConnectionStatusChanged")
	t.contains(logged(env), "boom di test")
end)

t.test("OnDriverDestroyed: nessun timer rimasto", function()
	local env = load_driver({ paired = true })
	OnDriverInit()
	OnDriverLateInit()
	ReceivedFromProxy(5000, "START_VOL_UP", {})
	OnDriverDestroyed()
	t.eq(env.pending_timers(), 0)
end)

t.finish()
