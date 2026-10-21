-- ============================================================
-- tests/support/harness.lua - mini harness per i test offline (Lua 5.1)
--
-- Uso (ogni file tests/test_*.lua parte dalla radice del repo):
--   local t = require "tests.support.harness"
--   t.test("nome", function() t.eq(a, b) end)
--   t.finish()   -- stampa il riepilogo, exit code != 0 se qualcosa e' fallito
-- ============================================================

-- print originale: alcuni test lo sostituiscono per catturare i log
local print = print

local H = {}

local passed, failed = 0, 0

function H.test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("  PASS " .. name)
	else
		failed = failed + 1
		print("  FAIL " .. name .. " -> " .. tostring(err))
	end
end

function H.eq(actual, expected, msg)
	if actual ~= expected then
		error(string.format("%satteso %s, ottenuto %s", msg and (msg .. ": ") or "",
			tostring(expected), tostring(actual)), 2)
	end
end

function H.truthy(value, msg)
	if not value then error(msg or "atteso valore vero", 2) end
end

function H.falsy(value, msg)
	if value then error(msg or "atteso valore falso", 2) end
end

-- Vero se `text` contiene `part` (ricerca letterale, non pattern).
function H.contains(text, part, msg)
	if not tostring(text):find(part, 1, true) then
		error(string.format("%s'%s' non contiene '%s'", msg and (msg .. ": ") or "", tostring(text), part), 2)
	end
end

-- Uguaglianza profonda di tabelle (liste e mappe di scalari).
local function deep_equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do
		if not deep_equal(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

function H.same(actual, expected, msg)
	if not deep_equal(actual, expected) then
		error((msg and (msg .. ": ") or "") .. "le tabelle differiscono", 2)
	end
end

function H.finish()
	print(string.format("  %d passati, %d falliti", passed, failed))
	if failed > 0 then os.exit(1) end
end

return H
