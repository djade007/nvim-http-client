# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [Unreleased]
### Added
* Download directives (`# @download`):
  * Add `# @download filename.ext` before a request line to auto-save the response body to a file.
  * Omit the filename (`# @download`) to auto-detect it from `Content-Disposition`, URL path, or content type.
  * Download requests skip JSON escape cleaning and formatting, preserving the raw response bytes.
  * The response buffer shows a download summary instead of the full body.
  * Works with both `:HttpRun` and `:HttpRunAll`.
  * Response state now preserves `raw_body` alongside `formatted_body` for accurate saving.
* Loading state for in-flight requests:
  * A response buffer now opens immediately on `:HttpRun` and shows the method, URL, and a Braille spinner (`⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏`) ticking at ~80ms.
  * Elapsed time appears after 500ms (e.g. `0.8s`).
  * After 3 seconds the wording changes from `Sending` to `Still sending`.
  * After 10 seconds the wording changes to `Still waiting on`.
  * On success, the spinner is replaced by the rendered response in the same buffer.
* Statusline integration:
  * The plugin sets a buffer-local variable `b:http_client_status` on the source `.http` buffer.
  * Values: `pending` while in flight, `<status> <ms>ms` on success (the `<ms>ms` portion is only present when profiling is enabled), `error`, `timeout`, or `cancelled` for failure modes.
  * Lualine and similar plugins can read this directly via `vim.b.http_client_status`.
* New `x` keymap in the response buffer that calls `:HttpStop`.

### Changed
* Error handling for in-flight requests now renders into the response buffer:
  * Curl/transport errors render `✗ ERROR (curl exit N)` plus the verbatim curl stderr in the same buffer instead of surfacing as a red `E5108` Lua error notification.
  * Timeouts render `⏱ TIMEOUT after Ns` with troubleshooting hints in the same buffer.
  * `:HttpStop` renders `⊘ CANCELLED` with the elapsed time in the same buffer.
* Cancel-and-replace policy for `:HttpRun`:
  * Triggering `:HttpRun` while a request is already in flight now automatically cancels the previous request (with a `Cancelled previous request` notification) and opens a fresh pending buffer for the new request, instead of silently doing nothing.
* Response buffer keymaps:
  * `q` and `<Esc>` now `:bdelete` the response buffer instead of `:close`-ing the window. This lets the cleanup autocmd fire and stops any spinner timer attached to that buffer.
  * `H` / `L` for history navigation are unchanged.
* Buffer history (`MAX_BUFFERS=10`) now skips pending buffers when evicting, so a slow in-flight request can never be silently dropped from the ring.

### Fixed
* `request_timeout` (default 30000ms) is now actually enforced for asynchronous requests. Previously the option was documented and present in `config.lua` but plenary's curl ignored `opts.timeout` on the async path, leaving the value inert. Expiry now produces the timeout error buffer described above.

## [1.4.4] 2025-09-10
### Added
* Project root management for file searching operations:
  * New command `:HttpSetProjectRoot [path]` to set the project root for file searching
  * New command `:HttpGetProjectRoot` to display the current project root
  * New command `:HttpDebugEnv` to debug environment and project root settings
  * New keybindings: `<leader>hg` to set project root, `<leader>hgg` to get project root
  * Enhanced `find_files` function to accept optional project root parameter
  * Automatic fallback to current directory when no project root is set
  * Relative path handling for environment files using project root
* Custom User-Agent header support:
  * Automatic User-Agent header (`heilgar/nvim-http-client`) added to all requests
  * Configurable via `user_agent` option in setup 
  * Only added if no User-Agent header is explicitly set in the request
* Enhanced response handler features:
  * Added `response.headers.valueOf(headerName)` method for case-insensitive header lookup
  * Improved header parsing to handle different formats from plenary.curl
  * Better header object creation with support for both array and key-value formats

### Fixed
* Fixed keybinding typo in configuration (corrected `<header>hs` to `<leader>hs`)
* Improved health check initialization to properly load configuration
* Enhanced environment file path handling for relative paths

## [1.4.3] 2025-04-26
### Added
* Automatic file extension detection when saving responses:
  * .json for JSON, .csv for CSV, .xml for XML, .html for HTML, .txt as fallback
* Prettified buffer display for JSON, XML
* New command :HttpResponseTab to open the latest response buffer in a new tab
* Content-Type detection improved: text/csv and application/csv are now recognized as CSV

### Fixed
* Always sanitize and re-encode JSON responses to guarantee valid JSON output (for jq/jmespath/json path compatibility)
* Fixed plugin to avoid Neovim fast event context errors by using pure Lua list detection

