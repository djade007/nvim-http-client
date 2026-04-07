local request_module = require('http_client.commands.request')
local hc = require('http_client.core.http_client')
local display = require('http_client.ui.display')

describe("commands.request.run_all", function()
    local original_unmanaged
    local original_display_in_buffer
    local capture
    local source_buf

    before_each(function()
        capture = { calls = {}, rendered = nil }

        original_unmanaged = hc.send_request_unmanaged
        original_display_in_buffer = display.display_in_buffer

        hc.send_request_unmanaged = function(req, on_done)
            table.insert(capture.calls, { request = req, on_done = on_done })
        end

        display.display_in_buffer = function(content, title)
            capture.rendered = { content = content, title = title }
        end

        source_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(source_buf)
    end)

    after_each(function()
        hc.send_request_unmanaged = original_unmanaged
        display.display_in_buffer = original_display_in_buffer
        if vim.api.nvim_buf_is_valid(source_buf) then
            vim.api.nvim_buf_delete(source_buf, { force = true })
        end
    end)

    local function set_buffer_lines(lines)
        vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, lines)
    end

    it("preserves source order when completions arrive out of order", function()
        set_buffer_lines({
            "### first",
            "GET https://example.com/a",
            "",
            "### second",
            "GET https://example.com/b",
            "",
            "### third",
            "GET https://example.com/c",
        })

        request_module.run_all()

        assert.are.equal(3, #capture.calls)

        -- Fire completions in reverse order to simulate the third request
        -- finishing first, then the first, then the second.
        capture.calls[3].on_done(true, { status = 200 })
        capture.calls[1].on_done(true, { status = 201 })
        capture.calls[2].on_done(true, { status = 202 })

        assert.is_not_nil(capture.rendered)
        local lines = vim.split(capture.rendered.content, "\n")
        local idx_a, idx_b, idx_c
        for i, line in ipairs(lines) do
            if line:match("/a") then idx_a = i end
            if line:match("/b") then idx_b = i end
            if line:match("/c") then idx_c = i end
        end
        assert.is_not_nil(idx_a)
        assert.is_not_nil(idx_b)
        assert.is_not_nil(idx_c)
        assert.is_true(idx_a < idx_b, "request a should appear before b")
        assert.is_true(idx_b < idx_c, "request b should appear before c")
    end)

    it("renders the summary exactly once when all requests complete", function()
        set_buffer_lines({
            "### one",
            "GET https://example.com/x",
            "",
            "### two",
            "GET https://example.com/y",
        })

        request_module.run_all()
        assert.are.equal(2, #capture.calls)

        capture.calls[1].on_done(true, { status = 200 })
        assert.is_nil(capture.rendered, "should not render until all requests complete")

        capture.calls[2].on_done(true, { status = 200 })
        assert.is_not_nil(capture.rendered, "should render after the last request completes")
    end)

    it("marks 4xx and 5xx as ERR", function()
        set_buffer_lines({
            "### r",
            "GET https://example.com/r",
        })

        request_module.run_all()
        capture.calls[1].on_done(true, { status = 500 })

        local content = capture.rendered.content
        assert.is_not_nil(content:match("ERR:"), "5xx should be marked ERR")
        assert.is_nil(content:match("OK :"), "should not be marked OK")
    end)

    it("marks 2xx as OK", function()
        set_buffer_lines({
            "### r",
            "GET https://example.com/r",
        })

        request_module.run_all()
        capture.calls[1].on_done(true, { status = 200 })

        local content = capture.rendered.content
        assert.is_not_nil(content:match("OK :"), "2xx should be marked OK")
    end)

    it("renders transport errors with curl exit code", function()
        set_buffer_lines({
            "### r",
            "GET https://example.com/r",
        })

        request_module.run_all()
        capture.calls[1].on_done(false, {
            message = "could not resolve host",
            exit = 6,
        })

        local content = capture.rendered.content
        assert.is_not_nil(content:match("ERR:"))
        assert.is_not_nil(content:match("could not resolve host"))
        assert.is_not_nil(content:match("curl exit 6"))
    end)

    it("includes a 'Completed N requests' summary line", function()
        set_buffer_lines({
            "### a",
            "GET https://example.com/a",
            "",
            "### b",
            "GET https://example.com/b",
        })

        request_module.run_all()
        capture.calls[1].on_done(true, { status = 200 })
        capture.calls[2].on_done(true, { status = 200 })

        assert.is_not_nil(capture.rendered.content:match("Completed 2 requests"))
    end)

    it("warns and bails when the buffer has no requests", function()
        set_buffer_lines({ "no requests here" })
        request_module.run_all()
        assert.are.equal(0, #capture.calls)
        assert.is_nil(capture.rendered)
    end)
end)
