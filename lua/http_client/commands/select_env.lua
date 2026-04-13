local M = {}

local environment = require('http_client.core.environment')
local file_utils = require('http_client.utils.file_utils')

M.select_env_file = function(config, bufnr, on_done)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local current_dir = vim.fn.expand('%:p:h')
    local files = file_utils.find_files('*.env.json', current_dir)
    local default_file = config.default_env_file or '.env.json'
    local default_index = nil

    -- Find the index of the default file
    for i, file in ipairs(files) do
        if file:match(default_file .. "$") then
            default_index = i
            break
        end
    end

    vim.ui.select(files, {
        prompt = 'Select environment file:',
        default = default_index
    }, function(choice)
        if choice then
            environment.set_env_file(vim.fs.joinpath(current_dir, choice), bufnr)
            print('\n\nEnvironment file set to: ' .. choice)
            -- Automatically select environment after file selection
            M.select_env(bufnr, on_done)
        end
    end)
end

M.select_env = function(bufnr, on_done)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not environment.get_current_env_file(bufnr) then
        print('\nNo environment file selected. Please select an environment file first.')
        return
    end

    local env_data = file_utils.read_json_file(environment.get_current_env_file(bufnr))
    if not env_data then
        print('\nFailed to read environment file')
        return
    end

    local env_names = { 'dev' }
    for name, _ in pairs(env_data) do
        if name ~= 'dev' then
            table.insert(env_names, name)
        end
    end

    vim.ui.select(env_names, {
        prompt = 'Select environment:',
    }, function(choice)
        if choice then
            local ok = environment.set_env(choice, bufnr)
            if ok then
                print('\nEnvironment set to: ' .. choice)
            else
                print('\nFailed to set environment: ' .. choice)
                return
            end
            if on_done then on_done() end
        end
    end)
end


return M

