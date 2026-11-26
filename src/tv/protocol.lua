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

-- Risposta di GET /api/v2/applications/<id>: {"running":true,"visible":false,...}
-- Restituisce { running = bool|nil, visible = bool|nil } (nil se il campo manca).
function M.parse_app_state(response)
	local function flag(name)
		local value = tostring(response):match('"' .. name .. '"%s*:%s*(%a+)')
		if value == "true" then return true end
		if value == "false" then return false end
		return nil
	end
	return { running = flag("running"), visible = flag("visible") }
end

-- ------------------------------------------------------------
-- Percorso video della stanza (variabile CURRENT_VIDEO_PATH di Director):
--   <devices><device><id>372</id><provider_binding_id>3101</provider_binding_id>
--   <consumer_binding_id>0</consumer_binding_id></device>...</devices>
-- ------------------------------------------------------------
M.APP_SWITCH_VIDEO_OUT = 2110 -- uscita video dell'App Switcher (driver.xml)
M.TV_APP_SWITCH_IN = 1102     -- ingresso della TV collegato all'App Switcher (driver.xml)

function M.parse_path(xml)
	local devices = {}
	for id, provider, consumer in tostring(xml):gmatch(
		"<device>%s*<id>(%d+)</id>%s*<provider_binding_id>(%d+)</provider_binding_id>"
		.. "%s*<consumer_binding_id>(%d+)</consumer_binding_id>%s*</device>") do
		devices[#devices + 1] = { id = tonumber(id), provider = tonumber(provider), consumer = tonumber(consumer) }
	end
	return devices
end

-- Il percorso passa dal nostro App Switcher? `mine` e' l'insieme degli id delle
-- proxy di questo driver (id -> true). Restituisce l'id della nostra TV (la
-- proxy il cui ingresso 1102 e' collegato), oppure nil e il motivo.
function M.route_through_app_switch(pathXml, mine)
	local viaSwitch, tvId = false, nil
	for _, device in ipairs(M.parse_path(pathXml)) do
		if mine[device.id] then
			if device.provider == M.APP_SWITCH_VIDEO_OUT then viaSwitch = true end
			if device.consumer == M.TV_APP_SWITCH_IN then tvId = device.id end
		end
	end
	if not viaSwitch then return nil, "the room source is not behind the App Switcher" end
	if not tvId then return nil, "own TV not found in the video path" end
	return tvId
end

-- Il percorso video della stanza passa da una delle nostre proxy? Vero quando la
-- stanza sta usando questa TV (con una sorgente HDMI o con l'App Switcher).
function M.path_uses_own_device(pathXml, mine)
	for _, device in ipairs(M.parse_path(pathXml)) do
		if mine[device.id] then return true end
	end
	return false
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

-- App lanciabili, nell'ordine in cui compaiono nelle proprieta' "MiniApp N App"
M.APP_NAMES = {
	"Netflix", "YouTube", "Prime Video", "Disney+", "Spotify", "Apple TV", "DAZN", "RaiPlay",
	"Paramount+", "Plex",
}

-- Slot MiniApp (binding della proxy avswitch) con l'app predefinita. La
-- proprieta' "MiniApp N App" (N = posizione nell'elenco) permette di
-- assegnare a ogni slot l'app che si vuole: Director manda solo il numero
-- dello slot, il driver non sa quale minidriver ci sia collegato.
M.MINI_APP_SLOTS = {
	{ id = "3201", default = "Netflix" },
	{ id = "3202", default = "YouTube" },
	{ id = "3203", default = "Prime Video" },
	{ id = "3204", default = "Disney+" },
	{ id = "3205", default = "Spotify" },
	{ id = "3206", default = "Apple TV" },
	{ id = "3207", default = "DAZN" },
	{ id = "3208", default = "RaiPlay" },
	{ id = "3209", default = "Paramount+" },
}

-- Valore della proprieta' che disattiva uno slot
M.NOT_USED = "Not used"

-- "3204" -> "MiniApp 4 App", slot; nil se non e' uno slot MiniApp.
function M.mini_app_property(slotId)
	local id = tostring(slotId)
	for index, slot in ipairs(M.MINI_APP_SLOTS) do
		if slot.id == id then return "MiniApp " .. index .. " App", slot end
	end
	return nil
end

-- App da lanciare per uno slot: la scelta nella proprieta' se c'e', altrimenti
-- il predefinito. `readProperty(nome)` legge il valore della proprieta'.
-- Restituisce il nome dell'app oppure nil e il motivo.
function M.mini_app_for(slotId, readProperty)
	local property, slot = M.mini_app_property(slotId)
	if not property then return nil, "not a MiniApp slot" end

	local choice = readProperty and readProperty(property)
	if choice == nil or choice == "" then choice = slot.default end
	if choice == M.NOT_USED then return nil, "no app assigned to the slot" end
	if not M.APP_IDS[choice] then return nil, "unknown app '" .. tostring(choice) .. "'" end
	return choice
end

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
	["Plex"] = "3201512006963",
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
