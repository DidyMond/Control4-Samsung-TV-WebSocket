-- ============================================================
-- lib/util.lua - utility pure (Lua 5.1, nessun riferimento a C4)
-- ============================================================

local M = {}

-- Nasconde il token di abbinamento della TV in un testo da loggare: sta
-- nell'URL del WebSocket (`?...&token=12345678`) e nei messaggi JSON
-- `ms.channel.connect` (`"token":"12345678"` oppure `"token":12345678`).
-- I log finiscono nelle issue pubbliche: il token non deve mai uscirne.
function M.redact(text)
	text = tostring(text)
	text = text:gsub("([?&]token=)[^&%s\"']+", "%1***")
	text = text:gsub('("token"%s*:%s*)"[^"]*"', '%1"***"')
	text = text:gsub('("token"%s*:%s*)%d+', '%1"***"')
	return text
end

-- Vero se `value` e' una stringa non vuota (dopo il trim).
function M.is_blank(value)
	return type(value) ~= "string" or value:match("^%s*$") ~= nil
end

return M
