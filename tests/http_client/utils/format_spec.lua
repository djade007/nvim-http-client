local format = require('http_client.utils.format')

describe("format.headers", function()
    it("formats an array of 'Key: Value' strings (plenary curl shape)", function()
        local result = format.headers({ "Content-Type: text/html", "X-Foo: bar" })
        assert.are.equal("Content-Type: text/html\nX-Foo: bar", result)
    end)

    it("formats a key-value table (parser shape)", function()
        local result = format.headers({ ["Content-Type"] = "text/html", ["X-Foo"] = "bar" })
        -- pairs() ordering isn't deterministic; compare as a set.
        local lines = vim.split(result, "\n")
        table.sort(lines)
        assert.are.same({ "Content-Type: text/html", "X-Foo: bar" }, lines)
    end)

    it("returns an empty string for empty input", function()
        assert.are.equal("", format.headers({}))
    end)

    it("returns an empty string for nil input", function()
        assert.are.equal("", format.headers(nil))
    end)

    it("skips array entries that don't contain a colon", function()
        local result = format.headers({ "not a header", "Valid: header" })
        assert.are.equal("Valid: header", result)
    end)

    it("preserves whitespace in header values", function()
        local result = format.headers({ "X-Custom: foo bar baz" })
        assert.are.equal("X-Custom: foo bar baz", result)
    end)

    it("handles a single-entry array", function()
        local result = format.headers({ "Content-Type: application/json" })
        assert.are.equal("Content-Type: application/json", result)
    end)

    it("handles a single-entry table", function()
        local result = format.headers({ Authorization = "Bearer token" })
        assert.are.equal("Authorization: Bearer token", result)
    end)
end)
