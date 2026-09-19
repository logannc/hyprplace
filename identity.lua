-- Window identity: turning a live window into a stable cross-session key.
--
-- No stable id survives a close (`address` and `stable_id` die with the window, `pid`
-- dies with the reboot), so the key is a fingerprint, layered most-specific first:
--
--   0. class + published tag -- an identity the application itself declares.
--   1. class + normalized cmdline -- only when the pid maps to exactly one window,
--      because Firefox and Electron serve many windows from one process.
--   2. class alone.
--
-- Tier 0 works where tier 1 structurally cannot. Nine Firefox windows share one pid, so
-- no amount of cmdline parsing can tell them apart; a tag is per window by
-- construction. It is also the only tier that is not a heuristic -- the others infer
-- identity from things the app set for its own reasons, while a tag is published
-- deliberately for this. See docs/FIREFOX-TAGS.md.
--
-- See docs/DESIGN.required.md.

local Tag = require("hyprplace.tag")

local M = {}

--- Marks the tag portion of a key, so a tag can never be confused with a cmdline that
--- happens to look like one. Renders readably in the tools: `firefox + tag:f533cc25`.
M.TAG_PREFIX = "tag:"

-- Command wrappers that carry no identity: strip them to reach the real argv.
local WRAPPERS = {
    ["uwsm"] = true,
    ["app"] = true,
    ["env"] = true,
    ["nohup"] = true,
    ["setsid"] = true,
}

--- Read and split /proc/<pid>/cmdline. Replaceable in tests.
---@param pid integer
---@return string[]|nil
function M.read_cmdline(pid)
    if not pid or pid <= 0 then
        return nil
    end
    local f = io.open("/proc/" .. tostring(pid) .. "/cmdline", "rb")
    if not f then
        return nil
    end
    local raw = f:read("a")
    f:close()
    if not raw or raw == "" then
        return nil
    end
    local argv = {}
    for part in raw:gmatch("([^%z]+)") do
        argv[#argv + 1] = part
    end
    return argv
end

--- Reduce an argv to a stable identity string, or nil if it says nothing useful.
---
--- Strips wrapper commands (`uwsm app -- kitty btop` -> `kitty btop`), VAR=value
--- prefixes, and leading directories. Returns nil when only the bare binary remains,
--- since that adds nothing over the class.
---
--- Flags are dropped unless allowlisted for that binary by `cfg.keep_flags`. This is
--- the difference between a usable fingerprint and a useless one: Steam's argv is 800+
--- characters and carries `-steampid=`, `-buildid=` and `-startcount=`, all of which
--- change every launch. Dropping flags leaves the stable `steamwebhelper`.
---@param argv string[]|nil
---@param cfg table|nil
---@return string|nil
function M.normalize_cmdline(argv, cfg)
    if not argv or #argv == 0 then
        return nil
    end

    local out = {}
    local skipping = true
    for _, arg in ipairs(argv) do
        if skipping then
            local base = arg:match("([^/]+)$") or arg
            if arg == "--" or arg:match("^[%w_]+=") or WRAPPERS[base] then
                -- wrapper noise; keep skipping
            else
                skipping = false
                out[#out + 1] = base
            end
        else
            out[#out + 1] = arg
        end
    end

    if #out == 0 then
        return nil
    end

    local binary = out[1]
    local allow = cfg and cfg.keep_flags and cfg.keep_flags[binary]
    local kept = { binary }
    for n = 2, #out do
        local tok = out[n]
        if tok:sub(1, 1) ~= "-" then
            kept[#kept + 1] = tok
        elseif allow then
            for _, pat in ipairs(allow) do
                if tok:match(pat) then
                    kept[#kept + 1] = tok
                    break
                end
            end
        end
    end

    if #kept <= 1 then
        -- Bare binary only: `kitty` tells us nothing `class` did not.
        return nil
    end

    local joined = table.concat(kept, " ")
    local cap = cfg and cfg.max_cmdline_len
    if cap and cap > 0 and #joined > cap then
        joined = joined:sub(1, cap)
    end
    return joined
end

--- How many of `windows` share this pid?
---@param windows table[]
---@param pid integer
---@return integer
function M.pid_window_count(windows, pid)
    local n = 0
    for _, w in ipairs(windows or {}) do
        if w.pid == pid then
            n = n + 1
        end
    end
    return n
end

--- Derive the identity key for a window.
---
--- `windows` is the current window list, used to decide whether this window's pid is
--- unique enough for its cmdline to be meaningful.
---@param w table
---@param windows table[]
---@param cfg table|nil
---@return string|nil key, string tier
function M.key_for(w, windows, cfg)
    if not w then
        return nil, "none"
    end
    local class = w.class
    if not class or class == "" then
        class = w.initial_class
    end
    if not class or class == "" then
        return nil, "none"
    end

    -- Tier 0, before anything is inferred. Also spares the /proc read below, which is
    -- blocking I/O in the compositor's hot path.
    local tag = Tag.of(w.title)
    if tag then
        return class .. "\0" .. M.TAG_PREFIX .. tag, "tag"
    end

    if w.pid and M.pid_window_count(windows, w.pid) == 1 then
        local cmd = M.normalize_cmdline(M.read_cmdline(w.pid), cfg)
        if cmd then
            return class .. "\0" .. cmd, "cmdline"
        end
    end

    return class, "class"
end

--- A key as a human should read it.
---
--- Keys join their parts with NUL, which is invisible in a terminal: an unrendered
--- `org.kde.dolphin\0dolphin /home/logan` reads as `org.kde.dolphindolphin /home/logan`,
--- which looks like a parsing bug that is not there. Lives here rather than in the CLI
--- because the plugin logs keys too, and the two must render them the same way.
---@param key string|nil
---@return string
function M.render(key)
    if not key or key == "" then
        return "(none)"
    end
    return (key:gsub("%z", " + "))
end

--- Does this window have an identity of its own, beyond its class?
---
--- Used by `require_cmdline`, whose name predates tags: the question it is really
--- asking is "is this window distinguishable from every other window of its class", and
--- a tag answers that better than a cmdline does. A tagged terminal is a specific
--- terminal even if it was launched bare.
---@param w table
---@param windows table[]
---@param cfg table|nil
---@return boolean
function M.has_specific_identity(w, windows, cfg)
    local _, tier = M.key_for(w, windows, cfg)
    return tier == "tag" or tier == "cmdline"
end

-- Previous name, kept so nothing outside this module breaks on the rename.
M.has_cmdline_identity = M.has_specific_identity

return M
