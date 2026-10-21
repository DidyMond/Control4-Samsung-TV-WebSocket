-- ============================================================
-- lib/net.lua - dispatch degli eventi di rete per binding
--
-- Director consegna OnConnectionStatusChanged e ReceivedFromNetwork con
-- l'id del binding: qui ogni binding dinamico (REST, app, WebSocket)
-- registra le proprie callback, e driver.lua le smista da un solo punto.
-- Lua 5.1 puro, nessun riferimento a C4.
-- ============================================================

local M = {}

local handlers = {}

-- on_status(idBinding, nPort, strStatus), on_data(idBinding, nPort, strData)
function M.register(binding, on_status, on_data)
	handlers[binding] = { status = on_status, data = on_data }
end

function M.unregister(binding)
	handlers[binding] = nil
end

function M.is_registered(binding)
	return handlers[binding] ~= nil
end

-- Restituisce true se il binding aveva un handler (anche se lo status e' ignorato).
function M.dispatch_status(binding, port, status)
	local h = handlers[binding]
	if h and h.status then
		h.status(binding, port, status)
		return true
	end
	return false
end

function M.dispatch_data(binding, port, data)
	local h = handlers[binding]
	if h and h.data then
		h.data(binding, port, data)
		return true
	end
	return false
end

return M