### Improved
* Save dialog now suggests the correct file extension based on response type
* General robustness for malformed or double-encoded JSON from APIs

## [1.4.2] 2025-04-08
### Fixed
* Fixed bug where `:HttpEnvFile` would give error saying config is nil.

## [1.4.1] 2025-04-05
### Improved
* Context-aware Autocompletion System
  * Fixed headers autocompletion in request bodies - no longer suggesting headers in the body section
  * Improved script block detection for better completions in response handler scripts
  * Added enhanced context detection to provide appropriate suggestions based on cursor position
  * Added script-specific suggestions in response handler blocks (client.global.set, response.body, etc.)
  * Maintained environment variable {{...}} completion in request bodies while disabling header suggestions
  * Improved request body detection to properly recognize body sections

## [1.4.0] 2025-04-04
### Added
* Intelligent Autocompletion System
  * Environment variable completion with `{{` trigger
  * HTTP method completion at the start of requests
  * HTTP header name completion with documentation
  * Content type suggestions for Content-Type and Accept headers
  * Adaptive filtering for better matching as you type
  * Robust support for nvim-cmp
  * Fallback completion for vanilla Neovim
  * Caching system for recently used variables
  * Context-aware completion based on cursor position

## [1.3.0] 2025-04-03
### Added
* Request Profiling Capabilities
  * Detailed timing metrics for HTTP requests
  * DNS resolution, connection, TLS handshake, and transfer time tracking
  * Configurable display in response window
  * Toggle profiling with `:HttpProfiling` command
  * New keybinding: `<leader>hp` to toggle profiling
  * Configuration options:
    * `profiling.enabled` - Enable/disable profiling (default: true)
    * `profiling.show_in_response` - Show metrics in response (default: true)
    * `profiling.detailed_metrics` - Show detailed breakdown (default: true)

## [1.2.2] 2025-26-01
### Fixed
* Improved JSON response formatting
  * Fixed display of null values in JSON responses
  * Added proper handling of vim.NIL to null conversion

## [1.2.1] 2025-07-01
### Added

* Global response state management system
  * Persistent response caching using `_G._http_client_state`
  * Response history with configurable size limit

* Enhanced file operations
  * New `write_file` utility function with error handling
  * Automatic directory creation for saves
  * Cross-platform path handling using Plenary

* Improved URL handling
  * Enhanced URL encoding for complex query parameters
  * Tested handling for Salesforce SOQL queries
  * Comprehensive character escaping

* Response saving features
  * New command `:HttpSaveResponse` for formatted response
  * Content-type based file extension detection
  * Keybindings:
    * `<leader>hs` - Save formatted response


## [1.2.0] 2024-12-30
### Added
- Resopnse window management
    - New tab-based interface for resopnse history
    - Timestamp-based tab naming
    - Navigation between response with H/L keys
    - Maximum 10 most recent responses preserved
### Changed
- Response display now uses a single split window
    - All responses appear in the same window as tabs
    - Improved window management and cleanup
    - Better response history organization

- Optimized buffer management for response history
- Enhanced navigation between response tabs

### Improved
- Response window behavior and consistency
- Buffer cleanup and management
- Tab navigation user experience

## [1.1.1] 2024-12-10
### Changed
- Added `create_keybindings` option to control creation of default keybindings
- Modified plugin initialization to prevent automatic setup with defaults
- Default keybindings are now configurable and can be disabled completely
- Fixed plugin setup to properly handle user configurations

## [1.1.0] 2024-09-17
### Added
- New feature: Generate and display curl command in dry run output
- New command: `:HttpCopyCurl` to copy curl command for the request under cursor
- New keybinding: `<leader>hc` to copy curl command
- Support for comments in .http and .rest files
    - Full line comments starting with '#'
    - Inline comments from '#' to end of line


## [1.0.0] 2024-09-17
### Added
- Comprehensive test suite
    - Test created for parser, utils, init, config and health
- Command to run tests
- Workflow to run tests
### Updated
- CONTRIBUTING.md

## [1.0.0] 2024-09-16
### New Features
- Initial support for response handler scripts
  - Ability to execute `client.global.set(k, v)`
  - Set global variables based on response data
- Global variables functionality
  - Set and use variables that persist across requests within a session
  - Global variables take precedence over environment variables
- New command `:HttpRunAll` to run all requests in the current file
### Changes
- Updated request execution to work without selecting an environment file
- Improved dry run functionality to execute even when no environment file is selected
### Improvements
- Added warning message when environment variables are needed but not set
### Code Improvements
- Refactored command structure for better organization:
  - Split commands into separate files: `request.lua`, `select_env.lua`
  - Created a new `commands/init.lua` to manage command modules
