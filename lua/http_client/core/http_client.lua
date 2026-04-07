local M = {}
local curl = require('plenary.curl')
local vvv = require('http_client.utils.verbose')
local state = require('http_client.state')
local profiling = require('http_client.utils.profiling')
local display = require('http_client.ui.display')

-- { request, job, timeout_timer } | nil
local inflight = nil

local function detect_content_type(headers)
    local content_type

    -- If headers are in key-value pair format
    for k, v in pairs(headers or {}) do
        -- Handle numeric keys if headers are returned as an array of strings
        if type(k) == "number" and type(v) == "string" then
            local header_key, header_value = v:match("^(.-):%s*(.*)")
            if header_key and header_key:lower() == "content-type" then
                content_type = header_value
                break
            end
        elseif type(k) == "string" and k:lower() == "content-type" then
            content_type = v
            break
        end
    end

    if content_type then
        if content_type:match("application/json") then
            return "json"
        elseif content_type:match("application/xml") or content_type:match("text/xml") then
            return "xml"
        elseif content_type:match("text/html") then
            return "html"
        elseif content_type:match("text/csv") or content_type:match("application/csv") then
            return "csv"
        end
    end
    return "text"
end

local function clean_invalid_escapes(json_str)
    -- Remove octal/decimal escapes like \13
    json_str = json_str:gsub("\\%d%d?%d?", "")
    -- Remove any other invalid escapes (not one of the valid JSON escapes)
    json_str = json_str:gsub("\\([^\"\\/bfnrtu])", "")
    return json_str
end

local function prepare_response(request, response)
    local content_type = detect_content_type(response.headers or {})
    local formatted_body = response.body or "No body"

    if content_type == "json" then
        formatted_body = clean_invalid_escapes(formatted_body)
    end

    local pr = {
        formatted_body = formatted_body,
        headers = response.headers or {},
        status = response.status or "N/A",
        content_type = content_type,
        response_handler = request.response_handler,
        request = {
            method = request.method,
            url = request.url,
            http_version = request.http_version or "N/A",
            test_name = request.test_name or "N/A",
        },
        request_id = request.request_id,
        timing_metrics = response.timing_metrics or {},
    }

    -- store_response deepcopies pr; the ui table contains a uv timer handle that
    -- vim.deepcopy can't copy, so callers attach pr.ui *after* this returns.
    state.store_response(pr)

    return pr
end

local function handle_response(pr)
    local response_handler = require('http_client.core.response_handler')
    if pr.response_handler then
        local body
        if pr.content_type == "json" then
            local ok, decoded = pcall(vim.json.decode, pr.formatted_body)
            if ok then
                body = decoded
            else
                body = pr.formatted_body
            end
        else
            body = pr.formatted_body
        end

        response_handler.execute(pr.response_handler, {
            body = body,
            headers = pr.headers,
            status = pr.status
        })
    end
end

local function profiling_enabled()
    local profiling_config = require('http_client.config').get('profiling')
    return profiling_config and profiling_config.enabled
end

local function stop_timeout(timer)
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
end

-- Tear down the current inflight slot. Stops the timeout timer, clears
-- metrics, and (if requested) shuts down the curl job. Returns nothing —
-- callers that needed the request/job already captured them.
local function teardown_inflight(shutdown_job)
    if not inflight then return end
    local req = inflight.request
    local job = inflight.job
    stop_timeout(inflight.timeout_timer)
    inflight = nil

    if req.request_id then
        pcall(profiling.clear_metrics, req.request_id)
    end
    if shutdown_job and job and not job.is_shutdown then
        pcall(function() job:shutdown() end)
    end
end

local function cancel_inflight(reason)
    if not inflight then return end
    local req = inflight.request
    teardown_inflight(true)

    -- Synchronous render: callers (send_request cancel-and-replace, stop_request,
    -- the timeout timer) all run on the main thread, so we don't need to schedule.
    -- Doing it sync also avoids a race where the next request's "pending" status
    -- briefly gets overwritten by the deferred "cancelled".
    display.show_cancelled(req)

    if reason then
        vim.notify("[http_client] " .. reason, vim.log.levels.INFO)
    end
