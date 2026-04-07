local display = require('http_client.ui.display')

describe("display._unique_buffer_name", function()
    it("never produces colliding names within the same second", function()
        local n1 = display._unique_buffer_name("HTTP 200")
        local n2 = display._unique_buffer_name("HTTP 200")
        local n3 = display._unique_buffer_name("HTTP 200")
        assert.are_not.equal(n1, n2)
        assert.are_not.equal(n2, n3)
        assert.are_not.equal(n1, n3)
    end)

    it("includes the prefix and a timestamp + counter suffix", function()
        local name = display._unique_buffer_name("HTTP Request (pending)")
        -- Format is "[HH:MM:SS] <prefix> #<counter>"
        assert.is_not_nil(
            name:match("^%[%d%d:%d%d:%d%d%] HTTP Request %(pending%) #%d+$"),
            "name '" .. name .. "' did not match expected pattern"
        )
    end)

    it("monotonically increments the counter across calls", function()
        local first = display._unique_buffer_name("X")
        local second = display._unique_buffer_name("X")
        local n1 = tonumber(first:match("#(%d+)$"))
        local n2 = tonumber(second:match("#(%d+)$"))
        assert.is_not_nil(n1)
        assert.is_not_nil(n2)
        assert.is_true(n2 > n1, "counter should monotonically increase")
    end)
end)
