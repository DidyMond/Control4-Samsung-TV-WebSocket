-- Test di lib/websocket.lua (client RFC 6455 su connessioni DriverWorks finte)
local t = require "tests.support.harness"
local fake = require "tests.support.fake_c4"
local server = require "tests.support.ws_server"

t.test("sha1/base64 di test: vettori noti (RFC 6455 par. 1.3)", function()
	t.eq(fake.sha1_hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
	t.eq(fake.accept_for("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
end)

-- Apre un socket fino all'handshake completato. Restituisce env, ws, eventi.
local function open_socket(url, handshake_extra)
	local env = fake.install()
	local WS = require "lib.websocket"
	local events = { opened = 0, messages = {}, closed = {} }
	local ws = assert(WS.new(url or "wss://192.168.1.50:8002/api/v2/channels/samsung.remote.control?name=QzQ=", {
		ssl_options = { verify_mode = "none", method = "tlsv1_2" },
		on_open = function() events.opened = events.opened + 1 end,
		on_message = function(_, text) events.messages[#events.messages + 1] = text end,
		on_close = function(_, reason) events.closed[#events.closed + 1] = reason end,
	}))
	ws:connect()
	local binding = ws.binding
	env.deliver_status(binding, "ONLINE")
	local request = env.last_sent(binding)
	env.deliver_data(binding, server.upgrade_response(request, handshake_extra))
	return env, ws, events, binding, request
end

t.test("parse_url: wss con porta, ws con porta, porte di default, risorsa", function()
	fake.install()
	local WS = require "lib.websocket"
	local scheme, host, port, resource = WS.parse_url("wss://192.168.1.50:8002/api/v2/x?name=a&b=c")
	t.eq(scheme, "wss"); t.eq(host, "192.168.1.50"); t.eq(port, 8002); t.eq(resource, "/api/v2/x?name=a&b=c")
	scheme, host, port, resource = WS.parse_url("ws://tv.local:8001")
	t.eq(scheme, "ws"); t.eq(host, "tv.local"); t.eq(port, 8001); t.eq(resource, "/")
	t.eq(select(3, WS.parse_url("ws://tv.local/x")), 80)
	t.eq(select(3, WS.parse_url("wss://tv.local/x")), 443)
	t.eq(WS.parse_url("http://tv.local"), nil)
	t.eq(WS.parse_url("garbage"), nil)
	local ws, err = WS.new("garbage")
	t.eq(ws, nil)
	t.contains(err, "invalid")
end)

t.test("connect: wss crea la connessione SSL con le opzioni, ws no", function()
	local env = fake.install()
	local WS = require "lib.websocket"
	local secure = WS.new("wss://192.168.1.50:8002/x", { ssl_options = { verify_mode = "none" } })
	secure:connect()
	t.eq(secure.binding, 6100)
	t.eq(env.conns[6100].ssl, "SSL")
	t.eq(env.conns[6100].options.verify_mode, "none")
	t.eq(env.connects[1].port, 8002)

	local plain = WS.new("ws://192.168.1.50:8001/x")
	plain:connect()
	t.eq(plain.binding, 6101, "il secondo socket usa il binding libero successivo")
	t.eq(env.conns[6101].ssl, nil)
end)

t.test("handshake: richiesta di upgrade corretta e on_open dopo la 101 valida", function()
	local env, ws, events, binding, request = open_socket()
	t.contains(request, "GET /api/v2/channels/samsung.remote.control?name=QzQ= HTTP/1.1\r\n")
	t.contains(request, "Host: 192.168.1.50:8002\r\n")
	t.contains(request, "Upgrade: websocket\r\n")
	t.contains(request, "Connection: Upgrade\r\n")
	t.contains(request, "Sec-WebSocket-Version: 13\r\n")
	t.truthy(request:find("\r\n\r\n$"), "la richiesta termina con una riga vuota")
	t.eq(events.opened, 1)
	t.truthy(ws:is_open())
end)

t.test("handshake: risposta spezzata in piu' pacchetti", function()
	local env = fake.install()
	local WS = require "lib.websocket"
	local opened = 0
	local ws = WS.new("ws://192.168.1.50:8001/x", { on_open = function() opened = opened + 1 end })
	ws:connect()
	env.deliver_status(ws.binding, "ONLINE")
	local response = server.upgrade_response(env.last_sent(ws.binding))
	env.deliver_data(ws.binding, response:sub(1, 20))
	t.eq(opened, 0)
	env.deliver_data(ws.binding, response:sub(21, 60))
	t.eq(opened, 0)
	env.deliver_data(ws.binding, response:sub(61))
	t.eq(opened, 1)
end)

t.test("handshake: frame arrivato insieme alla 101 viene processato", function()
	local env, ws, events = open_socket(nil, server.text('{"event":"ms.channel.connect"}'))
	t.eq(events.opened, 1)
	t.eq(events.messages[1], '{"event":"ms.channel.connect"}')
end)

t.test("handshake: Sec-WebSocket-Accept sbagliato -> on_close e binding rilasciato", function()
	local env = fake.install()
	local WS = require "lib.websocket"
	local closed, opened = {}, 0
	local ws = WS.new("ws://192.168.1.50:8001/x", {
		on_open = function() opened = opened + 1 end,
		on_close = function(_, reason) closed[#closed + 1] = reason end,
	})
	ws:connect()
	local binding = ws.binding
	env.deliver_status(binding, "ONLINE")
	env.deliver_data(binding, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
		.. "Connection: Upgrade\r\nSec-WebSocket-Accept: AAAA\r\n\r\n")
	t.eq(opened, 0)
	t.eq(#closed, 1)
	t.contains(closed[1], "Sec-WebSocket-Accept")
	t.eq(env.disconnects[#env.disconnects].binding, binding)
	t.falsy(require("lib.net").is_registered(binding))
end)

t.test("handshake: risposta HTTP diversa da 101 -> on_close con il codice", function()
	local env = fake.install()
	local WS = require "lib.websocket"
	local closed = {}
	local ws = WS.new("ws://192.168.1.50:8001/x", { on_close = function(_, r) closed[#closed + 1] = r end })
	ws:connect()
	env.deliver_status(ws.binding, "ONLINE")
	env.deliver_data(ws.binding, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
	t.eq(#closed, 1)
	t.contains(closed[1], "HTTP 403")
end)

t.test("send_text: frame mascherato e decodificabile; a socket chiuso non invia", function()
	local env, ws, events, binding = open_socket()
	local payload = string.rep("k", 200) -- forza la lunghezza a 16 bit
	t.truthy(ws:send_text(payload))
	local opcode, decoded = server.decode_client_frame(env.last_sent(binding))
	t.eq(opcode, 1)
	t.eq(decoded, payload)

	local before = #env.sent[binding]
	ws:close()
	t.falsy(ws:send_text("x"))
	t.eq(#env.sent[binding], before + 1, "dopo close() parte solo il frame CLOSE")
end)

t.test("ricezione: messaggi di testo e PING -> PONG con lo stesso payload", function()
	local env, ws, events, binding = open_socket()
	env.deliver_data(binding, server.text("uno") .. server.frame(0x9, "abc"))
	t.eq(events.messages[1], "uno")
	local opcode, payload = server.decode_client_frame(env.last_sent(binding))
	t.eq(opcode, 0xA)
	t.eq(payload, "abc")
end)

t.test("ricezione: messaggio spezzato su due pacchetti TCP", function()
	local env, ws, events, binding = open_socket()
	local data = server.text('{"event":"x"}')
	env.deliver_data(binding, data:sub(1, 1))
	env.deliver_data(binding, data:sub(2, 5))
	t.eq(#events.messages, 0)
	env.deliver_data(binding, data:sub(6))
	t.eq(events.messages[1], '{"event":"x"}')
end)

t.test("CLOSE dalla TV: risposta CLOSE, on_close('remote'), binding rilasciato dopo 1 s", function()
	local env, ws, events, binding = open_socket()
	env.deliver_data(binding, server.frame(0x8, "\3\232"))
	local opcode = server.decode_client_frame(env.last_sent(binding))
	t.eq(opcode, 0x8)
	t.same(events.closed, { "remote" })
	t.eq(#env.disconnects, 0, "il TCP resta aperto per la chiusura pulita")
	env.advance(999)
	t.eq(#env.disconnects, 0)
	env.advance(1)
	t.eq(env.disconnects[#env.disconnects].binding, binding)
	t.eq(env.addresses[binding], nil)
	-- l'evento OFFLINE che segue la chiusura non genera una seconda on_close
	env.deliver_status(binding, "OFFLINE")
	t.eq(#events.closed, 1)
end)

t.test("OFFLINE a meta' sessione: on_close('offline') una volta sola", function()
	local env, ws, events, binding = open_socket()
	env.deliver_status(binding, "OFFLINE")
	env.deliver_status(binding, "OFFLINE")
	t.same(events.closed, { "offline" })
	t.falsy(ws:is_open())
end)

t.test("OFFLINE prima dell'handshake: on_close('offline') e rilascio immediato", function()
	local env = fake.install()
	local WS = require "lib.websocket"
	local closed = {}
	local ws = WS.new("ws://192.168.1.50:8001/x", { on_close = function(_, r) closed[#closed + 1] = r end })
	ws:connect()
	env.deliver_status(ws.binding, "OFFLINE")
	t.same(closed, { "offline" })
	t.eq(env.disconnects[#env.disconnects].binding, ws.binding)
end)

t.test("close() locale: invia CLOSE, non chiama on_close, binding tenuto 1 s", function()
	local env, ws, events, binding = open_socket()
	ws:close()
	local opcode = server.decode_client_frame(env.last_sent(binding))
	t.eq(opcode, 0x8)
	t.eq(#events.closed, 0)
	t.eq(#env.disconnects, 0)

	-- nel frattempo un nuovo socket non puo' prendere lo stesso binding
	local WS = require "lib.websocket"
	local other = WS.new("ws://192.168.1.50:8001/y")
	other:connect()
	t.truthy(other.binding ~= binding, "binding ancora occupato")

	env.advance(1000)
	t.eq(env.disconnects[#env.disconnects].binding, binding)
	t.eq(#events.closed, 0)
	-- il binding e' di nuovo libero
	local third = WS.new("ws://192.168.1.50:8001/z")
	third:connect()
	t.eq(third.binding, binding)
end)

t.test("errore di protocollo (RSV acceso): on_close('error: ...') e binding rilasciato", function()
	local env, ws, events, binding = open_socket()
	env.deliver_data(binding, "\193\0")
	t.eq(#events.closed, 1)
	t.contains(events.closed[1], "protocol error")
	env.advance(1000)
	t.eq(env.disconnects[#env.disconnects].binding, binding)
end)

t.test("un errore nella callback on_message non interrompe la ricezione", function()
	local env = fake.install()
	local WS = require "lib.websocket"
	local got = {}
	local ws = WS.new("ws://192.168.1.50:8001/x", {
		on_message = function(_, text)
			got[#got + 1] = text
			if text == "boom" then error("callback failure") end
		end,
	})
	ws:connect()
	env.deliver_status(ws.binding, "ONLINE")
	env.deliver_data(ws.binding, server.upgrade_response(env.last_sent(ws.binding)))
	env.deliver_data(ws.binding, server.text("boom") .. server.text("dopo"))
	t.same(got, { "boom", "dopo" })
	t.truthy(ws:is_open())
	local logged = table.concat(env.printed, "\n")
	t.contains(logged, "callback error")
end)

t.test("nessun binding libero: on_close con errore, niente eccezioni", function()
	local env = fake.install()
	for id = 6100, 6199 do env.addresses[id] = "occupied" end
	local WS = require "lib.websocket"
	local closed = {}
	local ws = WS.new("ws://192.168.1.50:8001/x", { on_close = function(_, r) closed[#closed + 1] = r end })
	ws:connect()
	t.eq(#closed, 1)
	t.contains(closed[1], "no free network binding")
end)

t.finish()
