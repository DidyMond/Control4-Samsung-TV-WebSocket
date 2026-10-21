-- Test di lib/util.lua
local t = require "tests.support.harness"
local util = require "lib.util"

t.test("redact: token nell'URL del WebSocket", function()
	local out = util.redact("connecting to wss://192.168.1.50:8002/api/v2/channels/samsung.remote.control?name=QzQ=&token=24681357")
	t.falsy(out:find("24681357", 1, true))
	t.contains(out, "token=***")
	t.contains(out, "name=QzQ=")
end)

t.test("redact: token in JSON fra virgolette", function()
	local out = util.redact('{"data":{"token":"24681357"},"event":"ms.channel.connect"}')
	t.falsy(out:find("24681357", 1, true))
	t.contains(out, '"token":"***"')
end)

t.test("redact: token in JSON senza virgolette", function()
	local out = util.redact('{"data":{"clients":[{"token": 24681357}]}}')
	t.falsy(out:find("24681357", 1, true))
end)

t.test("redact: testo senza token resta identico", function()
	t.eq(util.redact("REST check -> ON (PowerState On)"), "REST check -> ON (PowerState On)")
end)

t.test("redact: accetta valori non stringa", function()
	t.eq(util.redact(42), "42")
end)

t.test("is_blank", function()
	t.truthy(util.is_blank(nil))
	t.truthy(util.is_blank(""))
	t.truthy(util.is_blank("   "))
	t.falsy(util.is_blank("192.168.1.50"))
end)

t.finish()