end

local function finalize_success(request, response)
    if not inflight or inflight.request.request_id ~= request.request_id then
        return
    end
    teardown_inflight(false)

    if profiling_enabled() then
        profiling.end_metric(request.request_id, "total")
        response.timing_metrics = profiling.get_metrics(request.request_id)
        response.timing_metrics.url = request.url
    end

    vvv.debug_print("Response received")
    if vvv.get_verbose_mode() then
        vvv.debug_print(string.format("Status: %s", response.status))
        if response.headers then
            vvv.debug_print("Response headers:")
            for k, v in pairs(response.headers) do
                vvv.debug_print(string.format("  %s: %s", k, v))
            end
        end
        vvv.debug_print("Response body:")
        vvv.debug_print(response.body)
    end

    local pr = prepare_response(request, response)
    -- prepare_response intentionally omits ui from pr because state.store_response
    -- deepcopies the table and vim.deepcopy can't copy uv timer userdata.
    pr.ui = request.ui

    display.show_response(pr)
    handle_response(pr)
end

local function finalize_error(request, err)
    if not inflight or inflight.request.request_id ~= request.request_id then
        return
    end
    teardown_inflight(false)
    display.show_error(request, err)
end

M.send_request = function(request)
    vvv.debug_print("Sending request...")
    vvv.debug_print(string.format("Method: %s, URL: %s, HTTP Version: %s", request.method, request.url,
        request.http_version))

    local request_timeout = require('http_client.config').get('request_timeout')
    local profile = profiling_enabled()

    if inflight then
        cancel_inflight("Cancelled previous request")
    end

    request.request_id = profiling.generate_request_id()
    display.show_pending(request)

    if not request.url:match("^https?://") then
        request.url = "http://" .. request.url
    end

    if vvv.get_verbose_mode() then
        vvv.debug_print("Headers:")
        for k, v in pairs(request.headers or {}) do
            vvv.debug_print(string.format("  %s: %s", k, v))
        end
        if request.body then
            vvv.debug_print("Request body:")
            vvv.debug_print(request.body)
        else
            vvv.debug_print("No request body")
        end
    end

    if profile then
        profiling.start_metric(request.request_id, "total")
        profiling.start_metric(request.request_id, "dns_resolution")
    end

    local curl_options = {
        url = request.url,
        method = request.method,
        body = request.body,
        headers = request.headers,
        callback = function(response)
            vim.schedule(function()
                finalize_success(request, response)
            end)
        end,
        on_error = function(err)
            vim.schedule(function()
                finalize_error(request, {
                    kind = "transport",
                    message = err.message,
                    stderr = err.stderr,
                    exit = err.exit,
                })
            end)
        end,
    }

    if profile then
        curl_options.on_start = function()
            profiling.end_metric(request.request_id, "dns_resolution")
            profiling.start_metric(request.request_id, "connection")
        end

        curl_options.on_connect = function()
            profiling.end_metric(request.request_id, "connection")
            profiling.start_metric(request.request_id, "send_request")
        end

        curl_options.on_first_byte = function()
            profiling.end_metric(request.request_id, "send_request")

            local metrics = profiling.get_metrics(request.request_id)
            if metrics.send_request and metrics.send_request.end_time then
                local start_time = metrics.send_request.end_time
                metrics.server_processing = {
                    start_time = start_time,
                    end_time = vim.loop.hrtime(),
                    duration = (vim.loop.hrtime() - start_time) / 1000000,
                }
            end

            profiling.start_metric(request.request_id, "content_transfer")
        end
    end

    if request.http_version then
        if request.http_version == "HTTP/2" or request.http_version == "HTTP/2 (Prior Knowledge)" then
            curl_options.http_version = "HTTP/2"
        elseif request.http_version == "HTTP/1.1" then
            curl_options.http_version = "HTTP/1.1"
        else
            vvv.debug_print("Unknown HTTP version: " .. request.http_version)
        end
    end

    local ssl_config = require('http_client.core.environment').get_ssl_config()
    if ssl_config.verifyHostCertificate == false then
        curl_options.insecure = true
    end

    local job = curl.request(curl_options)
    if not job then
        display.show_error(request, { kind = "transport", message = "Failed to dispatch request", exit = -1 })
        return
    end

    -- plenary's async path ignores opts.timeout entirely (curl.lua:322-324),
    -- so we enforce request_timeout ourselves with vim.defer_fn.
    local timeout_timer = vim.defer_fn(function()
        if inflight and inflight.request.request_id == request.request_id then
            if inflight.job and not inflight.job.is_shutdown then
                pcall(function() inflight.job:shutdown() end)
            end
            finalize_error(request, { kind = "timeout", message = "Request timed out" })
        end
    end, request_timeout)

    inflight = { request = request, job = job, timeout_timer = timeout_timer }

    vvv.debug_print("Request sent, waiting for response...")
