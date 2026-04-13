local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local http_client = require("http_client")

local http_envs

local function env_previewer(origin_buf)
    return previewers.new_buffer_previewer({
        title = "Environment Preview",
        get_buffer_by_name = function(_, entry)
            return entry.value
        end,
        define_preview = function(self, entry, status)
            local env_file = http_client.environment.get_current_env_file(origin_buf)
            local env_data = http_client.file_utils.read_json_file(env_file)
            local env_content = vim.inspect(env_data[entry.value] or {})

            local private_file = http_client.environment.get_current_private_env_file(origin_buf)
            if private_file then
                local private_env = http_client.file_utils.read_json_file(private_file)
                if private_env and private_env[entry.value] then
                    env_content = env_content .. "\n\nPrivate Environment:\n" .. vim.inspect(private_env[entry.value])
                end
            end

            vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.split(env_content, '\n'))
            vim.api.nvim_buf_set_option(self.state.bufnr, 'filetype', 'lua')
        end,
    })
end

http_envs = function(opts)
    opts = opts or {}
    local origin_buf = opts.origin_buf or vim.api.nvim_get_current_buf()
    local env_file = http_client.environment.get_current_env_file(origin_buf)
    if not env_file then
        print("No environment file selected. Please select an environment file first.")
        return
    end

    local env_data = http_client.file_utils.read_json_file(env_file)
    if not env_data then
        print("Failed to read environment file")
        return
    end

    local results = { "dev" }
    for name, _ in pairs(env_data) do
        if name ~= "dev" then
            table.insert(results, name)
        end
    end

    pickers.new(opts, {
        prompt_title = "HTTP Environments",
        finder = finders.new_table {
            results = results,
            entry_maker = function(entry)
                return {
                    value = entry,
                    display = entry,
                    ordinal = entry,
                }
            end
        },
        sorter = conf.generic_sorter(opts),
        previewer = env_previewer(origin_buf),
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                http_client.environment.set_env(selection.value, origin_buf)
            end)
            return true
        end,
    }):find()
end

local http_env_files = function(opts)
    opts = opts or {}
    local origin_buf = vim.api.nvim_get_current_buf()
    local current_dir = vim.fn.expand('%:p:h')
    local results = http_client.file_utils.find_files('*.env.json', current_dir)

    pickers.new(opts, {
        prompt_title = "HTTP Environment Files",
        finder = finders.new_table {
            results = results,
            entry_maker = function(entry)
                return {
                    value = vim.fs.joinpath(current_dir, entry),
                    display = entry,
                    ordinal = entry,
                }
            end
        },
        sorter = conf.generic_sorter(opts),
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                http_client.environment.set_env_file(selection.value, origin_buf)
                -- Automatically open env selection after file selection
                vim.defer_fn(function()
                    http_envs({ origin_buf = origin_buf })
                end, 10)
            end)
            return true
        end,
    }):find()
end

local function health_check()
    local health = vim.health or require("htt_client.health")
    health.start("Telescope Extension: `http_client`")
    health.ok("Telescope HTTP Client extension is available")
end

return require("telescope").register_extension {
    exports = {
        http_env_files = http_env_files,
        http_envs = http_envs,
    },
    health = health_check
}

