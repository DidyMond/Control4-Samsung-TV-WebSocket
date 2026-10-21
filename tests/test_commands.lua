-- Test di tv/commands.lua: da comando Director/Composer ad azione sulla TV
local t = require "tests.support.harness"
local fake = require "tests.support.fake_c4"

-- TV finta: registra cosa le viene chiesto
local function setup(power)
	local env = fake.install()
	local Commands = require "tv.commands"
	local calls = {}
	local tv = {
		send_key = function(key) calls[#calls + 1] = "key:" .. key; return true end,
		launch_app = function(app) calls[#calls + 1] = "app:" .. app end,
		launch_app_when_on = function(app) calls[#calls + 1] = "app_when_on:" .. app end,
		power = function() return power or "UNKNOWN" end,
	}
	local commands = Commands.new(tv, function() return math.floor(env.now / 1000) end)
	return env, commands, calls
end

t.test("housekeeping di Director: nessuna azione", function()
	local env, commands, calls = setup()
	commands.handle_proxy(5000, "CONNECT_OUTPUT", {})
	commands.handle_proxy(5000, "GET_VOLUME_LEVEL", {})
	commands.handle_proxy(5002, "ON", {})
	commands.handle_proxy(5002, "OFF", {})
	t.same(calls, {})
end)

t.test("ON/OFF dalla proxy TV: KEY_POWER solo se lo stato reale e' diverso", function()
	local _, commands, calls = setup("OFF")
	commands.handle_proxy(5000, "ON", {})
	t.same(calls, { "key:KEY_POWER" })
	commands.handle_proxy(5000, "OFF", {})
	t.same(calls, { "key:KEY_POWER" }, "gia' OFF: nessun toggle")

	local _, commands2, calls2 = setup("ON")
	commands2.handle_proxy(5000, "ON", {})
	t.same(calls2, {}, "gia' ON: nessun toggle")
	commands2.handle_proxy(5000, "OFF", {})
	t.same(calls2, { "key:KEY_POWER" })
end)

t.test("ON/OFF di routing sulla avswitch non spengono la TV", function()
	local _, commands, calls = setup("ON")
	commands.handle_proxy(5002, "OFF", {})
	t.same(calls, {})
end)

t.test("SET_INPUT sulla proxy TV: HDMI fisici si, routing interno no", function()
	local _, commands, calls = setup()
	commands.handle_proxy(5000, "SET_INPUT", { INPUT = "1002" })
	commands.handle_proxy(5000, "SET_INPUT", { INPUT = 1003 })
	commands.handle_proxy(5000, "SET_INPUT", { INPUT = "1102" })
	t.same(calls, { "key:KEY_HDMI2", "key:KEY_HDMI3" })
end)

t.test("MiniApp: tile -> lancio quando la TV e' accesa; doppione di Director entro 3 s ignorato", function()
	local env, commands, calls = setup()
	commands.handle_proxy(5002, "SET_INPUT", { INPUT = "3201" })
	commands.handle_proxy(5002, "SET_INPUT", { INPUT = "3201" })
	t.same(calls, { "app_when_on:Netflix" })
	commands.handle_proxy(5002, "SET_INPUT", { INPUT = "3202" })
	t.eq(calls[2], "app_when_on:YouTube", "un'altra app non e' un doppione")
	env.advance(3000)
	commands.handle_proxy(5002, "SET_INPUT", { INPUT = "3202" })
	t.eq(calls[3], "app_when_on:YouTube", "dopo 3 s si rilancia")
	commands.handle_proxy(5002, "SET_INPUT", { INPUT = "9999" })
	t.eq(#calls, 3)
end)

t.test("tutti e 9 gli slot MiniApp lanciano un'app", function()
	local _, commands, calls = setup()
	for slot = 3201, 3209 do
		commands.handle_proxy(5002, "SET_INPUT", { INPUT = tostring(slot) })
	end
	t.eq(#calls, 9)
end)

t.test("PASSTHROUGH: EJECT chiude l'app, comandi sconosciuti ignorati", function()
	local _, commands, calls = setup()
	commands.handle_proxy(5000, "PASSTHROUGH", { PASSTHROUGH_COMMAND = "EJECT" })
	commands.handle_proxy(5000, "PASSTHROUGH", { PASSTHROUGH_COMMAND = "UP" })
	commands.handle_proxy(5000, "PASSTHROUGH", { PASSTHROUGH_COMMAND = "BOH" })
	t.same(calls, { "key:KEY_EXIT", "key:KEY_UP" })
end)

t.test("comandi singoli: volume, mute, canali, navigazione, numeri, tasti colore, trasporto", function()
	local _, commands, calls = setup()
	for _, cmd in ipairs({ "PULSE_VOL_UP", "MUTE_TOGGLE", "PULSE_CH_DOWN", "ENTER", "CANCEL",
		"NUMBER_5", "PROGRAM_A", "PLAY", "START_PAGE_RIGHT", "START_PAGE_LEFT" }) do
		commands.handle_proxy(5000, cmd, {})
	end
	t.same(calls, { "key:KEY_VOLUP", "key:KEY_MUTE", "key:KEY_CHDOWN", "key:KEY_ENTER", "key:KEY_RETURN",
		"key:KEY_5", "key:KEY_RED", "key:KEY_PLAY", "key:KEY_RIGHT", "key:KEY_LEFT" })
end)

t.test("comando non mappato: niente invio", function()
	local _, commands, calls = setup()
	commands.handle_proxy(5000, "QUALCOSA_DI_NUOVO", {})
	t.same(calls, {})
end)

t.test("ripetizione volume: subito + ogni 300 ms fino a STOP", function()
	local env, commands, calls = setup()
	commands.handle_proxy(5000, "START_VOL_UP", {})
	t.eq(#calls, 1)
	env.advance(300)
	t.eq(#calls, 2)
	env.advance(600)
	t.eq(#calls, 4)
	commands.handle_proxy(5000, "STOP_VOL_UP", {})
	env.advance(3000)
	t.eq(#calls, 4)
	t.eq(env.pending_timers(), 0)
end)

t.test("ripetizione canali ogni 500 ms; un nuovo START sostituisce il precedente", function()
	local env, commands, calls = setup()
	commands.handle_proxy(5000, "START_CH_UP", {})
	commands.handle_proxy(5000, "START_VOL_DOWN", {})
	t.eq(env.pending_timers(), 1)
	t.same(calls, { "key:KEY_CHUP", "key:KEY_VOLDOWN" })
	env.advance(300)
	t.eq(calls[3], "key:KEY_VOLDOWN")
end)

t.test("ripetizione: senza STOP si ferma da sola dopo 20 s", function()
	local env, commands, calls = setup()
	commands.handle_proxy(5000, "START_VOL_UP", {})
	env.advance(25000)
	t.eq(env.pending_timers(), 0)
	local n = #calls
	t.truthy(n > 30 and n < 80, "inviati " .. n)
	env.advance(5000)
	t.eq(#calls, n)
	t.contains(table.concat(env.printed, "\n"), "key repeat stopped")
end)

t.test("ExecuteCommand: SEND_KEY e LAUNCH_APP con i loro parametri", function()
	local env, commands, calls = setup()
	commands.execute("SEND_KEY", { KeyCode = "KEY_HOME" })
	commands.execute("LAUNCH_APP", { AppName = "Netflix" })
	t.same(calls, { "key:KEY_HOME", "app:Netflix" })
end)

t.test("ExecuteCommand: parametri mancanti o comando sconosciuto non fanno nulla", function()
	local env, commands, calls = setup()
	commands.execute("SEND_KEY", {})
	commands.execute("LAUNCH_APP", nil)
	commands.execute("ALTRO", {})
	t.same(calls, {})
	t.contains(table.concat(env.printed, "\n"), "SEND_KEY called without KeyCode")
end)

t.finish()
