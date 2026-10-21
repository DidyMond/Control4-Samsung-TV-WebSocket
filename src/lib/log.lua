-- ============================================================
-- lib/log.lua - logging con Log Mode / Log Level e tag
--
-- Severita' (0 = piu' grave):
--   0 Alert | 1 Error | 2 Warning | 3 Info | 4 Trace | 5 Debug
-- Un messaggio di severita' S e' emesso solo se S <= Log Level.
-- Log Mode: "Off" | "Print" | "Log" | "Print and Log"
--   Print = print() (Lua Output di Composer)
--   Log   = C4:ErrorLog() (System Manager Logging)
--
-- Ogni riga ha un tag fra parentesi ([REST], [WS], [PAIR]...) per filtrare
-- i log nelle segnalazioni. Il token di abbinamento viene sempre oscurato.
--
--   Log.info("REST", "state -> ON")
--
-- I sink (print / log) si possono sostituire con Log.set_sinks() nei test.
-- ============================================================

local util = require "lib.util"

local M = {}

M.ALERT, M.ERROR, M.WARNING, M.INFO, M.TRACE, M.DEBUG = 0, 1, 2, 3, 4, 5

local mode = "Off"
local level = M.INFO

local sinks = {
	print = function(line) print(line) end,
	log = function(line) C4:ErrorLog(line) end,
}

function M.set_sinks(new_sinks)
	sinks = new_sinks
end

-- Estrae la severita' da "3 - Info" o da un numero; Info se illeggibile.
function M.parse_level(value)
	local n = tonumber(value)
	if not n and type(value) == "string" then
		n = tonumber(value:match("^%s*(%d+)"))
	end
	if not n then return M.INFO end
	n = math.floor(n)
	if n < 0 then n = 0 end
	if n > 5 then n = 5 end
	return n
end

function M.set_mode(value)
	if value == "Print" or value == "Log" or value == "Print and Log" then
		mode = value
	else
		mode = "Off"
	end
end

function M.set_level(value)
	level = M.parse_level(value)
end

function M.get_mode() return mode end
function M.get_level() return level end

local function emit(severity, tag, message)
	if mode == "Off" or severity > level then return end
	local ok, ts = pcall(os.date, "%H:%M:%S")
	local line = (ok and ts or "") .. " [" .. tag .. "] " .. util.redact(message)
	if mode == "Print" or mode == "Print and Log" then
		sinks.print(line)
	end
	if mode == "Log" or mode == "Print and Log" then
		sinks.log(line)
	end
end

-- Gli errori non gestiti passano da qui con severita' Error ma ignorando
-- Log Mode = Off: un crash silenzioso e' peggio di una riga in piu'.
function M.unhandled(tag, message)
	local line = "[" .. tag .. "] " .. util.redact(message)
	if mode == "Off" then
		sinks.print(line)
	else
		emit(M.ERROR, tag, message)
	end
end

function M.alert(tag, message) emit(M.ALERT, tag, message) end
function M.error(tag, message) emit(M.ERROR, tag, message) end
function M.warn(tag, message)  emit(M.WARNING, tag, message) end
function M.info(tag, message)  emit(M.INFO, tag, message) end
function M.trace(tag, message) emit(M.TRACE, tag, message) end
function M.debug(tag, message) emit(M.DEBUG, tag, message) end

return M
