-- Logic behind the `hyprplace` CLI tools.
--
-- The row builders are pure functions over a window list, so they are unit-testable
-- without a compositor. Only `load_windows` talks to the outside world, and it only
-- ever *reads*: these tools never dispatch, never mutate the compositor, and only
-- `db`/`plan` even open the state file.

local DB        = require("hyprplace.db")
local Identity  = require("hyprplace.identity")
local Json      = require("hyprplace.json")
local Placement = require("hyprplace.placement")
local Policy    = require("hyprplace.policy")

local M = {}

-- ---------------------------------------------------------------- reading the compositor

--- Build the read-only hyprctl command for the target instance.
---@param opts table  { instance?: string, runtime?: string }
---@return string
function M.hyprctl_cmd(opts, args)
    local prefix = ""
    if opts.runtime then
        prefix = string.format("XDG_RUNTIME_DIR=%q ", opts.runtime)
    end
    local inst = opts.instance and string.format(" -i %q", opts.instance) or ""
    return string.format("%shyprctl%s -j %s", prefix, inst, args)
end

--- Fetch live windows, shaped like the `hl` window objects the plugin sees.
---@param opts table
---@return table[]|nil windows, string|nil err
function M.load_windows(opts)
    local cmd = M.hyprctl_cmd(opts or {}, "clients")
    local pipe = io.popen(cmd, "r")
    if not pipe then
        return nil, "could not run: " .. cmd
    end
    local out = pipe:read("a")
    pipe:close()

    local clients, err = Json.decode(out)
    if not clients then
        return nil, "could not parse hyprctl output: " .. tostring(err)
    end

    local windows = {}
    for _, c in ipairs(clients) do
        windows[#windows + 1] = {
            address       = c.address,
            class         = c.class,
            initial_class = c.initialClass,
            title         = c.title,
            pid           = c.pid,
            xwayland      = c.xwayland,
            floating      = c.floating,
            workspace     = c.workspace and { id = c.workspace.id, name = c.workspace.name } or nil,
        }
    end
    return windows
end

-- ------------------------------------------------------------------------ pure builders

--- What hyprplace would record for each currently-open window.
---
--- Reads no state and writes none: this answers "what does hyprplace *see*", not "what
--- does hyprplace know".
---@param windows table[]
---@param cfg table
---@return table[]
function M.fingerprint_rows(windows, cfg)
    local rows = {}
    for _, w in ipairs(windows) do
        local tracked, reason = Policy.decide(w, windows, cfg)
        local key, tier = Identity.key_for(w, windows, cfg)
        rows[#rows + 1] = {
            address = w.address,
            class   = Policy.class_of(w) or "(none)",
            title   = w.title,
            pid     = w.pid,
            ws      = w.workspace and w.workspace.id,
            tracked = tracked,
            reason  = reason,
            key     = key,
            tier    = tier,
            -- What a close right now would write.
            would_record = tracked and key and w.workspace and w.workspace.id or nil,
        }
    end
    return rows
end

--- Where each currently-open window would be placed if it opened right now.
---@param windows table[]
---@param state table
---@param cfg table
---@return table[]
function M.plan_rows(windows, state, cfg)
    local rows = {}
    for _, w in ipairs(windows) do
        local tracked, reason = Policy.decide(w, windows, cfg)
        local key = Identity.key_for(w, windows, cfg)
        local row = {
            address = w.address,
            class   = Policy.class_of(w) or "(none)",
            ws      = w.workspace and w.workspace.id,
            key     = key,
            tracked = tracked,
        }
        if not tracked then
            row.outcome = "skip"
            row.detail  = Policy.EXPLAIN[reason] or reason
        else
            local entry = DB.lookup(state, key)
            if not entry then
                row.outcome = "skip"
                row.detail  = "no record for this key"
            else
                local counts = Placement.count_workspaces(
                    windows, key, w.address, function(o) return (Identity.key_for(o, windows, cfg)) end)
                local target = Placement.choose(entry, counts)
                row.remembered = entry.workspaces
                if not target then
                    row.outcome = "skip"
                    row.detail  = "every remembered slot is already filled"
                elseif row.ws == target then
                    row.outcome = "stay"
                    row.detail  = "already on workspace " .. tostring(target)
                    row.target  = target
                else
                    row.outcome = "move"
                    row.detail  = string.format("workspace %s -> %d", tostring(row.ws), target)
                    row.target  = target
                end
            end
        end
        rows[#rows + 1] = row
    end
    return rows
end

--- Current DB contents, newest first, with age and expiry.
---@param state table
---@param cfg table
---@param now integer
---@return table[]
function M.db_rows(state, cfg, now)
    local rows = {}
    for key, e in pairs(state.entries or {}) do
        local age_days = (now - (e.seen or 0)) / 86400
        rows[#rows + 1] = {
            key        = key,
            workspaces = e.workspaces or {},
            seen       = e.seen,
            age_days   = age_days,
            expires_in = cfg.ttl_days > 0 and (cfg.ttl_days - age_days) or nil,
        }
    end
    table.sort(rows, function(a, b) return (a.seen or 0) > (b.seen or 0) end)
    return rows
end

-- ------------------------------------------------------------------------- presentation

--- A key contains a NUL between class and cmdline; render it readably.
---@param key string|nil
---@return string
function M.show_key(key)
    if not key then
        return "(none)"
    end
    return (key:gsub("%z", " + "))
end

return M
