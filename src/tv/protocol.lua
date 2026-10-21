-- ============================================================
-- tv/protocol.lua - conoscenza del protocollo Samsung Tizen e dei comandi
-- proxy Control4, senza I/O (Lua 5.1 puro, nessun riferimento a C4).
-- ============================================================

local M = {}

-- ------------------------------------------------------------
-- Binding del driver (devono coincidere con driver.xml)
-- ------------------------------------------------------------
M.TV_PROXY = 5000
M.AVSWITCH_PROXY = 5002

-- ------------------------------------------------------------
-- Messaggi della TV
-- ------------------------------------------------------------

-- Il token di abbinamento e' numerico (~8 cifre); la TV lo manda a volte
-- fra virgolette (`"token":"123"`) e a volte no (`"token":123`).
function M.extract_token(data)
	local token = data:match('"token"%s*:%s*"([^"]+)"')
	if not token then
		token = data:match('"token"%s*:%s*(%d+)')
	end
	return token
end

-- Risposta REST di GET /api/v2/ -> "ON" | "OFF", motivo (per i log).
--   corpo vuoto (nessuna risposta, timeout)  -> OFF
--   "PowerState":"On"                        -> ON
--   altro PowerState ("standby", "Off"...)   -> OFF
--   risposta senza PowerState                -> ON (la TV risponde, quindi e' viva)
function M.parse_power_state(body)
	if body == nil or body == "" then
		return "OFF", "no response"
	end
	local ps = body:match('"PowerState"%s*:%s*"([^"]+)"')
	if not ps then
		return "ON", "response without PowerState"
	end
	if ps:lower() == "on" then
		return "ON", "PowerState " .. ps
	end
	return "OFF", "PowerState " .. ps
end

-- Codice di stato di una risposta HTTP ("HTTP/1.1 200 OK" -> 200).
function M.http_status(response)
	local code = tostring(response):match("^HTTP/%d%.%d (%d+)")
	return code and tonumber(code) or nil
end

-- ------------------------------------------------------------
-- Tasti: i codici Samsung accettati da SEND_KEY / ms.remote.control sono
-- KEY_* alfanumerici. Qualunque altro carattere romperebbe il JSON.
-- ------------------------------------------------------------
function M.is_valid_key(keyCode)
	return type(keyCode) == "string" and keyCode:match("^[%w_]+$") ~= nil
end

-- Il payload ha spazi e a-capo: la TV lo accetta e funziona da sempre, non
-- riformattarlo.
function M.remote_key_payload(keyCode)
	return [[
    {
        "method": "ms.remote.control",
        "params": {
            "Cmd": "Click",
            "DataOfCmd": "]] .. keyCode .. [[",
            "Option": "false",
            "TypeOfRemote": "SendRemoteKey"
        }
    }]]
end

-- ------------------------------------------------------------
-- Comandi proxy Control4 -> tasti Samsung
-- (nomi dalla documentazione ufficiale dei proxy TV)
-- ------------------------------------------------------------
M.KEY_MAP = {
	-- Volume
	PULSE_VOL_UP = "KEY_VOLUP",
	PULSE_VOL_DOWN = "KEY_VOLDOWN",
	MUTE_ON = "KEY_MUTE",
	MUTE_OFF = "KEY_MUTE",
	MUTE_TOGGLE = "KEY_MUTE",
	-- Canali
	PULSE_CH_UP = "KEY_CHUP",
	PULSE_CH_DOWN = "KEY_CHDOWN",
	PULSE_CHANNEL_UP = "KEY_CHUP",
	PULSE_CHANNEL_DOWN = "KEY_CHDOWN",
	-- Navigazione
	UP = "KEY_UP",
	DOWN = "KEY_DOWN",
	LEFT = "KEY_LEFT",
	RIGHT = "KEY_RIGHT",
	START_UP = "KEY_UP",
	START_DOWN = "KEY_DOWN",
	START_LEFT = "KEY_LEFT",
	START_RIGHT = "KEY_RIGHT",
	START_PAGE_LEFT = "KEY_LEFT",
	START_PAGE_RIGHT = "KEY_RIGHT",
	ENTER = "KEY_ENTER",
	CANCEL = "KEY_RETURN",
	MENU = "KEY_MENU",
	GUIDE = "KEY_GUIDE",
	INFO = "KEY_INFO",
	PAGE_UP = "KEY_UP",
	PAGE_DOWN = "KEY_DOWN",
	-- Tasti colore
	PROGRAM_A = "KEY_RED",
	PROGRAM_B = "KEY_GREEN",
	PROGRAM_C = "KEY_YELLOW",
	PROGRAM_D = "KEY_BLUE",
	-- Trasporto
	PLAY = "KEY_PLAY",
	PAUSE = "KEY_PAUSE",
	STOP = "KEY_STOP",
	SKIP_FWD = "KEY_FF",
	SKIP_REV = "KEY_RW",
	SCAN_FWD = "KEY_FF",
	SCAN_REV = "KEY_RW",
	RECORD = "KEY_REC",
	PVR = "KEY_REC",
	-- Numeri
	NUMBER_0 = "KEY_0", NUMBER_1 = "KEY_1", NUMBER_2 = "KEY_2", NUMBER_3 = "KEY_3",
	NUMBER_4 = "KEY_4", NUMBER_5 = "KEY_5", NUMBER_6 = "KEY_6", NUMBER_7 = "KEY_7",
	NUMBER_8 = "KEY_8", NUMBER_9 = "KEY_9",
}

-- PASSTHROUGH (tastierino a schermo del Navigator con un'app aperta):
-- stessi tasti del KEY_MAP piu' EJECT, che chiude l'app corrente.
M.PASSTHROUGH_MAP = {
	EJECT = "KEY_EXIT",
	DOWN = "KEY_DOWN", UP = "KEY_UP", LEFT = "KEY_LEFT", RIGHT = "KEY_RIGHT",
	ENTER = "KEY_ENTER", MENU = "KEY_MENU",
	PLAY = "KEY_PLAY", PAUSE = "KEY_PAUSE", STOP = "KEY_STOP",
	SKIP_FWD = "KEY_FF", SKIP_REV = "KEY_RW", SCAN_FWD = "KEY_FF", SCAN_REV = "KEY_RW",
	INFO = "KEY_INFO", GUIDE = "KEY_GUIDE",
	BACK = "KEY_RETURN", CANCEL = "KEY_RETURN",
}

-- Pressione prolungata: START_* ripete il tasto finche' non arriva STOP_*.
M.REPEAT_MAP = {
	START_VOL_UP = { key = "KEY_VOLUP", interval_ms = 300 },
	START_VOL_DOWN = { key = "KEY_VOLDOWN", interval_ms = 300 },
	START_CH_UP = { key = "KEY_CHUP", interval_ms = 500 },
	START_CH_DOWN = { key = "KEY_CHDOWN", interval_ms = 500 },
}
M.STOP_REPEAT = {
	STOP_VOL_UP = true, STOP_VOL_DOWN = true, STOP_CH_UP = true, STOP_CH_DOWN = true,
}

-- Ingressi HDMI fisici (binding della proxy TV) -> tasto Samsung
M.HDMI_MAP = {
	["1001"] = "KEY_HDMI1",
	["1002"] = "KEY_HDMI2",
	["1003"] = "KEY_HDMI3",
}

-- Slot MiniApp (binding della proxy avswitch) -> nome dell'app
M.MINI_APP_MAP = {
	["3201"] = "Netflix",
	["3202"] = "YouTube",
	["3203"] = "Prime Video",
	["3204"] = "Disney+",
	["3205"] = "Spotify",
	["3206"] = "Apple TV",
	["3207"] = "DAZN",
	["3208"] = "RaiPlay",
	["3209"] = "Paramount+",
}

-- Nome dell'app -> id applicazione Tizen (POST /api/v2/applications/<id>)
M.APP_IDS = {
	["Netflix"] = "3201907018807",
	["YouTube"] = "111299001912",
	["Prime Video"] = "3201910019365",
	["Disney+"] = "3201901017640",
	["Apple TV"] = "3201807016597",
	["Spotify"] = "3201606009684",
	["DAZN"] = "3201806016390",
	["RaiPlay"] = "111399002034",
	["Paramount+"] = "3202110025305",
}

-- Comandi di routing/stato AV che Director manda di continuo e che non
-- richiedono nessuna azione sulla TV.
local HOUSEKEEPING = {
	CONNECT_OUTPUT = true,
	DISCONNECT_OUTPUT = true,
	SELECT_SOURCE = true,
	GET_VOLUME_LEVEL = true,
	GET_CURRENT_SOURCE = true,
}

function M.is_housekeeping(binding, command)
	if HOUSEKEEPING[command] then return true end
	-- ON/OFF sulla proxy avswitch sono routing, non accensione della TV
	return binding == M.AVSWITCH_PROXY and (command == "ON" or command == "OFF")
end

return M
