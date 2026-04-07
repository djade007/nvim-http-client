local M = {}

-- Format HTTP headers as a "Key: Value\nKey: Value" string. Accepts either:
--   - an array of pre-formatted "Key: Value" strings (from plenary curl response.headers)
--   - a key-value table (from the parser)
function M.headers(headers)
    local formatted = {}
    for k, v in pairs(headers or {}) do
        if type(k) == "number" and type(v) == "string" then
            local key, value = v:match("^(.-):%s*(.*)")
            if key and value then
                table.insert(formatted, string.format("%s: %s", key, value))
            end
        elseif type(k) == "string" then
            table.insert(formatted, string.format("%s: %s", k, v))
        end
    end
    return table.concat(formatted, "\n")
end

return M
