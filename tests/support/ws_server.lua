-- ============================================================
-- tests/support/ws_server.lua - la "TV" dei test: frame e handshake lato server
-- ============================================================

local fake = require "tests.support.fake_c4"

local S = {}

-- Frame server->client, non mascherato.
function S.frame(opcode, payload, fin)
	local len = #payload
	local head = string.char((fin == false and 0 or 0x80) + opcode)
	if len <= 125 then
		head = head .. string.char(len)
	else
		head = head .. string.char(126, math.floor(len / 256), len % 256)
	end
	return head .. payload
end

function S.text(payload) return S.frame(0x1, payload) end

-- Chiave Sec-WebSocket-Key dentro la richiesta di upgrade del client.
function S.key_of(request)
	return request:match("Sec%-WebSocket%-Key: ([^\r\n]+)")
end

-- Risposta 101 corretta per la richiesta del client.
function S.upgrade_response(request, extra)
	return "HTTP/1.1 101 Switching Protocols\r\n"
		.. "Upgrade: websocket\r\n"
		.. "Connection: Upgrade\r\n"
		.. "Sec-WebSocket-Accept: " .. fake.accept_for(S.key_of(request)) .. "\r\n"
		.. "\r\n" .. (extra or "")
end

-- Smaschera un frame client->server (per verificare cosa ha inviato il driver):
-- restituisce opcode, payload.
function S.decode_client_frame(packet)
	local b1, b2 = packet:byte(1, 2)
	assert(bit.band(b2, 0x80) ~= 0, "il client deve mascherare i frame")
	local len = bit.band(b2, 0x7F)
	local pos = 3
	if len == 126 then
		len = packet:byte(3) * 256 + packet:byte(4)
		pos = 5
	end
	local mask = { packet:byte(pos, pos + 3) }
	local payload = {}
	for i = 1, len do
		payload[i] = string.char(bit.bxor(packet:byte(pos + 3 + i), mask[(i - 1) % 4 + 1]))
	end
	return bit.band(b1, 0x0F), table.concat(payload)
end

return S
