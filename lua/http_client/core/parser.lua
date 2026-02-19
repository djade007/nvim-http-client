local M = {}
local environment = require('http_client.core.environment')
local url_u = require('http_client.utils.url')

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

local function extract_test_name(lines)
    if lines[1] and lines[1]:match("^###") then
        return lines[1]:match("^###%s*(.+)$") or ""
    end
    return ""
end

local function remove_comment(line)
    local comment_start = line:find("#")
    if comment_start then
        return line:sub(1, comment_start - 1):match("^%s*(.-)%s*$") -- Trim and remove comment part
    end
    return line:match("^%s*(.-)%s*$")                               -- Trim if no comment
end

M.get_request_under_cursor = function()
    local current_line = vim.api.nvim_win_get_cursor(0)[1]
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

    local request_start, request_end
    local has_separators = false

    -- First pass: check if there are any ### separators
    for _, line in ipairs(lines) do
        if line:match("^###") and not line:match("^###%s*#") then
            has_separators = true
            break
        end
    end

    if has_separators then
        -- Find the request that contains the cursor
        for i, line in ipairs(lines) do
            if line:match("^###") and not line:match("^###%s*#") then
                if i <= current_line then
                    request_start = i
                else
                    request_end = i - 1
                    break
                end
            end
        end

        -- If no end found, it's the last request in the file
        if not request_end then
            request_end = #lines
        end

        -- If no start found, it might be the first request without a separator
        if not request_start then
            request_start = 1
            for i, line in ipairs(lines) do
                if line:match("^###") and not line:match("^###%s*#") then
                    request_end = i - 1
                    break
                end
            end
        end
    else
        -- No separators, treat the whole file as one request
        request_start = 1
        request_end = #lines
    end

    local request_lines = vim.list_slice(lines, request_start, request_end)
    local test_name = extract_test_name(request_lines)

    -- Remove the ### line from request_lines if it exists
    if has_separators and request_lines[1] and request_lines[1]:match("^###") then
        table.remove(request_lines, 1)
    end

    -- If request_lines is empty after removing ###, it means cursor was on the ### line
    -- In this case, include the next request if available
    if #request_lines == 0 and request_end < #lines then
        request_end = request_end + 1
        while request_end < #lines and not lines[request_end + 1]:match("^###") do
            request_end = request_end + 1
        end
        request_lines = vim.list_slice(lines, request_start + 1, request_end)
    end

    -- If still empty, return nil
    if #request_lines == 0 then
        return nil
    end

    local request = M.parse_request(request_lines)
    request.test_name = test_name
    return request
end

M.parse_request = function(lines)
    local request = {
        method = nil,
        url = nil,
        headers = {},
        body = nil,
        http_version = nil
    }

    local stage = "start"
    local body_lines = {}
    local response_handler = nil
    local in_response_handler = false

    for _, line in ipairs(lines) do
        line = trim(line)

        if line:match("^>%s*{%%") then
            in_response_handler = true
            response_handler = ""
        elseif line:match("^%%}") and in_response_handler then
            in_response_handler = false
        elseif in_response_handler then
            response_handler = response_handler .. line .. "\n"
        elseif line == "" then
            if stage == "headers" then
                stage = "body"
            end
        elseif stage == "start" then
            line = remove_comment(line)
            local method, url, version = line:match("^(%S+)%s+(.+)%s+(HTTP/%S+)$")
            if not method then
                method, url = line:match("^(%S+)%s+(.+)$")
            end
            if method and url then
                request.method = method
                request.url = url
                request.http_version = version or "HTTP/1.1"
                stage = "headers"
            end
        elseif stage == "headers" then
            line = remove_comment(line)
            local key, value = line:match("^([^:]+):%s*(.+)$")
            if key and value then
                key = trim(key)
                value = remove_comment(value)
                value = trim(value)
                if value ~= "" then
                    request.headers[key] = value
                end
            end
        elseif stage == "body" then
            table.insert(body_lines, remove_comment(line))
        end
    end

    if #body_lines > 0 and request.method ~= 'GET' then
        request.body = table.concat(body_lines, "\n")
    end

    request.response_handler = response_handler

    -- Add default User-Agent header if not present
    if not request.headers['User-Agent'] and not request.headers['user-agent'] then
        local config = require('http_client.config')
        local user_agent = config.get('user_agent')
        if user_agent then
            request.headers['User-Agent'] = user_agent
        end
    end

    return request
end

M.parse_all_requests = function(lines)
    local requests = {}
    local current_request = {}
    local in_request = false

    for _, line in ipairs(lines) do
        if line:match("^###") then
            if in_request and #current_request > 0 then
                table.insert(requests, M.parse_request(current_request))
                current_request = {}
            end
            in_request = true
        elseif in_request then
            table.insert(current_request, line)
        end
    end

    if #current_request > 0 then
        table.insert(requests, M.parse_request(current_request))
    end

    return requests
end

-- Resolve built-in dynamic variables that start with $.
-- Supported:
--   $isoTimestamp                 current UTC time as ISO 8601
--   $isoTimestamp [+/-N] [unit]  offset from now (units: s, m, h, d)
--   $timestamp                   current Unix timestamp (seconds)
--   $uuid                        random UUID v4
--   $randomInt                   random integer 1–1000
--   $randomInt [min] [max]       random integer in [min, max]
local function resolve_dynamic(var)
    if var:sub(1, 1) ~= "$" then
        return nil
    end

    -- $isoTimestamp with optional offset: "$isoTimestamp [+/-N] [unit]"
    if var == "$isoTimestamp" or var:match("^%$isoTimestamp") then
        local offset_secs = 0
        local sign, amount, unit = var:match("^%$isoTimestamp%s+([%+%-]?)(%d+)%s+([smhd])$")
        if amount then
            local multipliers = { s = 1, m = 60, h = 3600, d = 86400 }
            offset_secs = tonumber(amount) * (multipliers[unit] or 1)
            if sign == "-" then
                offset_secs = -offset_secs
            end
        end
        return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + offset_secs)
    end

    -- $timestamp
    if var == "$timestamp" then
        return tostring(os.time())
    end

    -- $uuid (v4)
    if var == "$uuid" then
        math.randomseed(os.time())
        local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
        return (template:gsub("[xy]", function(c)
            local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
            return string.format("%x", v)
        end))
    end

    -- $randomInt [min max]
    if var:match("^%$randomInt") then
        math.randomseed(os.time())
        local min_s, max_s = var:match("^%$randomInt%s+(%d+)%s+(%d+)$")
        if min_s and max_s then
            return tostring(math.random(tonumber(min_s), tonumber(max_s)))
        end
        return tostring(math.random(1, 1000))
    end

    return nil
end

M.replace_placeholders = function(request, env)
    local function replace(str)
        if str == nil then
            return nil
        end
        return (str:gsub("{{(.-)}}", function(var)
            return resolve_dynamic(var) or env[var] or environment.get_global_variable(var) or "{{" .. var .. "}}"
        end))
    end

    if request.url then
        request.url = replace(request.url)
        if (url_u.needs_encoding(request.url)) then
            request.url = url_u.encode_url(request.url)
        end
    end
    for k, v in pairs(request.headers) do
        request.headers[k] = replace(v)
    end
    if request.body then
        request.body = replace(request.body)
    end

    -- print("Request after placeholder replacement:", vim.inspect(request)) -- Debug output
    return request
end

return M

