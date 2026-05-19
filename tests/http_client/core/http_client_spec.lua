local hc = require('http_client.core.http_client')
local state = require('http_client.state')

describe("http_client._prepare_response", function()
    before_each(function()
        state.clear_responses()
    end)

    it("regression: must NOT include ui in pr (deepcopy bug)", function()
        -- The bug: prepare_response used to set pr.ui = request.ui, but
        -- request.ui contains a uv timer userdata (the spinner timer) which
        -- vim.deepcopy can't copy. state.store_response (called inside
        -- prepare_response) deepcopies pr, so the whole flow throws on every
        -- successful response. The fix is that prepare_response intentionally
        -- omits ui; finalize_success attaches it AFTER store_response runs.
        --
        -- This test fails (with "Cannot deepcopy object of type userdata")
        -- if anyone re-introduces ui = request.ui inside prepare_response.

        local uv = vim.uv or vim.loop
        local timer = uv.new_timer()
        timer:start(1000, 0, function() end)

        local request = {
            method = "GET",
            url = "https://example.com",
            headers = {},
            request_id = "rid-deepcopy-regression",
            ui = {
                spinner_timer = timer,
                bufnr = 0,
                source_bufnr = 0,
                started_at = 0,
                spinner_idx = 1,
                status_line_idx = 3,
            },
        }
        local response = {
            body = '{"a":1}',
            headers = { "Content-Type: application/json" },
            status = 200,
        }

        local pr
        assert.has_no.errors(function()
            pr = hc._prepare_response(request, response)
        end)

        assert.is_nil(pr.ui)

        timer:stop()
        timer:close()
    end)

    it("populates basic response fields", function()
        local request = {
            method = "POST",
            url = "https://example.com/foo",
            headers = {},
            test_name = "named",
            request_id = "rid-basic",
        }
        local response = {
            body = "hello",
            headers = { "Content-Type: text/plain" },
            status = 201,
        }

        local pr = hc._prepare_response(request, response)

        assert.are.equal(201, pr.status)
        assert.are.equal("text", pr.content_type)
        assert.are.equal("POST", pr.request.method)
        assert.are.equal("https://example.com/foo", pr.request.url)
        assert.are.equal("named", pr.request.test_name)
        assert.are.equal("rid-basic", pr.request_id)
        assert.are.equal("hello", pr.formatted_body)
    end)

    it("detects content type from Content-Type header (json)", function()
        local pr = hc._prepare_response(
            { method = "GET", url = "x", headers = {}, request_id = "r" },
            { body = '{"k":"v"}', headers = { "Content-Type: application/json" }, status = 200 }
        )
        assert.are.equal("json", pr.content_type)
    end)

    it("detects content type from Content-Type header (xml)", function()
        local pr = hc._prepare_response(
            { method = "GET", url = "x", headers = {}, request_id = "r" },
            { body = "<a/>", headers = { "Content-Type: application/xml" }, status = 200 }
        )
        assert.are.equal("xml", pr.content_type)
    end)

    it("falls back to text content type for unknown Content-Type", function()
        local pr = hc._prepare_response(
            { method = "GET", url = "x", headers = {}, request_id = "r" },
            { body = "raw", headers = { "Content-Type: application/octet-stream" }, status = 200 }
        )
        assert.are.equal("text", pr.content_type)
    end)

    it("stores the response in history", function()
        hc._prepare_response(
            { method = "GET", url = "x", headers = {}, request_id = "r1" },
            { body = "a", headers = {}, status = 200 }
        )
        local current = state.get_current_response()
        assert.is_not_nil(current)
        assert.are.equal(200, current.status)
    end)

    it("uses N/A for missing test_name and http_version", function()
        local pr = hc._prepare_response(
            { method = "GET", url = "x", headers = {}, request_id = "r" },
            { body = "", headers = {}, status = 200 }
        )
        assert.are.equal("N/A", pr.request.test_name)
        assert.are.equal("N/A", pr.request.http_version)
    end)

    it("stores raw_body alongside formatted_body", function()
        local pr = hc._prepare_response(
            { method = "GET", url = "x", headers = {}, request_id = "r" },
            { body = "hello", headers = { "Content-Type: text/plain" }, status = 200 }
        )
        assert.are.equal("hello", pr.raw_body)
        assert.are.equal("hello", pr.formatted_body)
    end)

    it("does NOT clean invalid JSON escapes for download requests", function()
        local body_with_invalid_escape = '{"msg":"hello\\13world"}'
        local pr = hc._prepare_response(
            { method = "GET", url = "x", headers = {}, request_id = "r", download_path = "" },
            { body = body_with_invalid_escape, headers = { "Content-Type: application/json" }, status = 200 }
        )
        assert.are.equal(body_with_invalid_escape, pr.raw_body)
        assert.are.equal(body_with_invalid_escape, pr.formatted_body)
    end)

    it("cleans invalid JSON escapes for non-download JSON requests", function()
        local body_with_invalid_escape = '{"msg":"hello\\13world"}'
        local pr = hc._prepare_response(
            { method = "GET", url = "x", headers = {}, request_id = "r" },
            { body = body_with_invalid_escape, headers = { "Content-Type: application/json" }, status = 200 }
        )
        assert.are.equal(body_with_invalid_escape, pr.raw_body)
        assert.are.equal('{"msg":"helloworld"}', pr.formatted_body)
    end)
end)
