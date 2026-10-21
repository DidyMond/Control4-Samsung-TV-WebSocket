-- ============================================================
-- lib/websocket.lua - client WebSocket (RFC 6455) su connessioni DriverWorks
--
-- Scritto a partire dalla sola RFC 6455 e dalla documentazione DriverWorks:
-- nessun codice di terzi. Il codec dei frame sta in lib/ws_frame.lua.
--
--   local ws = WebSocket.new("wss://192.168.1.10:8002/path?x=1", {
--       ssl_options = { verify_mode = "none", method = "tlsv1_2" },
--       on_open    = function(ws) end,
--       on_message = function(ws, text) end,
--       on_close   = function(ws, reason) end,   -- "remote" | "offline" | "error: ..."
--   })
--   ws:connect()
--   ws:send_text("...")
--   ws:close()      -- chiusura locale: on_close NON viene chiamata
--
-- Ogni socket usa un binding di rete dinamico libero fra 6100 e 6199. Alla
-- chiusura il binding resta occupato per ~1 s, cosi' il frame CLOSE arriva
-- alla TV prima che il TCP venga abbattuto: un teardown immediato lasciava
-- sulla TV una sessione "zombie" che faceva cadere la connessione successiva.
-- ============================================================

local frame = require "lib.ws_frame"
local net = require "lib.net"
local timer = require "lib.timer"
local log = require "lib.log"

local M = {}

local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
local FIRST_BINDING, LAST_BINDING = 6100, 6199
local TEARDOWN_DELAY_MS = 1000
local MAX_HANDSHAKE_BYTES = 8192

local TAG = "WS"

-- binding -> socket che lo possiede
local owners = {}

math.randomseed(os.time())

local WebSocket = {}
WebSocket.__index = WebSocket

-- "wss://host:8002/risorsa?x=1" -> "wss", "host", 8002, "/risorsa?x=1"
function M.parse_url(url)
	local scheme, host, port, resource = tostring(url):match("^(wss?)://([^/:]+):?(%d*)(/?.*)$")
	if not scheme then return nil, "invalid WebSocket URL" end
	if port == "" then
		port = (scheme == "wss") and 443 or 80
	else
		port = tonumber(port)
	end
	if resource == "" then resource = "/" end
	return scheme, host, port, resource
end

function M.new(url, opts)
	opts = opts or {}
	local scheme, host, port, resource = M.parse_url(url)
	if not scheme then return nil, host end
	return setmetatable({
		url = url,
		scheme = scheme,
		host = host,
		port = port,
		resource = resource,
		ssl_options = opts.ssl_options,
		on_open = opts.on_open,
		on_message = opts.on_message,
		on_close = opts.on_close,
		state = "idle", -- idle | connecting | handshake | open | closed
		buf = "",
		parser = frame.new_parser(),
	}, WebSocket)
end

local function find_free_binding()
	for id = FIRST_BINDING, LAST_BINDING do
		if not owners[id] then
			local address = C4:GetBindingAddress(id)
			if address == nil or address == "" then return id end
		end
	end
	return nil
end

-- Le callback dell'utente non devono mai far saltare il parsing della rete.
local function call(fn, ...)
	if not fn then return end
	local ok, err = pcall(fn, ...)
	if not ok then log.error(TAG, "callback error: " .. tostring(err)) end
end

function WebSocket:is_open()
	return self.state == "open"
end

-- TCP connesso (anche se l'handshake WebSocket non e' ancora finito)
function WebSocket:is_connected()
	return self.state == "handshake" or self.state == "open"
end

function WebSocket:connect()
	if self.state ~= "idle" then return self end

	local binding = find_free_binding()
	if not binding then
		self:_finish("error: no free network binding")
		return self
	end

	self.binding = binding
	owners[binding] = self
	self.state = "connecting"

	if self.scheme == "wss" then
		C4:CreateNetworkConnection(binding, self.host, "SSL")
		C4:NetPortOptions(binding, self.port, "SSL", self.ssl_options or {})
	else
		C4:CreateNetworkConnection(binding, self.host)
	end

	net.register(binding,
		function(_, _, status) self:_on_status(status) end,
		function(_, _, data) self:_on_data(data) end)

	log.debug(TAG, "connecting (binding " .. binding .. ")")
	C4:NetConnect(binding, self.port)
	return self
end

function WebSocket:_send_raw(packet)
	C4:SendToNetwork(self.binding, self.port, packet)
end

