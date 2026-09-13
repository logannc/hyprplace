-- Choosing where a window should go. Pure logic, no `hl` dependency.

local M = {}

--- How many live windows sharing this identity key sit on each workspace.
---
--- Counts, not a set: an app can legitimately have several windows on one workspace,
--- and a set would let only the first of them be placed.
---
--- `key_fn(window)` returns the key for a window; injected so this is testable and so
--- the caller controls how expensive key derivation is.
---@param windows table[]
---@param key string
---@param self_address string|nil  address of the window being placed, excluded
---@param key_fn fun(w: table): string|nil
---@return table<integer, integer>
function M.count_workspaces(windows, key, self_address, key_fn)
    local counts = {}
    for _, w in ipairs(windows or {}) do
        if w.address ~= self_address and w.workspace and w.workspace.id then
            if key_fn(w) == key then
                local id = w.workspace.id
                counts[id] = (counts[id] or 0) + 1
            end
        end
    end
    return counts
end

--- Pick the first remembered slot this app has not already filled.
---
--- Walks the remembered distribution in order; the k-th occurrence of a workspace is
--- available when fewer than k live windows of this app are on it. So an app remembered
--- as {3, 3, 4} places its first two windows on 3 and its third on 4.
---
--- Returns nil when the entry is empty or every remembered slot is filled -- hyprplace
--- then does nothing and Hyprland decides (AC-3). We never guess beyond what we
--- remember.
---@param entry table|nil
---@param counts table<integer, integer>
---@return integer|nil
function M.choose(entry, counts)
    if not entry or not entry.workspaces then
        return nil
    end
    local wanted = {}
    for _, ws in ipairs(entry.workspaces) do
        wanted[ws] = (wanted[ws] or 0) + 1
        if (counts[ws] or 0) < wanted[ws] then
            return ws
        end
    end
    return nil
end

return M
