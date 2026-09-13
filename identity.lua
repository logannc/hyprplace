-- Window identity: turning a live window into a stable cross-session key.
--
-- No stable id survives a close (`address` and `stable_id` die with the window, `pid`
-- dies with the reboot), so the key is a fingerprint, layered most-specific first:
--
--   1. class + normalized cmdline -- only when the pid maps to exactly one window,
--      because Firefox and Electron serve many windows from one process.
--   2. class alone.
--
-- See docs/DESIGN.required.md.

local M = {}

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
---@param argv string[]|nil
---@return string|nil
function M.normalize_cmdline(argv)
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

    if #out <= 1 then
        -- Bare binary only: `kitty` tells us nothing `class` did not.
        return nil
    end
    return table.concat(out, " ")
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
---@return string|nil key, string tier
function M.key_for(w, windows)
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

    if w.pid and M.pid_window_count(windows, w.pid) == 1 then
        local cmd = M.normalize_cmdline(M.read_cmdline(w.pid))
        if cmd then
            return class .. "\0" .. cmd, "cmdline"
        end
    end

    return class, "class"
end

--- Does this window have a distinguishing cmdline? Used by `require_cmdline`.
---@param w table
---@param windows table[]
---@return boolean
function M.has_cmdline_identity(w, windows)
    local _, tier = M.key_for(w, windows)
    return tier == "cmdline"
end

return M