- Updated `init.lua` to use the new command structure

## [1.0.0] - 2024-09-13
### New Features
- Added support for private environment files (.private.env.json)
  - Private environment files are now automatically detected and loaded
  - Private environments take precedence over public environments
- Implemented HTTP version support
  - Added ability to specify HTTP/1.1 and HTTP/2 in requests
  - HTTP/2 (Prior Knowledge) support added for servers that can handle HTTP/2 connections without upgrades
- Introduced SSL configuration options
  - Added ability to disable certificate verification for development environments
### Changes
- Updated environment handling mechanism
  - Improved merging of public and private environments
  - Default environments are now applied before specific environments
  - Private default environments override public default environments
- Modified HTTP request parsing to handle requests with and without explicit HTTP versions
### File Handling
- Modified file selection process to exclude private environment files from the overview
- Private environment file names now match their public counterparts
  - Example: .env.json -> .private.env.json
  - Example: http-client.env.json -> http-client.private.env.json
### Code Improvements
- Refactored environment.lua for better handling of public and private environment files
- Updated set_env_file function to set both current_env_file and current_private_env_file
- Modified set_env function to properly merge environments from both public and private files
- Added get_current_private_env_file function to retrieve the current private environment file path
- Refactored parser.lua to correctly handle HTTP version in request parsing
- Updated http_client.lua to support different HTTP versions and SSL configurations
### Code Restructuring
- Reorganized project structure for improved maintainability
  - Created `core` directory for main plugin logic
    - Moved `parser.lua`, `http_client.lua`, and `environment.lua` into `core`
  - Created `utils` directory for utility functions
    - Moved `file_utils.lua` and `verbose.lua` into `utils`
  - Created `ui` directory for user interface related code
    - Renamed `ui.lua` to `display.lua` and moved it to `ui`
    - Moved `dry_run.lua` into `ui`
  - Created new `config.lua` file for centralized configuration management
- Updated import statements across the project to reflect new file structure
- Improved modularity and logical grouping of related functionalities
### Security
- Improved handling of sensitive information by separating it into private environment files
- Private environment files are automatically excluded from git tracking (ensure .gitignore is updated)
- Added option to disable SSL certificate verification for trusted development environments
### User Interface
- Updated Telescope integration to show merged environment preview (public + private)
- Added dry run support for HTTP version display
### Documentation
- Updated documentation to include information on HTTP version support and SSL configuration options
### Note to Users
- Ensure your .gitignore includes *.private.env.json to prevent accidental commits of sensitive data
- To use private environments, create a .private.env.json file alongside your existing .env.json file
- When using self-signed certificates in development, you can now disable certificate verification in your environment configuration

## [1.0.0]

### Added
- HTTP Request Parsing and Execution
  - Parse HTTP requests from .http files
  - Support for GET, POST, PUT, DELETE, PATCH, HEAD, and OPTIONS methods
  - Handle headers and request bodies
  - Execute requests using plenary.curl
- Environment Management
  - Support for multiple environments using .env.json files
  - Ability to switch between environments
  - Variable substitution in requests using {{variable}} syntax
- Response Handling
  - Display responses in a separate buffer
  - Format JSON and XML responses for better readability
  - Syntax highlighting for response content
- User Interface
  - Custom syntax highlighting for .http files
  - Custom syntax highlighting for response buffers
  - Split window configuration for displaying responses
- Commands
  - `:HttpEnvFile` - Select an environment file
  - `:HttpEnv` - Select an environment from the current file
  - `:HttpRun` - Execute the request under the cursor
  - `:HttpStop` - Stop the currently running request
  - `:HttpVerbose` - Toggle verbose mode for debugging
  - `:HttpDryRun` - Perform a dry run of the request without sending it
- Keybindings
  - Customizable keybindings for all major actions
  - Default keybindings provided out of the box
- Telescope Integration
  - Custom pickers for selecting environment files and environments
  - Preview window for environment contents
- Configuration
  - Customizable options for default environment file, request timeout, and split direction
  - Easy setup function for plugin configuration
- Debugging and Verbosity
  - Verbose mode for detailed logging of request and response information
  - Health checks to ensure proper plugin setup and dependencies
- Documentation
  - Help documentation accessible via `:help http_client`
  - Automatic generation of help tags

### Notes
- The plugin requires Neovim 0.5 or later
- Dependencies: plenary.nvim, telescope.nvim (optional for enhanced environment selection)
1
