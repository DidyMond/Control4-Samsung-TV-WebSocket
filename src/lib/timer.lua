-- ============================================================
-- lib/timer.lua - timer DriverWorks con callback e cancellazione
--
-- DriverWorks non ha sleep: ogni attesa e' un timer C4:AddTimer, che
-- Director chiude con OnTimerExpired(idTimer). Qui ogni timer ha una
-- callback; driver.lua inoltra OnTimerExpired a Timer.fire().
--
--   local t = Timer.after(2000, fn)   -- una volta
--   local t = Timer.every(300, fn)    -- ripetuto fino a t:cancel()
--   t:cancel()                        -- sicuro anche se gia' scattato
-- ============================================================

local M = {}

local registry = {}

local function arm(handle, ms, callback, repeating)
	handle.id = C4:AddTimer(ms, "MILLISECONDS")
	registry[handle.id] = function()
		-- il timer e' gia' stato tolto dal registro da fire(): se la callback
		-- chiama handle:cancel() non c'e' nulla da fermare ne' da riarmare
		handle.id = nil
		callback(handle)
		if repeating and not handle.cancelled then
			arm(handle, ms, callback, repeating)
		end
	end
end

local function new_timer(ms, callback, repeating)
	local handle = { cancelled = false }
	function handle:cancel()
		self.cancelled = true
		if self.id then
			registry[self.id] = nil
			C4:KillTimer(self.id)
			self.id = nil
		end
	end
	arm(handle, ms, callback, repeating)
	return handle
end

function M.after(ms, callback)
	return new_timer(ms, callback, false)
end

function M.every(ms, callback)
	return new_timer(ms, callback, true)
end

-- Da chiamare da OnTimerExpired. Restituisce true se l'id era nostro.
function M.fire(idTimer)
	local fn = registry[idTimer]
	if not fn then return false end
	registry[idTimer] = nil
	fn()
	return true
end

return M
