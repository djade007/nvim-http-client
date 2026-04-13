local M = {}

local vvv = require('http_client.utils.verbose')
local parser = require('http_client.core.parser')
local environment = require('http_client.core.environment')
local http_client = require('http_client.core.http_client')
local select_env = require('http_client.commands.select_env')
local config = require('http_client.config')

--- Prompt for env file or env selection, then call on_done.
local function prompt_for_env(bufnr, on_done)
    if not environment.get_current_env_file(bufnr) then
        select_env.select_env_file(config.options, bufnr, on_done)
    else
        select_env.select_env(bufnr, on_done)
    end
end

M.run_request = function()
    local verbose = vvv.get_verbose_mode()

    local request = parser.get_request_under_cursor()
    if not request then
        print('\nNo valid HTTP request found under cursor')
        return
    end

    if verbose then
        print("Parsed request:", vim.inspect(request)) -- Debug output
    end

    local env = environment.get_current_env()
    local env_needed = environment.env_variables_needed(request)

    if env_needed and not next(env) then
        prompt_for_env(vim.api.nvim_get_current_buf(), function()
            M.run_request()
        end)
        return
    end

    request = parser.replace_placeholders(request, env)

    if verbose then
        print("Request after placeholder replacement:", vim.inspect(request)) -- Debug output
    end

    http_client.send_request(request)
end

M.stop_request = function()
    local current_request = http_client.get_current_request()
    if not current_request then
        print('\nNo active request to stop')
        return
    end

    local success, error = pcall(function()
        http_client.stop_request()
    end)

    if success then
        print('\nHTTP request stopped successfully')
    else
        print('\nError stopping HTTP request: ' .. tostring(error))
    end

    -- Cleanup
    http_client.clear_current_request()
end

M.run_all = function()
    local verbose = vvv.get_verbose_mode()

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local requests = parser.parse_all_requests(lines)
    local env = environment.get_current_env()

    if #requests == 0 then
        vim.notify("[http_client] No requests found in buffer", vim.log.levels.WARN)
        return
    end

    -- If any request needs env vars but none are set, prompt first then retry.
    if not next(env) then
        for _, req in ipairs(requests) do
            if environment.env_variables_needed(req) then
                prompt_for_env(vim.api.nvim_get_current_buf(), function()
                    M.run_all()
                end)
                return
            end
        end
    end

    local results = {}
    local pending = 0
    local rendered = false
    local uv = vim.uv or vim.loop
    local started_at = uv.hrtime()

    -- Pre-size so async completions can slot in by index and ordering is
    -- preserved regardless of which request finishes first.
    for i = 1, #requests do results[i] = false end

    local function maybe_render()
        if pending ~= 0 or rendered then return end
        rendered = true
        local elapsed_ms = (uv.hrtime() - started_at) / 1e6
        local lines_out = {}
        for _, line in ipairs(results) do
            if type(line) == "string" then
                table.insert(lines_out, line)
            end
        end
        table.insert(lines_out, "")
        table.insert(lines_out, string.format(
            "Completed %d requests in %.1fs", #requests, elapsed_ms / 1000))
        local ui = require('http_client.ui.display')
        ui.display_in_buffer(table.concat(lines_out, "\n"), "HTTP Run All Results")
    end

    vim.notify(
        string.format("[http_client] Dispatching %d requests...", #requests),
        vim.log.levels.INFO)

    for i, raw_request in ipairs(requests) do
        local env_needed = environment.env_variables_needed(raw_request)
        if env_needed and not next(env) then
            results[i] = string.format(
                "SKIP: %s %s - environment variables needed but not set",
                raw_request.method, raw_request.url)
        else
            local request = parser.replace_placeholders(raw_request, env)
            pending = pending + 1
            http_client.send_request_unmanaged(request, function(ok, pr_or_err)
                if ok then
                    local pr = pr_or_err
                    local status_num = tonumber(pr.status) or 0
                    local marker = (status_num > 0 and status_num < 400) and "OK " or "ERR"
                    results[i] = string.format("%s: %s %s %s %s",
                        marker,
                        request.method,
                        request.url,
                        request.http_version or "HTTP/1.1",
                        tostring(pr.status))
                else
                    local err = pr_or_err or {}
                    results[i] = string.format("ERR: %s %s - %s (curl exit %s)",
                        request.method,
                        request.url,
                        err.message or "transport error",
                        tostring(err.exit or "?"))
                end
                pending = pending - 1
                maybe_render()
            end)
        end
    end

    -- Covers the all-skipped case (pending never incremented) and is a no-op
    -- otherwise because the guard in maybe_render only fires once.
    maybe_render()
end

return M

