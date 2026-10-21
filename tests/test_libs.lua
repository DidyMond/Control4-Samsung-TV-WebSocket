-- Test di lib/log.lua, lib/timer.lua, lib/net.lua
local t = require "tests.support.harness"
local fake = require "tests.support.fake_c4"

-- ------------------------------------------------------------
-- log
-- ------------------------------------------------------------
local function make_log(mode, level)
	local env = fake.install()
	local log = require "lib.log"
	log.set_mode(mode)
	log.set_level(level)
	return env, log
end

t.test("log: parse_level dai valori della LIST e da numeri", function()
	local log = require "lib.log"
	local items = { "0 - Alert", "1 - Error", "2 - Warning", "3 - Info", "4 - Trace", "5 - Debug" }
	for i, item in ipairs(items) do t.eq(log.parse_level(item), i - 1, item) end
	t.eq(log.parse_level(4), 4)
	t.eq(log.parse_level(nil), log.INFO)
	t.eq(log.parse_level("boh"), log.INFO)
	t.eq(log.parse_level(99), 5)
	t.eq(log.parse_level(-3), 0)
end)

t.test("log: Off non emette nulla", function()
	local env, log = make_log("Off", 5)
	log.alert("T", "x"); log.debug("T", "y")
	t.eq(#env.printed, 0)
	t.eq(#env.errorlog, 0)
end)

t.test("log: Print / Log / Print and Log scelgono il sink", function()
	local env, log = make_log("Print", 3)
	log.info("T", "uno")
	t.eq(#env.printed, 1); t.eq(#env.errorlog, 0)

	env, log = make_log("Log", 3)
	log.info("T", "uno")
	t.eq(#env.printed, 0); t.eq(#env.errorlog, 1)

	env, log = make_log("Print and Log", 3)
	log.info("T", "uno")
	t.eq(#env.printed, 1); t.eq(#env.errorlog, 1)
end)

t.test("log: valore di Log Mode sconosciuto = Off", function()
	local env, log = make_log("Boh", 5)
	log.info("T", "x")
	t.eq(#env.printed, 0)
end)

t.test("log: il livello filtra (S <= livello)", function()
	local env, log = make_log("Print", 3)
	log.alert("T", "a"); log.error("T", "e"); log.warn("T", "w"); log.info("T", "i")
	log.trace("T", "t"); log.debug("T", "d")
	t.eq(#env.printed, 4)

	env, log = make_log("Print", 0)
	log.alert("T", "a"); log.error("T", "e")
	t.eq(#env.printed, 1)

	env, log = make_log("Print", 5)
	log.debug("T", "d")
	t.eq(#env.printed, 1)
end)

t.test("log: la riga ha ora, tag e messaggio", function()
	local env, log = make_log("Print", 3)
	log.info("REST", "state -> ON")
	t.truthy(env.printed[1]:match("^%d%d:%d%d:%d%d %[REST%] state %-> ON$"), env.printed[1])
end)

t.test("log: il token viene oscurato in ogni sink", function()
	local env, log = make_log("Print and Log", 5)
	log.info("WS", "connecting to wss://h:8002/x?name=a&token=99887766")
	t.falsy(env.printed[1]:find("99887766", 1, true))
	t.falsy(env.errorlog[1]:find("99887766", 1, true))
end)

t.test("log: unhandled e' visibile anche con Log Mode = Off", function()
	local env, log = make_log("Off", 3)
	log.unhandled("DRIVER", "boom")
	t.eq(#env.printed, 1)
	t.contains(env.printed[1], "[DRIVER] boom")

	env, log = make_log("Log", 3)
	log.unhandled("DRIVER", "boom")
	t.eq(#env.errorlog, 1)
end)

-- ------------------------------------------------------------
-- timer
-- ------------------------------------------------------------
t.test("timer: after scatta una volta", function()
	local env = fake.install()
	local timer = require "lib.timer"
	local n = 0
	timer.after(100, function() n = n + 1 end)
	env.advance(99); t.eq(n, 0)
	env.advance(1); t.eq(n, 1)
	env.advance(1000); t.eq(n, 1)
	t.eq(env.pending_timers(), 0)
end)

t.test("timer: every si ripete fino a cancel", function()
	local env = fake.install()
	local timer = require "lib.timer"
	local n = 0
	local handle = timer.every(100, function() n = n + 1 end)
	env.advance(350); t.eq(n, 3)
	handle:cancel()
	env.advance(1000); t.eq(n, 3)
	t.eq(env.pending_timers(), 0)
end)

t.test("timer: cancel prima dello scatto, e cancel doppio, sono sicuri", function()
	local env = fake.install()
	local timer = require "lib.timer"
	local n = 0
	local handle = timer.after(100, function() n = n + 1 end)
	handle:cancel()
	handle:cancel()
	env.advance(500)
	t.eq(n, 0)
end)

t.test("timer: una callback puo' cancellare il proprio timer ripetuto", function()
	local env = fake.install()
	local timer = require "lib.timer"
	local n = 0
	timer.every(100, function(handle)
		n = n + 1
		if n == 2 then handle:cancel() end
	end)
	env.advance(1000)
	t.eq(n, 2)
	t.eq(env.pending_timers(), 0)
end)

t.test("timer: fire con id sconosciuto restituisce false", function()
	fake.install()
	t.falsy(require("lib.timer").fire(12345))
end)

-- ------------------------------------------------------------
-- net
-- ------------------------------------------------------------
t.test("net: dispatch per binding, unregister, binding sconosciuti", function()
	fake.install()
	local net = require "lib.net"
	local seen = {}
	net.register(6099,
		function(b, p, s) seen[#seen + 1] = "status:" .. b .. ":" .. s end,
		function(b, p, d) seen[#seen + 1] = "data:" .. b .. ":" .. d end)
	t.truthy(net.dispatch_status(6099, 8001, "ONLINE"))
	t.truthy(net.dispatch_data(6099, 8001, "abc"))
	t.falsy(net.dispatch_status(7777, 0, "ONLINE"))
	t.same(seen, { "status:6099:ONLINE", "data:6099:abc" })
	net.unregister(6099)
	t.falsy(net.dispatch_data(6099, 8001, "abc"))
	t.falsy(net.is_registered(6099))
end)

t.finish()
