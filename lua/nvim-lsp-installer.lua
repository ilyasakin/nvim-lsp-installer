local fs = require "nvim-lsp-installer.fs"
local notify = require "nvim-lsp-installer.notify"
local dispatcher = require "nvim-lsp-installer.dispatcher"
local process = require "nvim-lsp-installer.process"
local status_win = require "nvim-lsp-installer.ui.status-win"
local servers = require "nvim-lsp-installer.servers"
local settings = require "nvim-lsp-installer.settings"
local log = require "nvim-lsp-installer.log"
local platform = require "nvim-lsp-installer.platform"
local language_autocomplete_map = require "nvim-lsp-installer._generated.language_autocomplete_map"

local M = {}

M.settings = settings.set

M.info_window = {
    ---Opens the status window.
    open = function()
        status_win().open()
    end,
    ---Closes the status window.
    close = function()
        status_win().close()
    end,
}

---Deprecated. Use info_window.open().
function M.display()
    notify(
        "The lsp_installer.display() function has been deprecated. Use lsp_installer.info_window.open() instead.",
        vim.log.levels.WARN
    )
    status_win().open()
end

function M.get_install_completion()
    local result = {}
    local server_names = servers.get_available_server_names()
    vim.list_extend(result, server_names)
    vim.list_extend(result, vim.tbl_keys(language_autocomplete_map))
    return result
end

---Raises an error with the provided message. If in a headless environment,
---will also schedule an immediate shutdown with the provided exit code.
---@param msg string
---@param code number @The exit code to use when in headless mode.
local function raise_error(msg, code)
    if platform.is_headless then
        vim.schedule(function()
            -- We schedule the exit to make sure the call stack is exhausted
            os.exit(code or 1)
        end)
    end
    error(msg)
end

