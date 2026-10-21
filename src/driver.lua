-- ============================================================
-- driver.lua - ENTRY POINT
-- Samsung TV (WebSocket) - driver DriverWorks per Control4
--
-- Solo handler Director e wiring: la logica sta in lib/ e tv/.
-- ============================================================

local log = require "lib.log"
local timer = require "lib.timer"
local net = require "lib.net"
local tv = require "tv.samsung_tv"
local Commands = require "tv.commands"

local commands = Commands.new(tv)

local TAG = "DRIVER"

-- ------------------------------------------------------------
-- Esegue fn in pcall e logga l'errore invece di lasciarlo salire a
-- Director, che interromperebbe in silenzio quella catena di esecuzione.
-- Se la callback interrotta era quella che doveva riarmare il prossimo
-- timer (es. il polling REST dello stato), il polling si fermerebbe fino
-- al reload del driver o al riavvio di Control4.
-- ------------------------------------------------------------
local function safe(context, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		log.unhandled(TAG, "unhandled error in " .. context .. " -> " .. tostring(err))
	end
	return ok
end

local function apply_log_properties()
	log.set_level(Properties["Log Level"])
	log.set_mode(Properties["Log Mode"])
end

-- ------------------------------------------------------------
-- Callback standard DriverWorks
-- ------------------------------------------------------------
function OnDriverInit()
	safe("OnDriverInit", function()
		apply_log_properties()
		log.info("LIFECYCLE", "OnDriverInit")
		tv.refresh_pairing_status()
	end)
end

function OnDriverLateInit()
	safe("OnDriverLateInit", function()
		log.info("LIFECYCLE", "OnDriverLateInit")
		if not tv.is_paired() then
			log.info("PAIR", "not paired: set Pairing to 'Pair with TV'")
		end
		tv.start()
	end)
end

function OnDriverDestroyed()
	safe("OnDriverDestroyed", function()
		commands.stop_repeat()
		tv.shutdown()
	end)
end

function OnTimerExpired(idTimer)
	safe("OnTimerExpired(idTimer=" .. tostring(idTimer) .. ")", timer.fire, idTimer)
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	safe("OnConnectionStatusChanged(idBinding=" .. tostring(idBinding) .. ", status=" ..
		tostring(strStatus) .. ")", net.dispatch_status, idBinding, nPort, strStatus)
end

function ReceivedFromNetwork(idBinding, nPort, strData)
	safe("ReceivedFromNetwork(idBinding=" .. tostring(idBinding) .. ", bytes=" ..
		tostring(string.len(strData or "")) .. ")", net.dispatch_data, idBinding, nPort, strData or "")
end

function OnPropertyChanged(strProperty)
	safe("OnPropertyChanged(property=" .. tostring(strProperty) .. ")", function()
		local value = Properties[strProperty]
		log.debug("LIFECYCLE", "property changed -> " .. strProperty)

		if strProperty == "Log Level" or strProperty == "Log Mode" then
			apply_log_properties()
			log.info("LIFECYCLE", strProperty .. " -> " .. tostring(value))

		elseif strProperty == "Pairing" then
			if value == "Pair with TV" then
				tv.pair()
			elseif value == "Unpair" then
				tv.unpair()
			end
			if value ~= "Select..." then
				C4:UpdateProperty("Pairing", "Select...")
			end

		elseif strProperty == "IP Address" then
			-- il token vale solo per la TV con cui si e' fatto il pairing
			log.info("PAIR", "IP address changed: token invalidated")
			tv.unpair()
			tv.reset_power()
			tv.check_reachability()

		elseif strProperty == "Port" or strProperty == "Device Name" then
			tv.reconnect()
		end
	end)
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
	safe("ReceivedFromProxy(idBinding=" .. tostring(idBinding) .. ", command=" ..
		tostring(strCommand) .. ")", commands.handle_proxy, idBinding, strCommand, tParams)
end

function ExecuteCommand(strCommand, tParams)
	safe("ExecuteCommand(command=" .. tostring(strCommand) .. ")", commands.execute, strCommand, tParams)
end
