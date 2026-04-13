local M = {}

-- Compatibility shim: vim.uv exists in Neovim 0.10+; fall back to vim.loop.
local uv = vim.uv or vim.loop

local format = require('http_client.utils.format')

local response_win = nil
local buffers = {}
local MAX_BUFFERS = 10

-- bufnr -> request while a response is in-flight. Used by ring eviction,
-- VimLeavePre cleanup, and is_pending().
local active_requests_by_bufnr = {}

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_INTERVAL_MS = 80
local STATUS_LINE_IDX = 3

-- Monotonic counter so buffers created within the same HH:MM:SS second get
-- unique names (avoids E95 on nvim_buf_set_name).
local name_counter = 0

-- Pretty-prints JSON. Returns the original string on parse failure.
local function prettify_json(json_str)
    local ok, parsed = pcall(vim.json.decode, json_str)
    if not ok then return json_str end

    local function encode_pretty(val, indent)
        indent = indent or ""
        local next_indent = indent .. "  "
        if type(val) == "table" then
            local items = {}
            if vim.islist(val) then
                for _, v in ipairs(val) do
                    table.insert(items, encode_pretty(v, next_indent))
                end
                return "[\n" .. next_indent .. table.concat(items, ",\n" .. next_indent) .. "\n" .. indent .. "]"
            else
                for k, v in pairs(val) do
                    table.insert(items, string.format('%q: %s', k, encode_pretty(v, next_indent)))
                end
                return "{\n" .. next_indent .. table.concat(items, ",\n" .. next_indent) .. "\n" .. indent .. "}"
            end
        elseif val == vim.NIL then
            return "null"
        elseif type(val) == "string" then
            return string.format('%q', val)
        elseif type(val) == "boolean" then
            return tostring(val)
        else
            return tostring(val)
        end
    end
    return encode_pretty(parsed)
end

local function format_xml(body)
    local indent = 0
    return (body:gsub("(<[^/!][^>]*>)", function(tag)
        local result = string.rep("  ", indent) .. tag
        if not tag:match("/>$") and not tag:match("</") then
            indent = indent + 1
        elseif tag:match("</") then
            indent = indent - 1
            result = string.rep("  ", indent) .. tag
        end
        return result
    end))
end

local function get_timestamp()
    return os.date("%H:%M:%S")
end

local function unique_buffer_name(prefix)
    name_counter = name_counter + 1
    return string.format("[%s] %s #%d", get_timestamp(), prefix, name_counter)
end

local function hrtime()
    return uv.hrtime()
end

local function elapsed_seconds_str(started_at)
    if not started_at then return "0.0" end
    return string.format("%.1f", (hrtime() - started_at) / 1e9)
end

local function request_summary(request)
    return request.test_name or "(unnamed)",
        request.method or "?",
        request.url or ""
end

local function set_buf_var_safe(bufnr, name, value)
    if bufnr == nil then return end
    pcall(vim.api.nvim_buf_set_var, bufnr, name, value)
end

local function buf_owns_request(bufnr, request_id)
    if not vim.api.nvim_buf_is_valid(bufnr) then return false end
    local ok, owner = pcall(vim.api.nvim_buf_get_var, bufnr, "http_client_request_id")
    return ok and owner == request_id
end

local function with_modifiable(bufnr, fn)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.bo[bufnr].modifiable = true
    local ok, err = pcall(fn)
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.bo[bufnr].modifiable = false
    end
    if not ok then error(err) end
end

local function stop_spinner(ui)
    if ui and ui.spinner_timer then
        local t = ui.spinner_timer
        if not t:is_closing() then
            t:stop()
            t:close()
        end
        ui.spinner_timer = nil
    end
end

local function navigate_buffers(direction)
    if not response_win or not vim.api.nvim_win_is_valid(response_win) then
        return
    end

    local current_buf = vim.api.nvim_win_get_buf(response_win)
    local current_idx = nil

    -- Find current buffer index
    for i, buf in ipairs(buffers) do
        if buf == current_buf then
            current_idx = i
            break
        end
    end

    if not current_idx then return end

    -- Calculate next buffer index
    local next_idx
    if direction == 'next' then
        next_idx = current_idx == 1 and #buffers or current_idx - 1
    else
        next_idx = current_idx == #buffers and 1 or current_idx + 1
    end

    -- Set the buffer in our response window
    if buffers[next_idx] and vim.api.nvim_buf_is_valid(buffers[next_idx]) then
        vim.api.nvim_win_set_buf(response_win, buffers[next_idx])
    end
