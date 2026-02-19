# Response Handling

nvim-http-client provides rich features for handling HTTP responses, including the ability to view, save, and process responses with custom handlers.

## Response Window

Responses are displayed in a dedicated split window with the following features:

- Each response creates a new tab with timestamp
- Latest 10 responses are preserved
- Automatic formatting for JSON and XML responses
- Syntax highlighting for response bodies
- Timing metrics when profiling is enabled

### Navigation

You can navigate between responses using:

- `H` - Previous response
- `L` - Next response
- `q` or `<Esc>` - Close response window

## Response Handlers

Response handlers allow you to execute custom code after receiving a response. This is useful for extracting data from responses and using it in subsequent requests.

### Syntax

Response handlers are defined using the following syntax:

```http
### Your HTTP Request
GET {{host}}/api/endpoint

> {%
-- Your Lua code here
%}
```

The code between `> {%` and `%}` is executed as **Lua** after the response is received.

### Available Objects

Within a response handler, you have access to:

- `response` - The HTTP response object
  - `response.body` - The response body (parsed as JSON if possible, otherwise a string)
  - `response.headers` - Response headers object with additional methods
    - `response.headers.valueOf(headerName)` - Get header value with case-insensitive lookup
  - `response.status` - HTTP status code

- `client` - The HTTP client object
  - `client.global.set(key, value)` - Set a global variable for use in subsequent requests

### Standard Library

The following Lua standard library modules and functions are available inside a handler:

| Available | Description |
|---|---|
| `os.time()` | Current Unix timestamp |
| `os.date(format, time)` | Format a timestamp |
| `os.clock()` | CPU time |
| `math.*` | All math functions |
| `string.*` | All string functions |
| `table.*` | All table functions |
| `tostring`, `tonumber`, `type` | Type conversion |
| `pairs`, `ipairs`, `next`, `select` | Iteration helpers |
| `print` | Print to Neovim messages |
| `error` | Raise an error |

### Example: Extracting an Authentication Token

```http
### Login
POST {{host}}/api/login
Content-Type: application/json

{
    "username": "{{username}}",
    "password": "{{password}}"
}

> {%
client.global.set("auth_token", response.body.token)
%}

### Get Protected Resource
GET {{host}}/api/protected
Authorization: Bearer {{auth_token}}
```

### Example: Processing Data

```http
### Get Users
GET {{host}}/api/users

> {%
client.global.set("user_count", tostring(#response.body))

local admin
for _, user in ipairs(response.body) do
    if user.role == "admin" then
        admin = user
        break
    end
end
if admin then
    client.global.set("admin_id", admin.id)
end
%}

### Get Admin Details
GET {{host}}/api/users/{{admin_id}}
```

### Example: Extracting Headers

```http
### Login with Session
POST {{host}}/api/login
Content-Type: application/json

{
    "username": "{{username}}",
    "password": "{{password}}"
}

> {%
local session_id = response.headers.valueOf("mcp-session-id")
if session_id then
    client.global.set("session_id", session_id)
end
%}

### Use Session in Next Request
GET {{host}}/api/protected
X-Session-ID: {{session_id}}
```

**Note:** The `valueOf` method provides case-insensitive header lookup, so `response.headers.valueOf("mcp-session-id")` will match `MCP-Session-ID` or `Mcp-Session-Id`.

### Example: Computing Timestamps in a Handler

If you need timestamps derived at handler time (e.g. to store alongside a token), use `os.date`:

```http
### Login
POST {{host}}/api/login
Content-Type: application/json

{"username": "{{username}}", "password": "{{password}}"}

> {%
client.global.set("auth_token", response.body.access_token)
local expires = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 3600)
client.global.set("token_expires_at", expires)
%}
```

For timestamps used directly in request bodies, prefer the built-in `$isoTimestamp` dynamic variable instead — see [Environment Files and Variables](environments.md#dynamic-variables).

## Saving Responses

You can save the current response body to a file using:

- Command: `:HttpSaveResponse`
- Default keybinding: `<leader>hs` (if enabled)

When saving a response:
1. You'll be prompted for a filename
2. The response body will be formatted (if it's JSON or XML)
3. The formatted content will be saved to the specified file
