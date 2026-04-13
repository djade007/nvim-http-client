local M = {}
local file_utils = require('http_client.utils.file_utils')

-- Per-buffer environment state: bufnr -> { env_file, private_env_file, env }
local buf_envs = {}
local global_variables = {}

local function resolve_bufnr(bufnr)
    return (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
end

local function get_buf_state(bufnr)
    bufnr = resolve_bufnr(bufnr)
    if not buf_envs[bufnr] then
        buf_envs[bufnr] = { env_file = nil, private_env_file = nil, env = {}, env_name = nil }
    end
    return buf_envs[bufnr]
end

-- Clean up state when a buffer is wiped.
vim.api.nvim_create_autocmd('BufWipeout', {
    callback = function(ev) buf_envs[ev.buf] = nil end,
})

M.set_env_file = function(file_path, bufnr)
    -- If the path is relative, make it absolute using the project root
    if not file_path:match("^/") then
        file_path = file_utils.get_project_root() .. "/" .. file_path
    end

    local state = get_buf_state(bufnr)
    state.env_file = file_path
    -- Set the private environment file path
    state.private_env_file = file_path:gsub("%.env%.json$", ".private.env.json")

    -- Check if the private file exists
    if vim.fn.filereadable(state.private_env_file) ~= 1 then
        state.private_env_file = nil
    end
    M.load_env(bufnr)
end

M.load_env = function(bufnr)
    local state = get_buf_state(bufnr)
    if not state.env_file then return end

    if state.env_name then
        M.set_env(state.env_name, bufnr)
    else
        M.set_env('dev', bufnr)
    end
end

M.set_env = function(env_name, bufnr)
    local state = get_buf_state(bufnr)
    if not state.env_file then
        print('No environment file selected')
        return false
    end

    local env_data = file_utils.read_json_file(state.env_file)
    if not env_data then
        print('Failed to read environment file')
        return false
    end

    state.env_name = env_name

    -- Start with an empty environment
    state.env = {}

    -- Merge default environment if it exists
    if env_data['dev'] then
        state.env = vim.tbl_deep_extend('force', state.env, env_data['dev'])
    end

    -- Merge selected environment
    if env_data[env_name] then
        state.env = vim.tbl_deep_extend('force', state.env, env_data[env_name])
    end

    -- Merge with private environment if it exists
    if state.private_env_file then
        local private_env_data = file_utils.read_json_file(state.private_env_file)
        if private_env_data then
            -- Merge private default environment if it exists
            if private_env_data['dev'] then
                state.env = vim.tbl_deep_extend('force', state.env, private_env_data['dev'])
            end
            -- Merge private selected environment if it exists
            if private_env_data[env_name] then
                state.env = vim.tbl_deep_extend('force', state.env, private_env_data[env_name])
            end
        end
    end

    return true
end

M.get_current_env = function(bufnr)
    local state = get_buf_state(bufnr)
    return vim.tbl_deep_extend('force', {}, state.env, global_variables)
end

M.get_current_env_file = function(bufnr)
    local state = get_buf_state(bufnr)
    return state.env_file
end

M.get_current_private_env_file = function(bufnr)
    local state = get_buf_state(bufnr)
    return state.private_env_file
end

M.get_ssl_config = function(bufnr)
    local state = get_buf_state(bufnr)
    if state.env and state.env.SSLConfiguration then
        return state.env.SSLConfiguration
    end
    return {}
end

M.set_global_variable = function(key, value)
    global_variables[key] = value
end

M.get_global_variable = function(key)
    return global_variables[key]
end

-- Return all global variables
M.get_global_variables = function()
    return global_variables
end

M.env_variables_needed = function(request)
    local function check_for_placeholders(str)
        return str and str:match("{{.-}}")
    end

    if check_for_placeholders(request.url) then
        return true
    end

    for _, header_value in pairs(request.headers) do
        if check_for_placeholders(header_value) then
            return true
        end
    end

    if check_for_placeholders(request.body) then
        return true
    end

    return false
end

return M
