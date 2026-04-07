# Environment Files and Variables

nvim-http-client uses environment files to manage variables that can be used in your HTTP requests.

## Environment Files

Environment files are JSON files with the extension `.env.json`. The plugin will look for these files in your project directory.

### Structure

An environment file has the following structure:

```json
{
    "dev": {
        "host": "http://localhost:3000",
        "apiKey": "dev-api-key"
    },
    "production": {
        "host": "https://api.example.com",
        "apiKey": "prod-api-key"
    },
    "staging": {
        "host": "https://staging.example.com",
        "apiKey": "staging-api-key"
    }
}
```

- The `dev` environment is the default and is used as a base environment.
- When you select another environment (e.g., "production"), it will inherit values from `dev` and then override them with the environment-specific values.

### Private Environment Files

For sensitive information, you can create a private environment file named `.private.env.json` which will be automatically loaded and merged with the regular environment file.

```json
{
    "dev": {
        "username": "admin",
        "password": "secret"
    },
    "production": {
        "password": "prod-password"
    }
}
```

Private environment files follow the same structure and inheritance rules as regular environment files.

## Using Environment Variables

You can use environment variables in your HTTP requests using the `{{variable}}` syntax:

```http
### Get User
GET {{host}}/api/users/{{userId}}
Authorization: Bearer {{apiKey}}

### Create User
POST {{host}}/api/users
Content-Type: application/json
Authorization: Bearer {{apiKey}}

{
    "name": "John Doe",
    "email": "john@example.com",
    "password": "{{password}}"
}
```

Environment variables can be used in:
- URLs
- Headers
- Request bodies

## Dynamic Variables

Dynamic variables are built-in variables prefixed with `$` that are resolved at request-send time. They do not need to be defined in an environment file.

| Variable | Example output | Description |
|---|---|---|
| `{{$isoTimestamp}}` | `2026-02-19T10:30:45Z` | Current UTC time in ISO 8601 |
| `{{$isoTimestamp -1 m}}` | `2026-02-19T10:29:45Z` | UTC time with offset (units: `s`, `m`, `h`, `d`) |
| `{{$isoTimestamp +20 m}}` | `2026-02-19T10:50:45Z` | Positive offset |
| `{{$timestamp}}` | `1740000000` | Current Unix timestamp (seconds) |
| `{{$uuid}}` | `f47ac10b-58cc-...` | Random UUID v4 |
| `{{$randomInt}}` | `742` | Random integer between 1 and 1000 |
| `{{$randomInt 100 999}}` | `583` | Random integer in a custom range |

### Offset syntax for `$isoTimestamp`

```
{{$isoTimestamp [+/-][amount] [unit]}}
```

Supported units:
- `s` — seconds
- `m` — minutes
- `h` — hours
- `d` — days

### Example usage

```http
### Submit event with dynamic timestamp
POST {{host}}/api/events
Content-Type: application/json
Authorization: Bearer {{auth_token}}

{
    "event_id": "{{$uuid}}",
    "occurred_at": "{{$isoTimestamp -1 m}}",
    "expires_at": "{{$isoTimestamp +24 h}}",
    "value": "{{$randomInt 1 100}}"
}
```

## Selecting Environments

### Commands

- `:HttpEnvFile`: Select an environment file to use (`.env.json`)
- `:HttpEnv`: Select an environment from the current environment file

### With Telescope

If you have the Telescope integration set up:

- `:Telescope http_client http_env_files`: Select an environment file
- `:Telescope http_client http_envs`: Select an environment

### Default Keybindings

- `<leader>hf`: Select environment file
- `<leader>he`: Set current environment

## Global Variables

You can set global variables in your response handlers that will be available for all subsequent requests:

```http
### Login
POST {{host}}/api/login
Content-Type: application/json

{
    "username": "{{username}}",
    "password": "{{password}}"
}

> {%
client.global.set("token", response.body.token)
%}

### Get Protected Resource
GET {{host}}/api/protected
Authorization: Bearer {{token}}
```

Global variables:
- Persist for the duration of your Neovim session
- Take precedence over environment variables
- Can be used just like environment variables

See [Response Handling](response-handling.md) for full details on handler syntax and the available Lua standard library.

## Running Without Environment

You can run requests without selecting an environment file, but if your request uses environment variables, the plugin will display a message suggesting to select an environment file.

For dry runs, you'll see a warning in the output if environment variables are needed but not set.
