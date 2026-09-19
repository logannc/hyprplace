#!/usr/bin/env lua
-- hyprplace installer.
--
-- Three separable concerns, each individually skippable:
--   plugin   Lua modules into the Hyprland config tree
--   config   a require() block in hyprland.lua, delimited by markers
--   bin      a wrapper putting the CLI on PATH
--
-- Idempotent: re-running converges rather than duplicating. Reversible: `uninstall`
-- removes exactly what was added, and nothing it did not add. Learned state is user
-- data and survives uninstall unless --purge is given.
--
-- Written in Lua rather than shell because the delicate part -- editing hyprland.lua --
-- is string manipulation, and that logic lives in installer.lua where it is unit
-- tested. Only the filesystem primitives shell out.

local ROOT = (debug.getinfo(1, "S").source:sub(2)):match("^(.*)/[^/]*$") or "."
local Installer = dofile(ROOT .. "/installer.lua")

local q = Installer.shell_quote

-- ----------------------------------------------------------------- filesystem helpers

local function exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end

local function write(path, text)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(text)
    f:close()
    return true
end

local function same(a, b)
    local x, y = read(a), read(b)
    return x ~= nil and x == y
end

-- ------------------------------------------------------------------------------- opts

local opts = {
    config_dir = os.getenv("HYPRPLACE_CONFIG_DIR")
        or ((os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/hypr"),
    bin_dir = os.getenv("HYPRPLACE_BIN_DIR") or (os.getenv("HOME") .. "/.local/bin"),
    state_dir = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/hyprplace",
    plugin = true, config = true, bin = true,
    dry_run = false, purge = false,
}

local function usage()
    io.write([[
usage: install.lua <install|uninstall|status> [options]

  install     copy modules, wire up the config, install the CLI wrapper
  uninstall   undo all three. Learned state is kept unless --purge
  status      report what is installed and whether it matches this checkout

options:
  --dry-run          print what would change, touch nothing
  --no-plugin        skip the Lua modules
  --no-config        skip editing hyprland.lua
  --no-bin           skip the CLI wrapper
  --purge            uninstall only: also delete learned state
  --config-dir DIR   Hyprland config dir
  --bin-dir DIR      where the CLI wrapper goes

Editing hyprland.lua is delimited by markers and backed up first. Your own
settings go between the inner markers and are preserved when this re-runs.
To wire it yourself instead, pass --no-config and add:

]] .. Installer.block() .. "\n\n")
end

local cmd
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "install" or a == "uninstall" or a == "status" then cmd = a
        elseif a == "--dry-run"    then opts.dry_run = true
        elseif a == "--no-plugin"  then opts.plugin = false
        elseif a == "--no-config"  then opts.config = false
        elseif a == "--no-bin"     then opts.bin = false
        elseif a == "--purge"      then opts.purge = true
        elseif a == "--config-dir" then i = i + 1; opts.config_dir = arg[i]
        elseif a == "--bin-dir"    then i = i + 1; opts.bin_dir = arg[i]
        elseif a == "-h" or a == "--help" then usage(); os.exit(0)
        else io.stderr:write("unknown argument: " .. a .. "\n"); usage(); os.exit(2)
        end
        i = i + 1
    end
end

local PLUGIN_DIR = opts.config_dir .. "/hyprplace"
local ENTRY      = opts.config_dir .. "/hyprland.lua"
local WRAPPER    = opts.bin_dir .. "/hyprplace"
local CLI_TARGET = PLUGIN_DIR .. "/bin/hyprplace"

local failures = 0
local function head(s) io.write("\n" .. s .. "\n") end
local function refuse(why)
    failures = failures + 1
    io.write("  REFUSING: " .. why .. "\n")
end
local function say(s)  io.write("  " .. s .. "\n") end

--- " (3 lines of config)" / " (no config yet)", for status lines.
---@param config string[]|nil
---@return string
local function describe_config(config)
    if not config then
        return " (no config section -- re-run install to add one)"
    end
    local n = 0
    for _, line in ipairs(config) do
        if not line:match("^%s*$") and not line:match("^%s*%-%-") then
            n = n + 1
        end
    end
    if n == 0 then
        return " (no settings set)"
    end
    return string.format(" (%d line%s of config)", n, n == 1 and "" or "s")
end

local function act(description, fn)
    if opts.dry_run then
        say("would: " .. description)
        return true
    end
    return fn()
end

local function mkdirp(path)
    return act("mkdir -p " .. path, function()
        return os.execute("mkdir -p " .. q(path)) and true or false
    end)
end

-- ---------------------------------------------------------------------------- install

local function install_plugin()
    head("plugin  " .. PLUGIN_DIR)
    mkdirp(PLUGIN_DIR)
    mkdirp(PLUGIN_DIR .. "/bin")
    local changed = 0
    for _, m in ipairs(Installer.MODULES) do
        local src, dst = ROOT .. "/" .. m, PLUGIN_DIR .. "/" .. m
        if not same(src, dst) then
            changed = changed + 1
            act("copy " .. src .. " -> " .. dst, function() return write(dst, read(src)) end)
        end
    end
    act("copy " .. ROOT .. "/bin/hyprplace -> " .. CLI_TARGET, function()
        write(CLI_TARGET, read(ROOT .. "/bin/hyprplace"))
        return os.execute("chmod +x " .. q(CLI_TARGET)) and true or false
    end)
    say(string.format("%d modules, %d changed", #Installer.MODULES, changed))
end

local function install_config()
    head("config  " .. ENTRY)
    if not exists(ENTRY) then
        say("NOT FOUND -- create it, or wire hyprplace in yourself:")
        for _, line in ipairs(Installer.split_lines(Installer.block())) do
            say("    " .. line)
        end
        return
    end
    local text = read(ENTRY)
    local updated, changed, err = Installer.upsert_block(text)
    if err then
        refuse(err)
        say("fix " .. ENTRY .. " by hand, or re-run with --no-config")
        return
    end

    -- Check the file as it stands, not just what we are about to write. A config
    -- section edited since the last install is the common case, and if it does not
    -- parse there is nothing for us to change -- so the unchanged path is exactly
    -- where a broken config would otherwise slip through unmentioned.
    local intact, ierr = Installer.validate(text)
    if not intact then
        refuse(ENTRY .. " does not parse as Lua -- " .. tostring(ierr))
        say("fix it before reloading Hyprland; the session will not come up as it is")
        return
    end

    local existing = Installer.config_of(text)
    if not changed then
        say("already wired, unchanged" .. describe_config(existing))
        return
    end

    -- Never write a config the compositor cannot parse: that surfaces as a session
    -- that will not come up, long after this command has exited.
    local parses, perr = Installer.validate(updated)
    if not parses then
        refuse("the result would not parse as Lua -- " .. tostring(perr))
        say("nothing was written")
        return
    end

    local backup = ENTRY .. ".hyprplace-backup"
    act("back up to " .. backup, function() return write(backup, text) end)
    act(Installer.has_block(text) and "update the hyprplace block"
        or "append the hyprplace block",
        function() return write(ENTRY, updated) end)
    if existing then
        say("kept your config section" .. describe_config(existing))
    end
    if not opts.dry_run then
        say("backup: " .. backup)
    end
end

local function install_bin()
    head("bin     " .. WRAPPER)
    mkdirp(opts.bin_dir)
    -- A generated wrapper, not a symlink: the CLI finds its modules relative to its own
    -- path, and through a symlink that resolves to the link's directory -- so the tools
    -- would load the repo's modules while the compositor ran the installed ones.
    local wrapper = table.concat({
        "#!/usr/bin/env bash",
        "# generated by hyprplace install.lua -- do not edit",
        'exec lua "' .. CLI_TARGET .. '" "$@"',
        "",
    }, "\n")
    act("write wrapper exec-ing " .. CLI_TARGET, function()
        write(WRAPPER, wrapper)
        return os.execute("chmod +x " .. q(WRAPPER)) and true or false
    end)
    local path = os.getenv("PATH") or ""
    if not (":" .. path .. ":"):find(":" .. opts.bin_dir .. ":", 1, true) then
        say("note: " .. opts.bin_dir .. " is not on your PATH")
    end
end

-- -------------------------------------------------------------------------- uninstall

local function uninstall_config()
    head("config  " .. ENTRY)
    if not exists(ENTRY) then say("not found") return end
    local text = read(ENTRY)
    if not Installer.has_block(text) then say("no hyprplace block present") return end
    local stripped = Installer.remove_block(text)
    local parses, perr = Installer.validate(stripped)
    if not parses then
        refuse("removing the block would leave a file that does not parse -- "
            .. tostring(perr))
        say("nothing was written")
        return
    end
    local backup = ENTRY .. ".hyprplace-backup"
    act("back up to " .. backup, function() return write(backup, text) end)
    act("remove the hyprplace block", function() return write(ENTRY, stripped) end)
    local existing = Installer.config_of(text)
    if existing and #existing > 0 then
        say("your settings went with it; they are in the backup")
    end
    if not opts.dry_run then
        say("backup: " .. backup)
    end
end

local function uninstall_plugin()
    head("plugin  " .. PLUGIN_DIR)
    if not exists(PLUGIN_DIR .. "/init.lua") then
        say(exists(PLUGIN_DIR) and "REFUSING: does not look like a hyprplace install" or "not installed")
        return
    end
    act("rm -rf " .. PLUGIN_DIR, function()
        return os.execute("rm -rf " .. q(PLUGIN_DIR)) and true or false
    end)
    say("removed")
end

local function uninstall_bin()
    head("bin     " .. WRAPPER)
    if not exists(WRAPPER) then say("not installed") return end
    local text = read(WRAPPER) or ""
    if not text:find("generated by hyprplace install.lua", 1, true) then
        say("REFUSING: not generated by this installer")
        return
    end
    act("rm " .. WRAPPER, function() return os.remove(WRAPPER) and true or false end)
    say("removed")
end

local function handle_state()
    head("state   " .. opts.state_dir)

    -- The config cache is generated by the plugin, not user data, and is meaningless
    -- once the plugin is gone. Removed either way; the learned state is not.
    local cache = opts.state_dir .. "/config.lua"
    if exists(cache) and not opts.purge then
        act("rm " .. cache .. " (generated config cache)",
            function() return os.remove(cache) and true or false end)
    end

    if not exists(opts.state_dir .. "/db.lua") then say("no learned state") return end
    if not opts.purge then
        say("learned state kept (pass --purge to delete)")
        return
    end
    act("rm -rf " .. opts.state_dir, function()
        return os.execute("rm -rf " .. q(opts.state_dir)) and true or false
    end)
    say("purged")
end

-- ----------------------------------------------------------------------------- status

local function status()
    head("plugin  " .. PLUGIN_DIR)
    if not exists(PLUGIN_DIR) then
        say("not installed")
    else
        local stale, missing = 0, 0
        for _, m in ipairs(Installer.MODULES) do
            local dst = PLUGIN_DIR .. "/" .. m
            if not exists(dst) then missing = missing + 1
            elseif not same(ROOT .. "/" .. m, dst) then stale = stale + 1 end
        end
        if stale == 0 and missing == 0 then
            say("installed, matches this checkout")
        else
            say(string.format("installed, but %d differ and %d missing -- re-run install", stale, missing))
        end
    end

    head("config  " .. ENTRY)
    if not exists(ENTRY) then
        say("not found")
    else
        local text = read(ENTRY)
        local found, err = Installer.locate(text)
        if err then say("DAMAGED: " .. err)
        elseif not found then say("not wired")
        else say("wired" .. describe_config(found.config)) end
        local parses, perr = Installer.validate(text)
        if not parses then say("DOES NOT PARSE: " .. tostring(perr)) end
    end

    head("bin     " .. WRAPPER)
    if not exists(WRAPPER) then say("not installed")
    elseif (read(WRAPPER) or ""):find("generated by hyprplace install.lua", 1, true) then say("installed")
    else say("present, but not generated by this installer") end

    head("state   " .. opts.state_dir)
    local db = read(opts.state_dir .. "/db.lua")
    if not db then
        say("no state yet")
    else
        local n = select(2, db:gsub("%] = {", ""))
        say(n .. " entries")
    end
    -- Absent means the plugin has not loaded since it was installed, which is worth
    -- knowing: the CLI tools fall back to defaults and may not match its behaviour.
    if exists(opts.state_dir .. "/config.lua") then
        say("config cache present (the CLI reports the running config)")
    else
        say("no config cache -- the plugin has not loaded; the CLI will use defaults")
    end
    local log = opts.state_dir .. "/hyprplace.log"
    if exists(log) then
        say("log: " .. log)
    end
    io.write("\n")
end

-- ------------------------------------------------------------------------------- main

if cmd == "install" then
    if opts.dry_run then io.write("DRY RUN -- nothing will be changed\n") end
    if opts.plugin then install_plugin() end
    if opts.config then install_config() end
    if opts.bin then install_bin() end
    head("done")
    if failures > 0 then
        say("finished with " .. failures .. " refusal(s); see above")
    else
        say("reload Hyprland (hyprctl reload) to pick it up")
    end
    io.write("\n")
    os.exit(failures == 0 and 0 or 1)
elseif cmd == "uninstall" then
    if opts.dry_run then io.write("DRY RUN -- nothing will be changed\n") end
    if opts.config then uninstall_config() end
    if opts.plugin then uninstall_plugin() end
    if opts.bin then uninstall_bin() end
    handle_state()
    io.write("\n")
    os.exit(failures == 0 and 0 or 1)
elseif cmd == "status" then
    status()
else
    usage()
    os.exit(2)
end