end

local function evict_old_buffers()
    -- Remove the first non-pending buffer from the end of the list. If every
    -- buffer is pending we let the list grow until something completes.
    while #buffers > MAX_BUFFERS do
        local removed_idx
        for i = #buffers, 1, -1 do
            if not active_requests_by_bufnr[buffers[i]] then
                removed_idx = i
                break
            end
        end
        if not removed_idx then return end
        local old_buf = table.remove(buffers, removed_idx)
        if vim.api.nvim_buf_is_valid(old_buf) then
            pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
        end
    end
end

local function create_response_buffer()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].filetype = 'http_response'

    -- q / <Esc> use :bdelete (not :close) so BufWipeout fires and spinner cleanup runs.
    vim.api.nvim_buf_set_keymap(buf, 'n', 'q', ':bdelete<CR>', { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', ':bdelete<CR>', { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(buf, 'n', 'x', ':HttpStop<CR>', { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(buf, 'n', 'H', '', {
        noremap = true, silent = true,
        callback = function() navigate_buffers('prev') end,
    })
    vim.api.nvim_buf_set_keymap(buf, 'n', 'L', '', {
        noremap = true, silent = true,
        callback = function() navigate_buffers('next') end,
    })
    vim.api.nvim_buf_set_keymap(buf, 'n', 'r', '', {
        noremap = true, silent = true,
        callback = function()
            local ok, saved = pcall(vim.api.nvim_buf_get_var, buf, 'http_client_request')
            if not ok or not saved then
                vim.notify("[http_client] No request to retry on this buffer", vim.log.levels.WARN)
                return
            end
            require('http_client.core.http_client').send_request(vim.deepcopy(saved))
        end,
    })

    table.insert(buffers, 1, buf)
    evict_old_buffers()

    return buf
end

local function get_response_win()
    if response_win and vim.api.nvim_win_is_valid(response_win) then
        return response_win
    end
    for _, buf in pairs(buffers) do
        if vim.api.nvim_buf_is_valid(buf) then
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_buf(win) == buf then
                    response_win = win
                    return win
                end
            end
        end
    end
end

local SPLIT_CMDS = {
    right = 'vsplit',
    left  = 'leftabove vsplit',
    below = 'split',
    above = 'leftabove split',
}

local function create_response_win()
    local split_direction = require('http_client.config').get('split_direction')
    local split_cmd = SPLIT_CMDS[split_direction] or 'vsplit'

    -- Open the split, capture the new window, then restore focus to the source.
    local current_win = vim.api.nvim_get_current_win()
    vim.cmd(split_cmd)
    response_win = vim.api.nvim_get_current_win()
    vim.wo[response_win].wrap = true
    vim.api.nvim_set_current_win(current_win)

    return response_win
end

local function clear_pending(bufnr)
    if bufnr then active_requests_by_bufnr[bufnr] = nil end
end

local function build_spinner_line(request, frame)
    local elapsed_ms = (hrtime() - request.ui.started_at) / 1e6
    local method = request.method or "?"
    local url = request.url or ""
    if elapsed_ms < 500 then
        return string.format("%s Sending %s %s", frame, method, url)
    end
    local elapsed_s = string.format("%.1f", elapsed_ms / 1000)
    if elapsed_ms < 3000 then
        return string.format("%s Sending %s %s   %ss", frame, method, url, elapsed_s)
    elseif elapsed_ms < 10000 then
        return string.format("%s Still sending %s %s   %ss", frame, method, url, elapsed_s)
    else
        return string.format("%s Still waiting on %s %s   %ss", frame, method, url, elapsed_s)
    end
end

local function spinner_tick(request)
    local ui = request.ui
    local bufnr = ui and ui.bufnr
    if not bufnr
        or not vim.api.nvim_buf_is_valid(bufnr)
        or not buf_owns_request(bufnr, request.request_id)
    then
        stop_spinner(ui)
        return
    end

    local frame = SPINNER_FRAMES[ui.spinner_idx]
    local line = build_spinner_line(request, frame)

    local ok = pcall(with_modifiable, bufnr, function()
        vim.api.nvim_buf_set_lines(bufnr, STATUS_LINE_IDX, STATUS_LINE_IDX + 1, false, { line })
    end)
    if not ok then
        stop_spinner(ui)
        return
    end

    ui.spinner_idx = (ui.spinner_idx % #SPINNER_FRAMES) + 1
end

local function start_spinner(request)
    local timer = uv.new_timer()
    request.ui.spinner_timer = timer
    timer:start(SPINNER_INTERVAL_MS, SPINNER_INTERVAL_MS, vim.schedule_wrap(function()
        spinner_tick(request)
    end))
end

local function pending_lines(request)
    local test_name, method, url = request_summary(request)
    return {
        "HTTP Request — " .. test_name,
        "─────────────────────────",
        "",
        string.format("%s Sending %s %s", SPINNER_FRAMES[1], method, url), -- STATUS_LINE_IDX
        "",
        "started " .. get_timestamp(),
        "",
        "Press q to close, x to cancel, r to retry",
    }
end

function M.setup()
    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            for _, request in pairs(active_requests_by_bufnr) do
                stop_spinner(request.ui)
            end
        end,
    })
