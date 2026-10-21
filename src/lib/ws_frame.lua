-- ============================================================
-- lib/ws_frame.lua - codec dei frame WebSocket (RFC 6455, sezione 5)
--
-- Scritto a partire dalla sola RFC 6455: nessun codice di terzi.
-- Lua 5.1 puro, nessun riferimento a C4; usa solo la libreria `bit`,
-- presente sia in DriverWorks sia in LuaJIT.
--
--   encode(opcode, payload, mask)  frame client->server (sempre mascherato)
--   new_parser()                   parser incrementale dei frame server->client
--
-- Il parser accetta i byte cosi' come arrivano dal TCP (anche un frame
-- spezzato in piu' pacchetti, o piu' frame in uno) e restituisce solo gli
-- eventi completi.
-- ============================================================

local M = {}

M.OP_CONTINUATION = 0x0
M.OP_TEXT = 0x1
M.OP_BINARY = 0x2
M.OP_CLOSE = 0x8
M.OP_PING = 0x9
M.OP_PONG = 0xA

-- Tetto alla dimensione di un singolo messaggio ricevuto: la TV manda JSON
-- di poche centinaia di byte; un valore enorme indica un flusso corrotto.
M.MAX_MESSAGE = 1024 * 1024

local bxor, band = bit.bxor, bit.band
local floor = math.floor

-- XOR del payload con la chiave di 4 byte. `mask` e' una tabella di 4 numeri.
function M.mask_payload(payload, mask)
	local out = {}
	for i = 1, #payload do
		out[i] = string.char(bxor(payload:byte(i), mask[(i - 1) % 4 + 1]))
	end
	return table.concat(out)
end

-- Frame client->server: FIN=1, mascherato. `mask` = { b1, b2, b3, b4 }.
function M.encode(opcode, payload, mask)
	payload = payload or ""
	local len = #payload
	local head = string.char(0x80 + opcode)
	if len <= 125 then
		head = head .. string.char(0x80 + len)
	elseif len <= 65535 then
		head = head .. string.char(0x80 + 126, floor(len / 256), len % 256)
	else
		-- lunghezza a 64 bit: i 4 byte alti sono sempre zero (len < 2^32)
		head = head .. string.char(0x80 + 127, 0, 0, 0, 0,
			floor(len / 16777216) % 256, floor(len / 65536) % 256,
			floor(len / 256) % 256, len % 256)
	end
	return head .. string.char(mask[1], mask[2], mask[3], mask[4]) .. M.mask_payload(payload, mask)
end

-- Payload di un frame CLOSE: codice di stato a 2 byte (big endian) + motivo.
function M.close_payload(code, reason)
	return string.char(floor(code / 256), code % 256) .. (reason or "")
end

local Parser = {}
Parser.__index = Parser

function M.new_parser()
	return setmetatable({ buf = "", fragments = nil }, Parser)
end

-- Legge un frame completo dall'inizio del buffer. Restituisce:
--   nil                          servono altri byte
--   frame, bytes_consumati       frame completo
--   false, messaggio             errore di protocollo
local function read_frame(buf)
	if #buf < 2 then return nil end

	local b1, b2 = buf:byte(1, 2)
	local fin = band(b1, 0x80) ~= 0
	local rsv = band(b1, 0x70)
	local opcode = band(b1, 0x0F)
	local masked = band(b2, 0x80) ~= 0
	local len = band(b2, 0x7F)

	if rsv ~= 0 then return false, "RSV bits set" end

	local header = 2
	if len == 126 then
		header = 4
	elseif len == 127 then
		header = 10
	end
	if #buf < header then return nil end

	if len == 126 then
		local h, l = buf:byte(3, 4)
		len = h * 256 + l
	elseif len == 127 then
		local b = { buf:byte(3, 10) }
		if b[1] ~= 0 or b[2] ~= 0 or b[3] ~= 0 or b[4] ~= 0 then
			return false, "frame too large"
		end
		len = ((b[5] * 256 + b[6]) * 256 + b[7]) * 256 + b[8]
	end
	if len > M.MAX_MESSAGE then return false, "frame too large" end

	local mask
	if masked then
		if #buf < header + 4 then return nil end
		mask = { buf:byte(header + 1, header + 4) }
		header = header + 4
	end

	if #buf < header + len then return nil end

	local payload = buf:sub(header + 1, header + len)
	if mask then payload = M.mask_payload(payload, mask) end

	return { fin = fin, opcode = opcode, payload = payload }, header + len
end

-- Aggiunge byte al buffer ed estrae tutti gli eventi completi:
--   { type = "message", opcode = 1|2, payload = "..." }
--   { type = "ping", payload = "..." }  { type = "pong" }
--   { type = "close", code = n|nil, reason = "..." }
-- In caso di errore restituisce nil, messaggio: la connessione va chiusa.
function Parser:feed(data)
	self.buf = self.buf .. data
	local events = {}

	while true do
		local frame, used = read_frame(self.buf)
		if frame == nil then break end
		if frame == false then return nil, used end
		self.buf = self.buf:sub(used + 1)

		local op = frame.opcode
		if op >= 0x8 then
			-- frame di controllo: devono essere interi e al massimo 125 byte
			if not frame.fin or #frame.payload > 125 then
				return nil, "invalid control frame"
			end
			if op == M.OP_PING then
				events[#events + 1] = { type = "ping", payload = frame.payload }
			elseif op == M.OP_PONG then
				events[#events + 1] = { type = "pong" }
			elseif op == M.OP_CLOSE then
				local code, reason
				if #frame.payload >= 2 then
					local h, l = frame.payload:byte(1, 2)
					code = h * 256 + l
					reason = frame.payload:sub(3)
				end
				events[#events + 1] = { type = "close", code = code, reason = reason or "" }
			else
				return nil, "unknown control opcode " .. op
			end
		elseif op == M.OP_CONTINUATION then
			if not self.fragments then return nil, "continuation without start" end
			self.fragments.parts[#self.fragments.parts + 1] = frame.payload
			self.fragments.size = self.fragments.size + #frame.payload
			if self.fragments.size > M.MAX_MESSAGE then return nil, "message too large" end
			if frame.fin then
				events[#events + 1] = { type = "message", opcode = self.fragments.opcode,
					payload = table.concat(self.fragments.parts) }
				self.fragments = nil
			end
		elseif op == M.OP_TEXT or op == M.OP_BINARY then
			if self.fragments then return nil, "new message inside a fragmented one" end
			if frame.fin then
				events[#events + 1] = { type = "message", opcode = op, payload = frame.payload }
			else
				self.fragments = { opcode = op, parts = { frame.payload }, size = #frame.payload }
			end
		else
			return nil, "unknown opcode " .. op
		end
	end

	return events
end

return M