local function random_mask()
	return { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
end

function WebSocket:send_text(text)
	if self.state ~= "open" then return false end
	self:_send_raw(frame.encode(frame.OP_TEXT, text, random_mask()))
	return true
end

function WebSocket:_send_handshake()
	-- 16 byte casuali (caratteri stampabili) in Base64, come richiesto da RFC 6455 par. 4.1
	local raw = {}
	for i = 1, 16 do raw[i] = string.char(math.random(33, 125)) end
	self.key = C4:Base64Encode(table.concat(raw))

	local lines = {
		"GET " .. self.resource .. " HTTP/1.1",
		"Host: " .. self.host .. ":" .. self.port,
		"Connection: Upgrade",
		"Upgrade: websocket",
		"Sec-WebSocket-Key: " .. self.key,
		"Sec-WebSocket-Version: 13",
		"Cache-Control: no-cache",
		"Pragma: no-cache",
		"",
		"",
	}
	self:_send_raw(table.concat(lines, "\r\n"))
end

-- Libera il binding e le sue callback (solo se e' ancora il nostro).
function WebSocket:_release()
	local binding = self.binding
	if binding and owners[binding] == self then
		owners[binding] = nil
		net.unregister(binding)
		C4:NetDisconnect(binding, self.port)
		C4:SetBindingAddress(binding, "")
	end
end

function WebSocket:_schedule_release()
	if self.release_timer then return end
	self.release_timer = timer.after(TEARDOWN_DELAY_MS, function()
		self.release_timer = nil
		self:_release()
	end)
end

-- Chiusura "da errore" o "dal lato remoto": notifica on_close una sola volta.
function WebSocket:_finish(reason)
	if self.state == "closed" then return end
	local was_open = (self.state == "open")
	self.state = "closed"
	if self.binding then
		if was_open then
			self:_schedule_release()
		else
			self:_release()
		end
	end
	call(self.on_close, self, reason)
end

function WebSocket:_on_status(status)
	if self.state == "closed" then return end
	if status == "ONLINE" then
		if self.state == "connecting" then
			self.state = "handshake"
			self:_send_handshake()
		end
	else
		-- OFFLINE: TCP caduto (TV spenta, rifiuto, chiusura dalla TV)
		self:_finish("offline")
	end
end

-- Risposta HTTP all'upgrade: "HTTP/1.1 101 ...", header, riga vuota.
-- Restituisce true se valida, altrimenti false e il motivo.
function WebSocket:_check_handshake(head)
	local status = head:match("^HTTP/%d%.%d (%d+)")
	if status ~= "101" then
		return false, "handshake rejected (HTTP " .. tostring(status) .. ")"
	end
	local headers = {}
	for name, value in head:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do
		headers[name:lower()] = value
	end
	if (headers["upgrade"] or ""):lower() ~= "websocket" then
		return false, "handshake: missing Upgrade header"
	end
	if not (headers["connection"] or ""):lower():find("upgrade", 1, true) then
		return false, "handshake: missing Connection header"
	end
	-- 'SHA1' maiuscolo: il minuscolo non e' riconosciuto da C4:Hash
	local expected = C4:Hash("SHA1", self.key .. GUID, { return_encoding = "BASE64" })
	if headers["sec-websocket-accept"] ~= expected then
		return false, "handshake: bad Sec-WebSocket-Accept"
	end
	return true
end

function WebSocket:_on_data(data)
	if self.state == "handshake" then
		self.buf = self.buf .. data
		local eoh = self.buf:find("\r\n\r\n", 1, true)
		if not eoh then
			if #self.buf > MAX_HANDSHAKE_BYTES then
				self:_fail("handshake response too long")
			end
			return
		end
		local head = self.buf:sub(1, eoh + 1)
		local rest = self.buf:sub(eoh + 4)
		self.buf = ""

		local ok, why = self:_check_handshake(head)
		if not ok then
			self:_fail(why)
			return
		end
		self.state = "open"
		log.debug(TAG, "handshake completed")
		call(self.on_open, self)
		-- eventuali frame arrivati insieme alla risposta 101
		if self.state == "open" and #rest > 0 then
			self:_on_frames(rest)
		end
	elseif self.state == "open" then
		self:_on_frames(data)
	end
end

function WebSocket:_on_frames(data)
	local events, err = self.parser:feed(data)
	if not events then
		self:_fail("protocol error: " .. tostring(err))
		return
	end
	for _, event in ipairs(events) do
		if self.state ~= "open" then return end
		if event.type == "message" then
			call(self.on_message, self, event.payload)
		elseif event.type == "ping" then
			self:_send_raw(frame.encode(frame.OP_PONG, event.payload, random_mask()))
		elseif event.type == "close" then
			-- rispondiamo con CLOSE (stesso codice) e chiudiamo il TCP dopo la pausa
			self:_send_raw(frame.encode(frame.OP_CLOSE,
				frame.close_payload(event.code or 1000, ""), random_mask()))
			self:_finish("remote")
		end
	end
end

function WebSocket:_fail(why)
	log.warn(TAG, why)
	self:_finish("error: " .. why)
end

-- Chiusura voluta da noi: invia CLOSE, libera il binding dopo la pausa.
-- on_close non viene chiamata (la chiusura e' gia' una decisione del chiamante).
function WebSocket:close()
	local state = self.state
	if state == "closed" then return self end
	self.state = "closed"
	if state == "open" then
		self:_send_raw(frame.encode(frame.OP_CLOSE, frame.close_payload(1000, ""), random_mask()))
		self:_schedule_release()
	elseif self.binding then
		self:_release()
	end
	return self
end

return M
