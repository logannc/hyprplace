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

--- The distribution of live windows per identity key, sorted, duplicates kept.
---@param windows table[]
---@param cfg table
---@return table<string, integer[]>
function M.live_distribution(windows, cfg)
    local dist = {}
    for _, w in ipairs(windows) do
        if Policy.decide(w, windows, cfg) and w.workspace and w.workspace.id then
            local key = Identity.key_for(w, windows, cfg)
            if key then
                dist[key] = dist[key] or {}
                table.insert(dist[key], w.workspace.id)
            end
        end
    end
    for _, list in pairs(dist) do
        table.sort(list)
    end
    return dist
end

local function same_list(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

--- Where the learned state and the current layout disagree.
---
--- Status is one of:
---   match      remembered and live distributions are identical
---   differs    the app is running somewhere other than remembered
---   unlearned  running, but nothing recorded for it yet
---   absent     recorded, but not currently running
---@param windows table[]
---@param state table
---@param cfg table
---@return table[]
function M.diff_rows(windows, state, cfg)
    local live = M.live_distribution(windows, cfg)
    local rows, seen = {}, {}

    for key, actual in pairs(live) do
        seen[key] = true
        local entry = state.entries[key]
        local remembered = entry and entry.workspaces or nil
        local status
        if not remembered then
            status = "unlearned"
        elseif same_list(remembered, actual) then
            status = "match"
        else
            status = "differs"
        end
        rows[#rows + 1] = { key = key, status = status, remembered = remembered, actual = actual }
    end

    for key, entry in pairs(state.entries or {}) do
        if not seen[key] then
            rows[#rows + 1] = { key = key, status = "absent", remembered = entry.workspaces, actual = {} }
        end
    end

    local ORDER = { differs = 1, unlearned = 2, absent = 3, match = 4 }
    table.sort(rows, function(a, b)
        if ORDER[a.status] ~= ORDER[b.status] then
            return ORDER[a.status] < ORDER[b.status]
        end
        return a.key < b.key
    end)
    return rows
end

--- Entries the TTL would drop right now.
---@param state table
---@param cfg table
---@param now integer
---@return table[]
function M.expired_rows(state, cfg, now)
    local out = {}
    if not cfg.ttl_days or cfg.ttl_days <= 0 then
        return out
    end
    for _, row in ipairs(M.db_rows(state, cfg, now)) do
        if row.age_days >= cfg.ttl_days then
            out[#out + 1] = row
        end
    end
    return out
end

--- What changed between two window snapshots, keyed by address.
---@param before table[]|nil
---@param after table[]
---@return table  { appeared = {}, vanished = {}, moved = {} }
function M.window_delta(before, after)
    local delta = { appeared = {}, vanished = {}, moved = {} }
    local prev = {}
    for _, w in ipairs(before or {}) do
        prev[w.address] = w
    end
    local now_by_addr = {}
    for _, w in ipairs(after) do
        now_by_addr[w.address] = w
        local was = prev[w.address]
        if not was then
            if before then
                delta.appeared[#delta.appeared + 1] = w
            end
        else
            local a = was.workspace and was.workspace.id
            local b = w.workspace and w.workspace.id
            if a ~= b then
                delta.moved[#delta.moved + 1] = { window = w, from = a, to = b }
            end
        end
    end
    for addr, w in pairs(prev) do
        if not now_by_addr[addr] then
            delta.vanished[#delta.vanished + 1] = w
        end
    end
    return delta
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
