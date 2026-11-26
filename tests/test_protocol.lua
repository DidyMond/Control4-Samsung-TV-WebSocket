-- Test di tv/protocol.lua
local t = require "tests.support.harness"
local protocol = require "tv.protocol"

t.test("extract_token: con e senza virgolette", function()
	t.eq(protocol.extract_token('{"data":{"token":"24681357"}}'), "24681357")
	t.eq(protocol.extract_token('{"data":{"token": 24681357}}'), "24681357")
	t.eq(protocol.extract_token('{"event":"ms.channel.connect","data":{}}'), nil)
end)

t.test("parse_power_state: On, standby, Off", function()
	local s, why = protocol.parse_power_state('{"device":{"PowerState":"on"}}')
	t.eq(s, "ON")
	t.contains(why, "on")
	t.eq((protocol.parse_power_state('{"device":{"PowerState":"On"}}')), "ON")
	t.eq((protocol.parse_power_state('{"device":{"PowerState":"standby"}}')), "OFF")
	t.eq((protocol.parse_power_state('{"device":{"PowerState":"Off"}}')), "OFF")
end)

t.test("parse_power_state: nessuna risposta = OFF, risposta senza PowerState = ON", function()
	t.eq((protocol.parse_power_state("")), "OFF")
	t.eq((protocol.parse_power_state(nil)), "OFF")
	t.eq((protocol.parse_power_state("HTTP/1.1 200 OK\r\n\r\n{}")), "ON")
end)

t.test("parse_app_state: running e visible", function()
	local state = protocol.parse_app_state('HTTP/1.1 200 OK\r\n\r\n{"id":"1","name":"Plex","running":true,"visible":false}')
	t.eq(state.running, true)
	t.eq(state.visible, false)
	state = protocol.parse_app_state('{"running": false, "visible": false}')
	t.eq(state.running, false)
	t.eq(state.visible, false)
end)

t.test("parse_app_state: campi assenti o risposta senza JSON", function()
	local state = protocol.parse_app_state("HTTP/1.1 404 Not Found\r\n\r\n")
	t.eq(state.running, nil)
	t.eq(state.visible, nil)
	state = protocol.parse_app_state('{"running":true}')
	t.eq(state.running, true)
	t.eq(state.visible, nil)
end)

-- percorso video reale di un progetto: Plex (372) -> App Switcher (327) -> TV (325)
local PATH = '<devices><device><id>372</id><provider_binding_id>3101</provider_binding_id>'
	.. '<consumer_binding_id>0</consumer_binding_id></device><device><id>327</id>'
	.. '<provider_binding_id>2110</provider_binding_id><consumer_binding_id>3204</consumer_binding_id>'
	.. '</device><device><id>325</id><provider_binding_id>7000</provider_binding_id>'
	.. '<consumer_binding_id>1102</consumer_binding_id></device></devices>'

