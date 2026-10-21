-- Coerenza di src/driver.xml con il codice Lua e con la documentazione
local t = require "tests.support.harness"
local protocol = require "tv.protocol"

local function read(path)
	local f = assert(io.open(path, "rb"))
	local text = f:read("*a")
	f:close()
	return text
end

local xml = read("src/driver.xml")

-- File Lua del driver (senza lfs non si puo' elencare la cartella)
local LUA_FILES = {
	"src/driver.lua", "src/lib/log.lua", "src/lib/net.lua", "src/lib/timer.lua", "src/lib/util.lua",
	"src/lib/websocket.lua", "src/lib/ws_frame.lua", "src/tv/commands.lua", "src/tv/protocol.lua",
	"src/tv/samsung_tv.lua",
}

t.test("driver_name = nome del pacchetto e script non cifrato", function()
	t.eq(xml:match("<driver_name>([^<]+)</driver_name>"), "samsung_tv_websocket")
	t.contains(xml, '<script file="driver.lua" encryption="0">')
end)

t.test("versione YYMMDDNNN e uguale al default di 'Driver Version'", function()
	local version = xml:match("<version>(%d+)</version>")
	t.truthy(version and #version == 9, "versione: " .. tostring(version))
	local shown = xml:match("<name>Driver Version</name>%s*<type>STRING</type>%s*<readonly>true</readonly>%s*<default>(%d+)</default>")
	t.eq(shown, version)
end)

t.test("copyright MIT, niente 'All rights reserved'", function()
	local copyright = xml:match("<copyright>([^<]*)</copyright>")
	t.contains(copyright, "MIT")
	t.falsy(xml:find("All rights reserved", 1, true))
end)

t.test("ogni proprieta' usata dal Lua e' dichiarata nell'XML", function()
	local missing = {}
	for _, path in ipairs(LUA_FILES) do
		local text = read(path)
		for name in text:gmatch('Properties%["([^"]+)"%]') do
			if not xml:find("<name>" .. name .. "</name>", 1, true) then
				missing[name] = path
			end
		end
		for name in text:gmatch('UpdateProperty%("([^"]+)"') do
			if not xml:find("<name>" .. name .. "</name>", 1, true) then
				missing[name] = path
			end
		end
	end
	for name, path in pairs(missing) do error("proprieta' '" .. name .. "' (usata in " .. path .. ") non e' nel driver.xml") end
end)

t.test("Pairing: i valori della LIST sono quelli che il codice confronta", function()
	t.contains(xml, "<item>Select...</item>")
	t.contains(xml, "<item>Pair with TV</item>")
	t.contains(xml, "<item>Unpair</item>")
	local driver = read("src/driver.lua")
	t.contains(driver, '"Pair with TV"')
	t.contains(driver, '"Unpair"')
end)

t.test("Log Mode default Off, Log Level default Info, stessi valori dello standard", function()
	t.truthy(xml:find("<name>Log Mode</name>%s*<type>LIST</type>%s*<readonly>false</readonly>%s*<default>Off</default>"))
	t.truthy(xml:find("<name>Log Level</name>%s*<type>LIST</type>%s*<readonly>false</readonly>%s*<default>3 %- Info</default>"))
	for _, item in ipairs({ "0 - Alert", "1 - Error", "2 - Warning", "3 - Info", "4 - Trace", "5 - Debug",
		"Off", "Print", "Log", "Print and Log" }) do
		t.contains(xml, "<item>" .. item .. "</item>")
	end
end)

t.test("proxy 5000 (tv) e 5002 (avswitch) come in protocol.lua", function()
	t.contains(xml, '<proxy proxybindingid="' .. protocol.TV_PROXY .. '"')
	t.contains(xml, '<proxy proxybindingid="' .. protocol.AVSWITCH_PROXY .. '"')
	t.contains(xml, ">tv</proxy>")
	t.contains(xml, ">avswitch</proxy>")
end)

t.test("ogni ingresso HDMI e ogni slot MiniApp mappati nel codice hanno la connessione", function()
	for input in pairs(protocol.HDMI_MAP) do
		t.contains(xml, "<id>" .. input .. "</id>", "HDMI " .. input)
	end
	for slot in pairs(protocol.MINI_APP_MAP) do
		t.truthy(xml:find('<connection proxybindingid="5002">%s*<id>' .. slot .. "</id>"), "MiniApp " .. slot)
	end
end)

t.test("comandi SEND_KEY e LAUNCH_APP con i parametri letti da commands.lua", function()
	t.truthy(xml:find("<name>SEND_KEY</name>.-<name>KeyCode</name>"))
	t.truthy(xml:find("<name>LAUNCH_APP</name>.-<name>AppName</name>"))
	local commands = read("src/tv/commands.lua")
	t.contains(commands, "params.KeyCode")
	t.contains(commands, "params.AppName")
end)

t.test("la guida RTF del driver esiste ed e' un RTF valido", function()
	t.contains(xml, '<documentation file="www/documentation.rtf">')
	local rtf = read("src/www/documentation.rtf")
	t.eq(rtf:sub(1, 5), "{\\rtf")
	-- parentesi graffe bilanciate (fuori dalle sequenze \{ e \})
	local stripped = rtf:gsub("\\[{}]", "")
	local depth = 0
	for c in stripped:gmatch("[{}]") do
		depth = depth + (c == "{" and 1 or -1)
		t.truthy(depth >= 0, "graffe sbilanciate")
	end
	t.eq(depth, 0)
end)

t.test("la guida cita la versione solo tramite il driver, niente numeri di versione fissi", function()
	local rtf = read("src/www/documentation.rtf")
	t.falsy(rtf:find("%(v%d+%)"), "numero di versione fisso nella guida")
end)

t.finish()
