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

t.test("ogni MiniApp e' lanciabile (ha un id applicazione)", function()
	local n = 0
	for slot, app in pairs(protocol.MINI_APP_MAP) do
		t.truthy(protocol.APP_IDS[app], "slot " .. slot .. " -> " .. app .. " senza id")
		n = n + 1
	end
	t.eq(n, 9)
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