end

function M.is_pending(bufnr)
    return active_requests_by_bufnr[bufnr] ~= nil
end

function M.show_pending(request)
    local source_bufnr = vim.api.nvim_get_current_buf()
    local buf = create_response_buffer()

    -- Snapshot the request BEFORE request.ui is attached below. request.ui
    -- contains a uv timer handle that vim.deepcopy can't copy. Strip any
    -- lingering ui field just in case (e.g. if a caller reused a request).
    local shallow_no_ui = {}
    for k, v in pairs(request) do
        if k ~= "ui" then shallow_no_ui[k] = v end
    end
    local saved_request = vim.deepcopy(shallow_no_ui)
    pcall(vim.api.nvim_buf_set_var, buf, 'http_client_request', saved_request)

    with_modifiable(buf, function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, pending_lines(request))
    end)

    pcall(vim.api.nvim_buf_set_name, buf, unique_buffer_name("HTTP Request (pending)"))

    set_buf_var_safe(buf, "http_client_request_id", request.request_id)
    set_buf_var_safe(source_bufnr, "http_client_status", "pending")

    active_requests_by_bufnr[buf] = request

    request.ui = {
        bufnr           = buf,
        source_bufnr    = source_bufnr,
        spinner_timer   = nil,
        spinner_idx     = 1,
        started_at      = hrtime(),
        status_line_idx = STATUS_LINE_IDX,
    }

    -- Closing the buffer is a UI gesture, not "abandon work" — we stop the
    -- spinner but leave the curl job running; the finalizer falls back to
    -- vim.notify when it can't find a buffer to write into.
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            stop_spinner(request.ui)
            active_requests_by_bufnr[buf] = nil
        end,
    })

    local win = get_response_win() or create_response_win()
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_set_buf, win, buf)
    end

    start_spinner(request)
end

local function build_response_content(pr)
    local profiling = require('http_client.utils.profiling')
    local config = require('http_client.config')

    -- Format timing metrics if available
    local timing_str = ""
    local profiling_config = config.get('profiling')

    if profiling_config and profiling_config.enabled and profiling_config.show_in_response then
        if pr.timing_metrics and next(pr.timing_metrics) then
            timing_str = "\n# Timing:\n" .. profiling.format_metrics(pr.timing_metrics)
        end
    end

    local formatted_body = pr.formatted_body
    if pr.content_type == "json" then
        formatted_body = prettify_json(pr.formatted_body)
    elseif pr.content_type == "xml" then
        formatted_body = format_xml(pr.formatted_body)
    end

    return string.format([[
Response Information (%s):
---------------------
%s %s %s
# Status: %s

# Headers:
%s%s

# Body (%s):
%s
]],
        pr.request.test_name,
        pr.request.method,
        pr.request.url,
        pr.request.http_version,
        pr.status,
        format.headers(pr.headers),
        timing_str,
        pr.content_type,
        formatted_body
    )
end

local function build_status_summary(pr)
    local config = require('http_client.config')
    local profiling_config = config.get('profiling')
    local status = tostring(pr.status or "?")
    if profiling_config and profiling_config.enabled
        and pr.timing_metrics and pr.timing_metrics.total
        and pr.timing_metrics.total.duration then
        return string.format("%s %dms", status, math.floor(pr.timing_metrics.total.duration + 0.5))
    end
    return status
end

local function build_error_content(request, glyph_label, body)
    local test_name, method, url = request_summary(request)
    return string.format(
        "HTTP Request — %s\n─────────────────────────\n\n%s\n%s %s\n\n%s",
        test_name, glyph_label, method, url, body)
end

