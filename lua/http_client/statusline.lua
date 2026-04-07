-- Statusline integration helper for nvim-http-client.
--
-- Reads the `b:http_client_status` buffer-local variable that display.lua
-- writes on the source .http buffer and returns a polished, glyph-decorated
-- string suitable for lualine (or any other statusline plugin).
--
-- Usage with lualine:
--
--   require("lualine").setup({
--     sections = {
--       lualine_x = {
--         require("http_client.statusline").component,
--       },
--     },
--   })

local M = {}

-- Static values written by display.lua map to fixed glyph-decorated labels.
local STATIC_LABELS = {
    pending   = "⠋ pending",
    error     = "✗ ERROR",
    timeout   = "⏱ TIMEOUT",
    cancelled = "⊘ CANCELLED",
}

local function status_glyph(code)
    if code >= 100 and code < 400 then return "✓" end
    if code >= 400 and code < 500 then return "!" end
    if code >= 500 and code < 600 then return "✗" end
    return "·"
end

-- Returns a polished status string for the given buffer (defaults to current).
-- Examples:
--   "⠋ pending"
--   "✓ 200 342ms"
--   "✓ 200"
--   "! 404 89ms"
--   "✗ 500 1.2s"
--   "✗ ERROR"
--   "⏱ TIMEOUT"
--   "⊘ CANCELLED"
--   ""                (no request has run on this buffer)
function M.status(bufnr)
    bufnr = bufnr or 0
    local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, "http_client_status")
    if not ok or not value or value == "" then return "" end

    local label = STATIC_LABELS[value]
    if label then return label end

    local code_str = value:match("^(%d+)")
    if code_str then
        local code = tonumber(code_str)
        if code then
            return status_glyph(code) .. " " .. value
        end
    end
    return value
end

-- Drop-in lualine component. Lualine sets the current buffer per window
-- during render, so `nvim_get_current_buf()` yields the buffer whose
-- statusline is being drawn. Wrapped in pcall so statusline rendering can
-- never blow up on unexpected errors.
function M.component()
    local ok, result = pcall(M.status, vim.api.nvim_get_current_buf())
    if ok then return result end
    return ""
end

return M
