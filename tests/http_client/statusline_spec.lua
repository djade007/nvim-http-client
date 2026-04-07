local statusline = require('http_client.statusline')

describe("statusline.status", function()
    local bufnr

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
    end)

    after_each(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it("returns empty string when the status var is unset", function()
        assert.are.equal("", statusline.status(bufnr))
    end)

    it("returns empty string for an empty string value", function()
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "")
        assert.are.equal("", statusline.status(bufnr))
    end)

    it("renders 'pending' with the spinner glyph", function()
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "pending")
        assert.are.equal("⠋ pending", statusline.status(bufnr))
    end)

    it("renders 'error' with the cross glyph", function()
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "error")
        assert.are.equal("✗ ERROR", statusline.status(bufnr))
    end)

    it("renders 'timeout' with the clock glyph", function()
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "timeout")
        assert.are.equal("⏱ TIMEOUT", statusline.status(bufnr))
    end)

    it("renders 'cancelled' with the no-entry glyph", function()
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "cancelled")
        assert.are.equal("⊘ CANCELLED", statusline.status(bufnr))
    end)

    it("prefixes 1xx with the checkmark", function()
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "100")
        assert.are.equal("✓ 100", statusline.status(bufnr))
    end)

    it("prefixes 2xx with the checkmark", function()
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "200")
        assert.are.equal("✓ 200", statusline.status(bufnr))
    end)

    it("prefixes 3xx with the checkmark", function()
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "301")
        assert.are.equal("✓ 301", statusline.status(bufnr))
    end)

    it("prefixes 4xx with the warning glyph", function()
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "404")
        assert.are.equal("! 404", statusline.status(bufnr))
    end)

    it("prefixes 5xx with the cross glyph", function()
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "503")
        assert.are.equal("✗ 503", statusline.status(bufnr))
    end)

    it("preserves trailing timing info on success", function()
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "200 342ms")
        assert.are.equal("✓ 200 342ms", statusline.status(bufnr))
    end)

    it("preserves trailing timing info on error", function()
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "500 1200ms")
        assert.are.equal("✗ 500 1200ms", statusline.status(bufnr))
    end)

    it("falls through unrecognized values", function()
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "weird")
        assert.are.equal("weird", statusline.status(bufnr))
    end)

    it("defaults to the current buffer when bufnr is nil", function()
        vim.api.nvim_set_current_buf(bufnr)
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "200")
        assert.are.equal("✓ 200", statusline.status())
    end)
end)

describe("statusline.component", function()
    it("returns the status of the current buffer", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(bufnr)
        vim.api.nvim_buf_set_var(bufnr, "http_client_status", "200 342ms")
        assert.are.equal("✓ 200 342ms", statusline.component())
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("returns empty string with no status set", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(bufnr)
        assert.are.equal("", statusline.component())
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
end)
