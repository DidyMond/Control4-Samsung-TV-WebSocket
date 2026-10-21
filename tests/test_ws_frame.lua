-- Test di lib/ws_frame.lua (codec RFC 6455)
local t = require "tests.support.harness"
local frame = require "lib.ws_frame"

local function server_frame(opcode, payload, fin)
	local len = #payload
	local head = string.char((fin == false and 0 or 0x80) + opcode)
	if len <= 125 then
		head = head .. string.char(len)
	elseif len <= 65535 then
		head = head .. string.char(126, math.floor(len / 256), len % 256)
	else
		head = head .. string.char(127, 0, 0, 0, 0, math.floor(len / 16777216) % 256,
			math.floor(len / 65536) % 256, math.floor(len / 256) % 256, len % 256)
	end
	return head .. payload
end

local function bytes(s)
	local out = {}
	for i = 1, #s do out[i] = string.format("%02x", s:byte(i)) end
	return table.concat(out, " ")
end

t.test("encode: vettore RFC 6455 par. 5.7 (testo 'Hello' mascherato)", function()
	local packet = frame.encode(frame.OP_TEXT, "Hello", { 0x37, 0xfa, 0x21, 0x3d })
	t.eq(bytes(packet), "81 85 37 fa 21 3d 7f 9f 4d 51 58")
end)

t.test("encode: lunghezza a 16 bit (300 byte) e round trip della maschera", function()
	local payload = string.rep("a", 300)
	local mask = { 1, 2, 3, 4 }
	local packet = frame.encode(frame.OP_TEXT, payload, mask)
	t.eq(bytes(packet:sub(1, 8)), "81 fe 01 2c 01 02 03 04")
	t.eq(frame.mask_payload(packet:sub(9), mask), payload)
end)

t.test("encode: lunghezza a 64 bit (70000 byte)", function()
	local packet = frame.encode(frame.OP_TEXT, string.rep("b", 70000), { 9, 9, 9, 9 })
	t.eq(bytes(packet:sub(1, 10)), "81 ff 00 00 00 00 00 01 11 70")
	t.eq(#packet, 10 + 4 + 70000)
end)

t.test("encode: payload vuoto (CLOSE senza corpo)", function()
	t.eq(bytes(frame.encode(frame.OP_CLOSE, "", { 0, 0, 0, 0 })), "88 80 00 00 00 00")
end)

t.test("close_payload: codice big endian e motivo", function()
	t.eq(bytes(frame.close_payload(1000, "bye")), "03 e8 62 79 65")
end)

t.test("parser: testo non mascherato (vettore RFC)", function()
	local events = assert(frame.new_parser():feed("\129\5Hello"))
	t.eq(#events, 1)
	t.eq(events[1].type, "message")
	t.eq(events[1].payload, "Hello")
	t.eq(events[1].opcode, frame.OP_TEXT)
end)

t.test("parser: frame mascherato dal server viene smascherato", function()
	local events = assert(frame.new_parser():feed(
		string.char(0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58)))
	t.eq(events[1].payload, "Hello")
end)

t.test("parser: frame spezzato byte per byte (short read)", function()
	local parser = frame.new_parser()
	local data = server_frame(frame.OP_TEXT, '{"event":"ms.channel.connect"}')
	local got
	for i = 1, #data do
		local events = assert(parser:feed(data:sub(i, i)))
		if #events > 0 then got = events end
	end
	t.truthy(got, "nessun messaggio")
	t.eq(got[1].payload, '{"event":"ms.channel.connect"}')
end)

t.test("parser: PING di 2 byte in un pacchetto a se' (caso che desincronizzava la libreria vecchia)", function()
	local parser = frame.new_parser()
	local events = assert(parser:feed("\137"))
	t.eq(#events, 0)
	events = assert(parser:feed("\0"))
	t.eq(events[1].type, "ping")
	t.eq(events[1].payload, "")
end)

t.test("parser: header esteso (16 bit) spezzato a meta'", function()
	local parser = frame.new_parser()
	local payload = string.rep("x", 200)
	local data = server_frame(frame.OP_TEXT, payload)
	t.eq(#assert(parser:feed(data:sub(1, 3))), 0)
	local events = assert(parser:feed(data:sub(4)))
	t.eq(events[1].payload, payload)
end)

t.test("parser: piu' frame nello stesso pacchetto", function()
	local data = server_frame(frame.OP_TEXT, "uno") .. server_frame(frame.OP_PING, "p")
		.. server_frame(frame.OP_TEXT, "due")
	local events = assert(frame.new_parser():feed(data))
	t.eq(#events, 3)
	t.eq(events[1].payload, "uno")
	t.eq(events[2].type, "ping")
	t.eq(events[3].payload, "due")
end)

t.test("parser: messaggio frammentato (RFC 5.4) con PING in mezzo", function()
	local parser = frame.new_parser()
	t.eq(#assert(parser:feed(server_frame(frame.OP_TEXT, "Hel", false))), 0)
	local events = assert(parser:feed(server_frame(frame.OP_PING, "x")))
	t.eq(events[1].type, "ping")
	events = assert(parser:feed(server_frame(frame.OP_CONTINUATION, "lo", true)))
	t.eq(events[1].type, "message")
	t.eq(events[1].payload, "Hello")
end)

t.test("parser: PONG e CLOSE con codice e motivo", function()
	local events = assert(frame.new_parser():feed(server_frame(frame.OP_PONG, "")
		.. server_frame(frame.OP_CLOSE, frame.close_payload(1001, "going away"))))
	t.eq(events[1].type, "pong")
	t.eq(events[2].type, "close")
	t.eq(events[2].code, 1001)
	t.eq(events[2].reason, "going away")
end)

t.test("parser: CLOSE senza corpo", function()
	local events = assert(frame.new_parser():feed(server_frame(frame.OP_CLOSE, "")))
	t.eq(events[1].type, "close")
	t.eq(events[1].code, nil)
end)

t.test("parser: errore su bit RSV", function()
	local events, err = frame.new_parser():feed("\193\0")
	t.eq(events, nil)
	t.contains(err, "RSV")
end)

t.test("parser: errore su continuazione senza inizio", function()
	local events, err = frame.new_parser():feed(server_frame(frame.OP_CONTINUATION, "x"))
	t.eq(events, nil)
	t.contains(err, "continuation")
end)

t.test("parser: errore su frame di controllo frammentato", function()
	local events, err = frame.new_parser():feed(server_frame(frame.OP_PING, "x", false))
	t.eq(events, nil)
	t.contains(err, "control")
end)

t.test("parser: errore su nuovo messaggio dentro uno frammentato", function()
	local parser = frame.new_parser()
	assert(parser:feed(server_frame(frame.OP_TEXT, "a", false)))
	local events, err = parser:feed(server_frame(frame.OP_TEXT, "b"))
	t.eq(events, nil)
	t.contains(err, "fragmented")
end)

t.test("parser: errore su lunghezza 64 bit enorme", function()
	local events, err = frame.new_parser():feed(string.char(0x81, 127, 0, 0, 1, 0, 0, 0, 0, 0))
	t.eq(events, nil)
	t.contains(err, "too large")
end)

t.test("parser: errore su opcode riservato", function()
	local events, err = frame.new_parser():feed(server_frame(0x3, "x"))
	t.eq(events, nil)
	t.contains(err, "opcode")
end)

t.finish()