---Installs the provided servers synchronously (blocking call). It's recommended to only use this in headless environments.
---@param server_identifiers string[] @A list of server identifiers (for example {"rust_analyzer@nightly", "tsserver"}).
function M.install_sync(server_identifiers)
    local completed_servers = {}
    local failed_servers = {}
    local server_tuples = {}

    -- Collect all servers and exit early if unable to find one.
    for _, server_identifier in pairs(server_identifiers) do
        local server_name, version = servers.parse_server_identifier(server_identifier)
        local ok, server = servers.get_server(server_name)
        if not ok then
            raise_error(("Could not find server %q."):format(server_name))
        end
        table.insert(server_tuples, { server, version })
    end

    -- Start all installations.
    for _, server_tuple in ipairs(server_tuples) do
        local server, version = unpack(server_tuple)

        server:install_attached({
            stdio_sink = process.simple_sink(),
            requested_server_version = version,
        }, function(success)
            table.insert(completed_servers, server)
            if not success then
                table.insert(failed_servers, server)
            end
        end)
    end

    -- Poll for completion.
    if vim.wait(60000 * 15, function()
        return #completed_servers >= #server_identifiers
    end, 100) then
        if #failed_servers > 0 then
            for _, server in pairs(failed_servers) do
                log.fmt_error("Server %s failed to install.", server.name)
            end
            raise_error(("%d/%d servers failed to install."):format(#failed_servers, #completed_servers))
        end

        for _, server in pairs(completed_servers) do
            log.fmt_info("Server %s was successfully installed.", server.name)
        end
    end
end

---Unnstalls the provided servers synchronously (blocking call). It's recommended to only use this in headless environments.
---@param server_identifiers string[] @A list of server identifiers (for example {"rust_analyzer@nightly", "tsserver"}).
function M.uninstall_sync(server_identifiers)
    for _, server_identifier in pairs(server_identifiers) do
        local server_name = servers.parse_server_identifier(server_identifier)
        local ok, server = servers.get_server(server_name)
        if not ok then
            log.error(server)
            raise_error(("Could not find server %q."):format(server_name))
        end
        local uninstall_ok, uninstall_error = pcall(server.uninstall, server)
        if not uninstall_ok then
            log.error(tostring(uninstall_error))
            raise_error(("Failed to uninstall server %q."):format(server.name))
        end
        log.fmt_info("Successfully uninstalled server %s.", server.name)
    end
end

---@param server_identifier string
---@return string,string|nil
local function translate_language_alias(server_identifier, version)
    local language_aliases = language_autocomplete_map[server_identifier]
    if language_aliases then
        local choices = {}
        for idx, server_alias in ipairs(language_aliases) do
            table.insert(choices, ("&%d %s"):format(idx, server_alias))
        end
        local choice = vim.fn.confirm(
            ("The following servers were found for language %q, please select which one you want to install:"):format(
                server_identifier
            ),
            table.concat(choices, "\n"),
            0
        )
        return language_aliases[choice]
    end
    return server_identifier, version
end

--- Queues a server to be installed. Will also open the status window.
--- Use the .on_server_ready(cb) function to register a handler to be executed when a server is ready to be set up.
---@param server_identifier string @The server to install. This can also include a requested version, for example "rust_analyzer@nightly".
function M.install(server_identifier)
    local server_name, version = translate_language_alias(servers.parse_server_identifier(server_identifier))
    if not server_name then
        -- No selection was made
        return
    end
    local ok, server = servers.get_server(server_name)
    if not ok then
        return notify(("Unable to find LSP server %s.\n\n%s"):format(server_name, server), vim.log.levels.ERROR)
    end
    status_win().install_server(server, version)
    status_win().open()
end

--- Queues a server to be uninstalled. Will also open the status window.
---@param server_name string The server to uninstall.
function M.uninstall(server_name)
    local ok, server = servers.get_server(server_name)
    if not ok then
        return notify(("Unable to find LSP server %s.\n\n%s"):format(server_name, server), vim.log.levels.ERROR)
    end
    status_win().uninstall_server(server)
    status_win().open()
end

--- Queues all servers to be uninstalled. Will also open the status window.
function M.uninstall_all(no_confirm)
    if not no_confirm then
        local choice = vim.fn.confirm(
            ("This will uninstall all servers currently installed at %q. Continue?"):format(
                vim.fn.fnamemodify(settings.current.install_root_dir, ":~")
            ),
            "&Yes\n&No",
            2
        )
        if settings.current.install_root_dir ~= settings._DEFAULT_SETTINGS.install_root_dir then
            choice = vim.fn.confirm(
                (
                    "WARNING: You are using a non-default install_root_dir (%q). This command will delete the entire directory. Continue?"
                ):format(vim.fn.fnamemodify(settings.current.install_root_dir, ":~")),
                "&Yes\n&No",
                2
            )
        end

        if choice ~= 1 then
            print "Uninstalling all servers was aborted."
            return
        end
    end

    log.info "Uninstalling all servers."
    if fs.dir_exists(settings.current.install_root_dir) then
        local ok, err = pcall(fs.rmrf, settings.current.install_root_dir)
        if not ok then
            log.error(err)
            raise_error "Failed to uninstall all servers."
        end
    end
    log.info "Successfully uninstalled all servers."
    status_win().mark_all_servers_uninstalled()
    status_win().open()
end

---@param cb fun(server: Server) @Callback to be executed whenever a server is ready to be set up.
function M.on_server_ready(cb)
    dispatcher.register_server_ready_callback(cb)
    vim.schedule(function()
        local installed_servers = servers.get_installed_servers()
        for i = 1, #installed_servers do
            dispatcher.dispatch_server_ready(installed_servers[i])
        end
    end)
end

-- old API
M.get_server = servers.get_server
M.get_available_servers = servers.get_available_servers
M.get_installed_servers = servers.get_installed_servers
M.get_uninstalled_servers = servers.get_uninstalled_servers
M.register = servers.register

return M