end

M.stop_request = function()
    if not inflight then
        vim.notify("[http_client] No active request to stop", vim.log.levels.INFO)
        return
    end
    cancel_inflight()
end

M.clear_current_request = function()
    teardown_inflight(false)
end

M.get_current_request = function()
    return inflight and inflight.job or nil
end

-- Parallel-friendly dispatch used by :HttpRunAll. Unlike M.send_request:
--   * does NOT touch the inflight slot (multiple unmanaged requests can run
--     concurrently without cancelling each other)
--   * does NOT render per-request pending/response UI (the caller renders a
--     single summary buffer when the whole batch finishes)
--   * does NOT enforce request_timeout — callers can layer that in if needed;
--     for run_all we rely on plenary's network defaults to keep things simple
-- Calls on_done(ok, pr_or_err) exactly once:
--   * on success: ok = true,  pr_or_err = pr (the prepared response)
--   * on failure: ok = false, pr_or_err = err table { message, stderr, exit }
M.send_request_unmanaged = function(request, on_done)
    local profile = profiling_enabled()

    request.request_id = profiling.generate_request_id()

    if not request.url:match("^https?://") then
        request.url = "http://" .. request.url
    end

    if profile then
        profiling.start_metric(request.request_id, "total")
    end

    local done = false
    local function settle(ok, value)
        if done then return end
        done = true
        on_done(ok, value)
    end

    local function finish_success(response)
        if profile then
            profiling.end_metric(request.request_id, "total")
            response.timing_metrics = profiling.get_metrics(request.request_id)
            response.timing_metrics.url = request.url
        end
        local pr = prepare_response(request, response)
        handle_response(pr)
        if profile then
            pcall(profiling.clear_metrics, request.request_id)
        end
        settle(true, pr)
    end

    local function finish_error(err)
        if profile then
            pcall(profiling.clear_metrics, request.request_id)
        end
        settle(false, err)
    end

    local curl_options = {
        url = request.url,
        method = request.method,
        body = request.body,
        headers = request.headers,
        callback = function(response)
            vim.schedule(function() finish_success(response) end)
        end,
        on_error = function(err)
            vim.schedule(function()
                finish_error({
                    kind = "transport",
                    message = err and err.message,
                    stderr = err and err.stderr,
                    exit = err and err.exit,
                })
            end)
        end,
    }

    if request.http_version then
        if request.http_version == "HTTP/2" or request.http_version == "HTTP/2 (Prior Knowledge)" then
            curl_options.http_version = "HTTP/2"
        elseif request.http_version == "HTTP/1.1" then
            curl_options.http_version = "HTTP/1.1"
        end
    end

    local ssl_config = require('http_client.core.environment').get_ssl_config()
    if ssl_config.verifyHostCertificate == false then
        curl_options.insecure = true
    end

    local ok, job = pcall(curl.request, curl_options)
    if not ok or not job then
        vim.schedule(function()
            finish_error({
                kind = "transport",
                message = "Failed to dispatch request" .. ((not ok and job) and (": " .. tostring(job)) or ""),
                exit = -1,
            })
        end)
    end
end

-- Test seam: prepare_response is file-local but the deepcopy regression test
-- needs to drive it directly without going through curl.
M._prepare_response = prepare_response

return M
