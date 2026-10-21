-- ============================================================
-- tests/support/fake_c4.lua - ambiente DriverWorks finto per i test
--
--   local fake = require "tests.support.fake_c4"
--   local env = fake.install()          -- crea C4, Properties, Log sink catturato
--   env.advance(2500)                    -- fa scorrere il tempo simulato (ms)
--   env.deliver_status(6099, "ONLINE")   -- evento di rete verso il driver
--   env.sent[6099]                       -- cio' che il driver ha inviato
--
-- install() scarica anche i moduli del driver da package.loaded, cosi'
-- ogni test riparte da uno stato pulito.
-- ============================================================

local F = {}

local bit = bit
local floor = math.floor

-- ------------------------------------------------------------
-- SHA1 e Base64 reali: servono a validare Sec-WebSocket-Accept
-- ------------------------------------------------------------
local function sha1_hex(msg)
	local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
	local ml = #msg * 8
	msg = msg .. "\128" .. string.rep("\0", (55 - #msg) % 64)
		.. string.char(0, 0, 0, 0, floor(ml / 16777216) % 256, floor(ml / 65536) % 256,
			floor(ml / 256) % 256, ml % 256)
	local tobit, bor, band, bxor, bnot = bit.tobit, bit.bor, bit.band, bit.bxor, bit.bnot
	local lshift, rol = bit.lshift, bit.rol

	for chunk = 1, #msg, 64 do
		local w = {}
		for i = 0, 15 do
			local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
			w[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
		end
		for i = 16, 79 do
			w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
		end
		local a, b, c, d, e = h0, h1, h2, h3, h4
		for i = 0, 79 do
			local f, k
			if i < 20 then
				f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
			elseif i < 40 then
				f, k = bxor(b, c, d), 0x6ED9EBA1
			elseif i < 60 then
				f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
			else
				f, k = bxor(b, c, d), 0xCA62C1D6
			end
			local temp = tobit(rol(a, 5) + f + e + k + w[i])
			e, d, c, b, a = d, c, rol(b, 30), a, temp
		end
		h0, h1, h2, h3, h4 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d), tobit(h4 + e)
	end
	return bit.tohex(h0) .. bit.tohex(h1) .. bit.tohex(h2) .. bit.tohex(h3) .. bit.tohex(h4)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1, c2, c3, c4 = floor(n / 262144) % 64, floor(n / 4096) % 64, floor(n / 64) % 64, n % 64
		out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
			.. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
	end
	return table.concat(out)
end

local function hex_to_bytes(hex)
	return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

F.sha1_hex = sha1_hex
F.base64 = base64

-- Accept atteso dal client per una chiave, come lo calcolerebbe la TV
function F.accept_for(key)
	return base64(hex_to_bytes(sha1_hex(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))
end

-- ------------------------------------------------------------
local OUR_MODULES = {
	"lib.log", "lib.timer", "lib.net", "lib.util", "lib.websocket", "lib.ws_frame",
	"tv.protocol", "tv.samsung_tv", "tv.commands",
}

function F.install()
	for _, name in ipairs(OUR_MODULES) do package.loaded[name] = nil end

	local env = {
		now = 0,
		timers = {},     -- id -> { at = ms }
		next_timer = 1,
		persist = {},
		updates = {},    -- { name, value }
		proxy = {},      -- { binding, command, params, notify }
		conns = {},      -- binding -> { host, ssl }
		connects = {},   -- lista di { binding, port }
		disconnects = {},
		sent = {},       -- binding -> lista di stringhe inviate
		addresses = {},  -- binding -> host (GetBindingAddress)
		errorlog = {},
		printed = {},
	}

	Properties = {
		["IP Address"] = "192.168.1.50",
		["Port"] = "8002",
		["Device Name"] = "Control4-TV",
		["Pairing"] = "Select...",
		["Pairing Status"] = "Not paired",
		["Log Level"] = "5 - Debug",
		["Log Mode"] = "Print",
	}

	C4 = {}
	function C4:AddTimer(ms, units)
		local id = env.next_timer
		env.next_timer = id + 1
		env.timers[id] = { at = env.now + ms }
		return id
	end
	function C4:KillTimer(id) env.timers[id] = nil end
	function C4:PersistGetValue(key) return env.persist[key] end
	function C4:PersistSetValue(key, value) env.persist[key] = value end
	function C4:UpdateProperty(name, value)
		Properties[name] = value
		env.updates[#env.updates + 1] = { name, value }
	end
	function C4:SendToProxy(binding, command, params, notify)
		env.proxy[#env.proxy + 1] = { binding = binding, command = command, params = params, notify = notify }
	end
	function C4:Base64Encode(data) return base64(data) end
	function C4:Hash(algorithm, data, options)
		assert(algorithm == "SHA1", "C4:Hash vuole 'SHA1' maiuscolo")
		return base64(hex_to_bytes(sha1_hex(data)))
	end
	function C4:GetBindingAddress(binding) return env.addresses[binding] end
	function C4:SetBindingAddress(binding, address)
		env.addresses[binding] = (address ~= "") and address or nil
	end
	function C4:CreateNetworkConnection(binding, host, ssl)
		env.conns[binding] = { host = host, ssl = ssl }
		env.addresses[binding] = host
	end
	function C4:NetPortOptions(binding, port, mode, options)
		env.conns[binding] = env.conns[binding] or {}
		env.conns[binding].options = options
	end
	function C4:NetConnect(binding, port)
		env.connects[#env.connects + 1] = { binding = binding, port = port }
	end
	function C4:NetDisconnect(binding, port)
		env.disconnects[#env.disconnects + 1] = { binding = binding, port = port }
	end
	function C4:SendToNetwork(binding, port, data)
		env.sent[binding] = env.sent[binding] or {}
		table.insert(env.sent[binding], data)
	end
	function C4:ErrorLog(line) env.errorlog[#env.errorlog + 1] = line end

	-- ---- helper per i test ----

	-- Fa scorrere il tempo simulato eseguendo i timer in ordine di scadenza.
	function env.advance(ms)
		local target = env.now + ms
		while true do
			local best_id, best_at
			for id, t in pairs(env.timers) do
				if t.at <= target and (not best_at or t.at < best_at or (t.at == best_at and id < best_id)) then
					best_id, best_at = id, t.at
				end
			end
			if not best_id then break end
			env.now = best_at
			env.timers[best_id] = nil
			require("lib.timer").fire(best_id)
		end
		env.now = target
	end

	function env.pending_timers()
		local n = 0
		for _ in pairs(env.timers) do n = n + 1 end
		return n
	end

	function env.deliver_status(binding, status)
		return require("lib.net").dispatch_status(binding, 0, status)
	end

	function env.deliver_data(binding, data)
		return require("lib.net").dispatch_data(binding, 0, data)
	end

	-- Cattura print() e la porta in env.printed
	local real_print = print
	function env.capture_print()
		print = function(line) env.printed[#env.printed + 1] = tostring(line) end
	end
	function env.restore_print() print = real_print end

	-- Log pulito e silenzioso di default (i test accendono cio' che serve)
	local log = require "lib.log"
	log.set_sinks({
		print = function(line) env.printed[#env.printed + 1] = line end,
		log = function(line) env.errorlog[#env.errorlog + 1] = line end,
	})
	log.set_mode("Print")
	log.set_level(5)

	-- Ultimo pacchetto inviato su un binding
	function env.last_sent(binding)
		local list = env.sent[binding]
		return list and list[#list]
	end

	return env
end

return F
