-- ============================================================
-- tv/commands.lua - comandi da Director/Composer -> azioni sulla TV
--
--   ReceivedFromProxy(binding, command, params)  -> handle_proxy
--   ExecuteCommand(command, params)              -> execute
--
-- Riceve la TV (`tv`) per iniezione: send_key, launch_app,
-- launch_app_when_on, power. Cosi' si prova senza rete.
-- ============================================================

local log = require "lib.log"
local timer = require "lib.timer"
local protocol = require "tv.protocol"

local M = {}

-- Director manda SET_INPUT due volte per un lancio app (audio + video):
-- lo stesso lancio entro 3 s e' un doppione.
local APP_DEBOUNCE_S = 3

-- Rete di sicurezza: se il STOP_* di una pressione prolungata non arriva
-- (pannello che perde la connessione), il volume non deve salire per sempre.
local REPEAT_MAX_S = 20

function M.new(tv, now)
	now = now or os.time

	local self = {}
	local repeat_timer = nil
	local last_app, last_app_at = "", 0

	local function stop_repeat()
		if repeat_timer then
			repeat_timer:cancel()
			repeat_timer = nil
		end
	end

	local function start_repeat(spec)
		stop_repeat()
		tv.send_key(spec.key)
		local started = now()
		repeat_timer = timer.every(spec.interval_ms, function()
			if now() - started > REPEAT_MAX_S then
				log.warn("CMD", "key repeat stopped after " .. REPEAT_MAX_S .. " s without STOP")
				stop_repeat()
			else
				tv.send_key(spec.key)
			end
		end)
	end

	function self.stop_repeat()
		stop_repeat()
	end

	function self.handle_proxy(binding, command, params)
		params = params or {}

		if protocol.is_housekeeping(binding, command) then
			log.trace("CMD", "housekeeping -> " .. tostring(command) .. " (binding " .. tostring(binding) .. ")")
			return
		end

		log.info("CMD", "proxy command -> " .. tostring(command) .. " (binding " .. tostring(binding) .. ")")

		-- Tastierino a schermo del Navigator con un'app aperta
		if command == "PASSTHROUGH" and params.PASSTHROUGH_COMMAND then
			local key = protocol.PASSTHROUGH_MAP[params.PASSTHROUGH_COMMAND]
			if key then
				tv.send_key(key)
			else
				log.debug("CMD", "PASSTHROUGH not handled -> " .. tostring(params.PASSTHROUGH_COMMAND))
			end
			return
		end

		-- Tile MiniApp della Watch experience: SET_INPUT sulla proxy avswitch
		if binding == protocol.AVSWITCH_PROXY and command == "SET_INPUT" and params.INPUT then
			local appName = protocol.MINI_APP_MAP[tostring(params.INPUT)]
			if appName then
				local t = now()
				if appName == last_app and (t - last_app_at) < APP_DEBOUNCE_S then
					log.info("APP", "launch of '" .. appName .. "' ignored (duplicate Director command)")
				else
					last_app, last_app_at = appName, t
					log.info("APP", "MiniApp tile -> " .. appName)
					tv.launch_app_when_on(appName)
				end
			end
			return
		end

		-- ON/OFF solo dalla proxy TV: quelli della avswitch sono routing e
		-- non devono diventare KEY_POWER (spegnevano la TV alla pressione di una tile).
		-- Il tasto e' un toggle: si manda solo se lo stato reale e' diverso.
		if binding == protocol.TV_PROXY and (command == "ON" or command == "OFF") then
			if tv.power() == command then
				log.debug("CMD", command .. " ignored (TV already " .. command .. ")")
			else
				tv.send_key("KEY_POWER")
			end
			return
		end

		-- Selezione sorgente sulla proxy TV: 1001-1003 = HDMI fisici; altri
		-- valori (es. 1102) sono routing interno dell'app switcher.
		if binding == protocol.TV_PROXY and command == "SET_INPUT" and params.INPUT then
			local key = protocol.HDMI_MAP[tostring(params.INPUT)]
			if key then
				tv.send_key(key)
			else
				log.debug("CMD", "SET_INPUT ignored (INPUT=" .. tostring(params.INPUT) .. ")")
			end
			return
		end

		-- Pressione prolungata di volume e canali
		local spec = protocol.REPEAT_MAP[command]
		if spec then
			start_repeat(spec)
			return
		end
		if protocol.STOP_REPEAT[command] then
			stop_repeat()
			return
		end

		local key = protocol.KEY_MAP[command]
		if key then
			tv.send_key(key)
		else
			log.debug("CMD", "unmapped command (not sent) -> " .. tostring(command))
		end
	end

	-- Comandi di Composer Programming (driver.xml <commands>)
	function self.execute(command, params)
		params = params or {}
		log.info("CMD", "ExecuteCommand -> " .. tostring(command))
		if command == "SEND_KEY" then
			if params.KeyCode then
				tv.send_key(params.KeyCode)
			else
				log.warn("CMD", "SEND_KEY called without KeyCode")
			end
		elseif command == "LAUNCH_APP" then
			if params.AppName then
				tv.launch_app(params.AppName)
			else
				log.warn("CMD", "LAUNCH_APP called without AppName")
			end
		else
			log.debug("CMD", "unhandled command -> " .. tostring(command))
		end
	end

	return self
end

return M