-- Per-kind data driving show_error: how to render the body, the short label
-- baked into the buffer name, and the lualine status string.
local KINDS = {
    transport = {
        label = "ERROR",
        status = "error",
        build = function(request, err)
            local glyph_label = string.format("✗ ERROR (curl exit %s)", tostring(err.exit or "?"))
            local body = string.format(
                "Stderr:\n%s\n\nPress q to close, r to retry, H/L to navigate history.\n",
                err.stderr or "")
            return build_error_content(request, glyph_label, body)
        end,
    },
    timeout = {
        label = "TIMEOUT",
        status = "timeout",
        build = function(request, _err)
            local elapsed_s = elapsed_seconds_str(request.ui and request.ui.started_at)
            local timeout_ms = require('http_client.config').get('request_timeout')
            local glyph_label = string.format("⏱ TIMEOUT after %ss", elapsed_s)
            local body = string.format([[
Configured limit: request_timeout = %dms

The server did not respond within the timeout. This usually means:
  • the host is unreachable or slow
  • a firewall is dropping packets silently
  • the endpoint is doing long work (try increasing request_timeout)

Press q to close, r to retry.
]], timeout_ms)
            return build_error_content(request, glyph_label, body)
        end,
    },
    cancelled = {
        label = "CANCELLED",
        status = "cancelled",
        build = function(request, _err)
            local elapsed_s = elapsed_seconds_str(request.ui and request.ui.started_at)
            local body = string.format("Cancelled after %ss by user.\n\nPress q to close, r to retry.\n", elapsed_s)
            return build_error_content(request, "⊘ CANCELLED", body)
        end,
    },
}

-- Render `content` into the request's pending buffer and clean up the in-flight
-- tracking. Falls back to vim.notify if the buffer is gone or has been reused
-- by a newer request. `notify_msg` is shown in those fallback paths.
local function render_into_pending(ui, request_id, content, label, status_str, notify_msg)
    if not ui or not ui.bufnr then
        vim.notify(notify_msg .. " (no pending buffer). Open with :HttpResponseTab", vim.log.levels.INFO)
        return
    end

    local bufnr = ui.bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then
        vim.notify(notify_msg .. " (buffer was closed). Open with :HttpResponseTab", vim.log.levels.INFO)
        clear_pending(bufnr)
        return
    end
    if not buf_owns_request(bufnr, request_id) then
        vim.notify(notify_msg .. " (buffer was reused). Open with :HttpResponseTab", vim.log.levels.INFO)
        clear_pending(bufnr)
        return
    end

    clear_pending(bufnr)

    with_modifiable(bufnr, function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content, '\n'))
    end)

    pcall(vim.api.nvim_buf_set_name, bufnr, unique_buffer_name("HTTP " .. label))

    if ui.source_bufnr and vim.api.nvim_buf_is_valid(ui.source_bufnr) then
        set_buf_var_safe(ui.source_bufnr, "http_client_status", status_str)
    end

    local win = get_response_win() or create_response_win()
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_set_buf, win, bufnr)
    end
end

function M.show_response(pr)
    stop_spinner(pr.ui)
    render_into_pending(
        pr.ui,
        pr.request_id,
        build_response_content(pr),
        tostring(pr.status or "?"),
        build_status_summary(pr),
        "HTTP Response ready"
    )
end

function M.show_error(request, err)
    stop_spinner(request.ui)

    err = err or {}
    local kind = KINDS[err.kind] and err.kind or "transport"
    local k = KINDS[kind]

    render_into_pending(
        request.ui,
        request.request_id,
        k.build(request, err),
        k.label,
        k.status,
        string.format("HTTP %s: %s", kind, err.message or "")
    )
end

function M.show_cancelled(request)
    M.show_error(request, { kind = "cancelled", message = "Cancelled by user" })
end

function M.display_in_buffer(content, title)
    vim.schedule(function()
        local buf = create_response_buffer()
        local win = get_response_win() or create_response_win()

        pcall(vim.api.nvim_buf_set_name, buf, unique_buffer_name(title))

        with_modifiable(buf, function()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n'))
        end)

        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_buf(win, buf)
        end
    end)
end

function M.open_latest_response_in_tab()
    if #buffers == 0 then
        vim.notify("No response buffer available", vim.log.levels.WARN)
        return
    end
    local buf = buffers[1]
    if vim.api.nvim_buf_is_valid(buf) then
        vim.cmd('tabnew')
        vim.api.nvim_win_set_buf(0, buf)
    else
        vim.notify("Latest response buffer is not valid", vim.log.levels.WARN)
    end
end

-- Test seam: file-local helper exposed so the collision-uniqueness test can
-- call it without going through display_in_buffer's vim.schedule path.
M._unique_buffer_name = unique_buffer_name

return M
