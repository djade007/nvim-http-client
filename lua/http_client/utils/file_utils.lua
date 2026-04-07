local M = {}
local Path = require('plenary.path')

-- Store the project root globally
M.project_root = vim.fn.getcwd()

M.set_project_root = function(root_path)
    if root_path then
        M.project_root = root_path
    else
        M.project_root = vim.fn.getcwd()
    end
end

M.get_project_root = function()
    return M.project_root
end

-- Convert a simple glob pattern (supporting `*` and literal `.`) into a Lua
-- pattern anchored to the end of the string. Only the characters used by
-- current callers (`*.env.json`, `*.json`) need to be supported.
local function glob_to_lua_pattern(glob)
    local lua_pattern = glob:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', function(ch)
        if ch == '.' then
            return '%.'
        end
        return '%' .. ch
    end)
    lua_pattern = lua_pattern:gsub('%*', '.*')
    return lua_pattern .. '$'
end

M.find_files = function(pattern, project_root)
    local search_root = project_root or M.project_root
    local lua_pattern = glob_to_lua_pattern(pattern)

    local matches = vim.fs.find(function(name, _)
        return name:match(lua_pattern) ~= nil and not name:match('%.private%.')
    end, {
        path = search_root,
        type = 'file',
        limit = math.huge,
    })

    local files = {}
    for _, abs_path in ipairs(matches) do
        local rel = vim.fs.relpath(search_root, abs_path) or abs_path
        table.insert(files, rel)
    end

    return files
end

M.read_json_file = function(file_path)
    -- If the path is relative, make it absolute using the project root
    if not file_path:match("^/") then
        file_path = M.project_root .. "/" .. file_path
    end
    
    local file = io.open(file_path, "r")
    if not file then return nil end

    local content = file:read("*all")
    file:close()

    local ok, parsed = pcall(vim.fn.json_decode, content)
    if not ok then return nil end

    return parsed
end

M.write_file = function(filename, content)
    local path = Path:new(filename)

    local parent = path:parent()
    local mkdir_ok, mkdir_err = pcall(function()
        parent:mkdir({ parents = true })
    end)

    if not mkdir_ok then
        return false, string.format("Failed to create directory: %s", mkdir_err)
    end

    local write_ok, write_err = pcall(function()
        path:write(content, 'w')
    end)

    if not write_ok then
        return false, string.format("Failed to write file: %s", write_err)
    end

    return true, nil
end

return M