t.test("parse_path: elenco dei dispositivi del percorso", function()
	local devices = protocol.parse_path(PATH)
	t.eq(#devices, 3)
	t.same(devices[2], { id = 327, provider = 2110, consumer = 3204 })
	t.same(protocol.parse_path(""), {})
	t.same(protocol.parse_path(nil), {})
end)

t.test("route_through_app_switch: restituisce l'id della nostra TV", function()
	t.eq((protocol.route_through_app_switch(PATH, { [325] = true, [327] = true })), 325)
	-- con gli spazi che un XML formattato potrebbe avere
	local spaced = PATH:gsub("><", ">\n  <")
	t.eq((protocol.route_through_app_switch(spaced, { [325] = true, [327] = true })), 325)
end)

t.test("route_through_app_switch: non tocca percorsi che non sono i nostri", function()
	local tv, why = protocol.route_through_app_switch(PATH, { [999] = true })
	t.eq(tv, nil)
	t.contains(why, "not behind the App Switcher")

	-- un'altra sorgente (HDMI di un altro dispositivo): nessun App Switcher nel percorso
	local other = '<devices><device><id>400</id><provider_binding_id>3000</provider_binding_id>'
		.. '<consumer_binding_id>0</consumer_binding_id></device><device><id>325</id>'
		.. '<provider_binding_id>7000</provider_binding_id><consumer_binding_id>1001</consumer_binding_id></device></devices>'
	tv, why = protocol.route_through_app_switch(other, { [325] = true, [327] = true })
	t.eq(tv, nil)
	t.contains(why, "not behind the App Switcher")
	t.eq((protocol.route_through_app_switch("", { [325] = true })), nil)
end)

t.test("path_uses_own_device: la stanza sta usando questa TV (App Switcher o HDMI)", function()
	t.truthy(protocol.path_uses_own_device(PATH, { [325] = true, [327] = true }))
	local hdmi = '<devices><device><id>400</id><provider_binding_id>3000</provider_binding_id>'
		.. '<consumer_binding_id>0</consumer_binding_id></device><device><id>325</id>'
		.. '<provider_binding_id>7000</provider_binding_id><consumer_binding_id>1001</consumer_binding_id></device></devices>'
	t.truthy(protocol.path_uses_own_device(hdmi, { [325] = true }))
	t.falsy(protocol.path_uses_own_device(PATH, { [999] = true }))
	t.falsy(protocol.path_uses_own_device("", { [325] = true }))
end)

t.test("route_through_app_switch: App Switcher presente ma TV non trovata", function()
	local broken = '<devices><device><id>327</id><provider_binding_id>2110</provider_binding_id>'
		.. '<consumer_binding_id>3204</consumer_binding_id></device></devices>'
	local tv, why = protocol.route_through_app_switch(broken, { [327] = true })
	t.eq(tv, nil)
	t.contains(why, "own TV not found")
end)

t.test("http_status", function()
	t.eq(protocol.http_status("HTTP/1.1 200 OK\r\n"), 200)
	t.eq(protocol.http_status("HTTP/1.1 404 Not Found"), 404)
	t.eq(protocol.http_status("garbage"), nil)
end)

t.test("is_valid_key: solo KEY_* alfanumerici (niente injection nel JSON)", function()
	t.truthy(protocol.is_valid_key("KEY_HDMI1"))
	t.truthy(protocol.is_valid_key("KEY_VOLUP"))
	t.falsy(protocol.is_valid_key('KEY_X", "Cmd": "Press'))
	t.falsy(protocol.is_valid_key(""))
	t.falsy(protocol.is_valid_key(nil))
	t.falsy(protocol.is_valid_key(5))
end)

t.test("remote_key_payload: contiene il tasto e i campi che la TV si aspetta", function()
	local payload = protocol.remote_key_payload("KEY_MUTE")
	t.contains(payload, '"DataOfCmd": "KEY_MUTE"')
	t.contains(payload, '"method": "ms.remote.control"')
	t.contains(payload, '"TypeOfRemote": "SendRemoteKey"')
end)

t.test("mappe: ogni valore e' un codice tasto valido", function()
	for _, map in ipairs({ protocol.KEY_MAP, protocol.PASSTHROUGH_MAP, protocol.HDMI_MAP }) do
		for cmd, key in pairs(map) do
			t.truthy(protocol.is_valid_key(key), cmd .. " -> " .. tostring(key))
			t.eq(key:sub(1, 4), "KEY_", cmd)
		end
	end
	for cmd, spec in pairs(protocol.REPEAT_MAP) do
		t.truthy(protocol.is_valid_key(spec.key), cmd)
		t.truthy(spec.interval_ms > 0, cmd)
	end
end)

t.test("APP_NAMES e APP_IDS coincidono: ogni app dell'elenco e' lanciabile", function()
	local seen = {}
	for _, name in ipairs(protocol.APP_NAMES) do
		t.truthy(protocol.APP_IDS[name], name .. " senza id applicazione")
		seen[name] = true
	end
	for name in pairs(protocol.APP_IDS) do t.truthy(seen[name], name .. " manca in APP_NAMES") end
	t.eq(#protocol.APP_NAMES, 10)
	t.truthy(seen["Plex"])
end)

t.test("slot MiniApp: 9 slot consecutivi, ognuno con un'app predefinita lanciabile", function()
	t.eq(#protocol.MINI_APP_SLOTS, 9)
	for index, slot in ipairs(protocol.MINI_APP_SLOTS) do
		t.eq(slot.id, tostring(3200 + index))
		t.truthy(protocol.APP_IDS[slot.default], "slot " .. slot.id .. " -> " .. slot.default)
	end
end)

t.test("mini_app_property: nome della proprieta' dello slot", function()
	t.eq((protocol.mini_app_property("3201")), "MiniApp 1 App")
	t.eq((protocol.mini_app_property(3204)), "MiniApp 4 App")
	t.eq((protocol.mini_app_property("3209")), "MiniApp 9 App")
	t.eq(protocol.mini_app_property("3210"), nil)
	t.eq(protocol.mini_app_property("1001"), nil)
end)

t.test("mini_app_for: predefinito se la proprieta' manca o e' vuota", function()
	t.eq((protocol.mini_app_for("3204", nil)), "Disney+")
	t.eq((protocol.mini_app_for("3204", function() return nil end)), "Disney+")
	t.eq((protocol.mini_app_for("3204", function() return "" end)), "Disney+")
	t.eq((protocol.mini_app_for("3201", function() return "Netflix" end)), "Netflix")
end)

t.test("mini_app_for: la proprieta' sceglie l'app (Plex al posto di Disney+)", function()
	local props = { ["MiniApp 4 App"] = "Plex" }
	local read = function(name) return props[name] end
	t.eq((protocol.mini_app_for("3204", read)), "Plex")
	t.eq((protocol.mini_app_for("3203", read)), "Prime Video", "gli altri slot non cambiano")
end)

t.test("mini_app_for: 'Not used', app sconosciuta e slot che non esiste", function()
	local app, why = protocol.mini_app_for("3204", function() return protocol.NOT_USED end)
	t.eq(app, nil)
	t.contains(why, "no app")
	app, why = protocol.mini_app_for("3204", function() return "Boh" end)
	t.eq(app, nil)
	t.contains(why, "unknown app 'Boh'")
	app, why = protocol.mini_app_for("3299", nil)
	t.eq(app, nil)
	t.contains(why, "not a MiniApp slot")
end)

t.test("is_housekeeping: routing sempre; ON/OFF solo sulla avswitch", function()
	t.truthy(protocol.is_housekeeping(5000, "CONNECT_OUTPUT"))
	t.truthy(protocol.is_housekeeping(5000, "GET_VOLUME_LEVEL"))
	t.truthy(protocol.is_housekeeping(5002, "ON"))
	t.truthy(protocol.is_housekeeping(5002, "OFF"))
	t.falsy(protocol.is_housekeeping(5000, "ON"))
	t.falsy(protocol.is_housekeeping(5000, "PULSE_VOL_UP"))
end)

t.finish()
