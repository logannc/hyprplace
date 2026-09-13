-- Persistence. The DB is a versioned Lua table, serialized by hand so there is no
-- JSON dependency and loaded with `load()` in an empty environment.
--
-- Shape:
--   { version = 1, entries = { [key] = { workspaces = {3, 1}, seen = 1789000000 } } }
--
-- `workspaces` is ordered most-recent-first. A single-window app has one entry; a
-- multi-window app accumulates the workspaces its windows were last seen on, and
-- placement takes the first one not already occupied.

local M = {}

M.VERSION = 1

local function empty()
    return { version = M.VERSION, entries = {} }
end

M.empty = empty

--- Escape a string for a Lua long-bracket-free quoted literal.
local function quote(s)
    return string.format("%q", s)
end

--- Serialize state to Lua source.
---@param state table
---@return string
function M.serialize(state)
    local keys = {}
    for k in pairs(state.entries or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)

    local out = {
        "-- hyprplace state. Generated file; edits will be overwritten.",
        "return {",
        string.format("  version = %d,", state.version or M.VERSION),
        "  entries = {",
    }
    for _, k in ipairs(keys) do
        local e = state.entries[k]
        local ws = {}
        for _, id in ipairs(e.workspaces or {}) do
            ws[#ws + 1] = tostring(id)
        end
        out[#out + 1] = string.format(
            "    [%s] = { workspaces = { %s }, seen = %d },",
            quote(k), table.concat(ws, ", "), math.floor(e.seen or 0))
    end
    out[#out + 1] = "  },"
    out[#out + 1] = "}"
    out[#out + 1] = ""
    return table.concat(out, "\n")
end

--- Parse serialized state. Returns an empty DB on any problem rather than throwing --
--- a corrupt DB must never take the compositor down with it.
---@param text string|nil
---@return table
function M.deserialize(text)
    if not text or text == "" then
        return empty()
    end
    local chunk = load(text, "hyprplace-db", "t", {})
    if not chunk then
        return empty()
    end
    local ok, value = pcall(chunk)
    if not ok or type(value) ~= "table" or type(value.entries) ~= "table" then
        return empty()
    end
    value.version = value.version or M.VERSION
    return value
end

--- Drop entries not seen within `ttl_days`.
---@param state table
---@param ttl_days number
---@param now integer
---@return table state, integer dropped
function M.prune(state, ttl_days, now)
    if not ttl_days or ttl_days <= 0 then
        return state, 0
    end
    local cutoff = now - (ttl_days * 86400)
    local dropped = 0
    for k, e in pairs(state.entries) do
        if (e.seen or 0) < cutoff then
            state.entries[k] = nil
            dropped = dropped + 1
        end
    end
    return state, dropped
end

---@param path string
---@return table
function M.load(path)
    local f = io.open(path, "r")
    if not f then
        return empty()
    end
    local text = f:read("a")
    f:close()
    return M.deserialize(text)
end

--- Create the DB's parent directory. Call once at setup, never on the write path --
--- os.execute forks a shell, and this runs inside the compositor process.
---@param path string
function M.ensure_dir(path)
    local dir = path:match("^(.*)/[^/]*$")
    if dir and dir ~= "" then
        os.execute(string.format("mkdir -p %q", dir))
    end
end

--- Write atomically: a crash mid-write must not corrupt the DB.
--- The parent directory must already exist; see ensure_dir.
---@param path string
---@param state table
---@return boolean ok, string|nil err
function M.save(path, state)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then
        return false, err
    end
    f:write(M.serialize(state))
    f:close()
    local ok, rerr = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return false, rerr
    end
    return true
end

--- Record the observed distribution of an app's windows across workspaces.
---
--- `workspaces` is the full list of workspaces occupied by every live window sharing
--- this key, duplicates included -- seven Firefox windows on 2,3,3,4,4,32,1 record all
--- seven. A snapshot rather than an accumulation: recording one observation at a time
--- could not represent multiplicity, and accumulating counts across events would let a
--- workspace you reopen on constantly crowd out the others.
---
--- Stored sorted, so the ordering is stable and does not depend on window enumeration
--- order. Which of several identical windows lands where is arbitrary anyway -- we
--- cannot tell them apart, which is the whole reason multiplicity is needed.
---@param state table
---@param key string
---@param workspaces integer[]
---@param now integer
---@param max_slots integer
function M.observe(state, key, workspaces, now, max_slots)
    if not key or not workspaces or #workspaces == 0 then
        return
    end
    local sorted = {}
    for _, id in ipairs(workspaces) do
        sorted[#sorted + 1] = id
    end
    table.sort(sorted)
    while #sorted > (max_slots or 8) do
        table.remove(sorted)
    end

    local e = state.entries[key]
    if not e then
        e = {}
        state.entries[key] = e
    end
    e.workspaces = sorted
    e.seen = now
end

--- Refresh an entry's recency without disturbing its workspace order.
---
--- Used when placement acts on an entry: continued use is evidence the entry is still
--- wanted, so it should not expire. Reordering here would be wrong -- the slot order
--- encodes which workspace each of an app's windows goes to, and placement picking
--- slot 2 (because slot 1 was taken) must not promote slot 2 to the front.
---@param state table
---@param key string|nil
---@param now integer
---@return boolean touched
function M.touch(state, key, now)
    local e = key and state.entries[key]
    if not e then
        return false
    end
    e.seen = now
    return true
end

---@param state table
---@param key string|nil
---@return table|nil
function M.lookup(state, key)
    if not key then
        return nil
    end
    return state.entries[key]
end

return M
