-- Choosing where a window should go. Pure logic, no `hl` dependency.

local M = {}

--- Workspaces already occupied by live windows sharing this identity key.
---
--- `key_fn(window)` returns the key for a window; injected so this is testable and so
--- the caller controls how expensive key derivation is.
---@param windows table[]
---@param key string
---@param self_address string|nil  address of the window being placed, excluded
---@param key_fn fun(w: table): string|nil
---@return table<integer, boolean>
function M.occupied_workspaces(windows, key, self_address, key_fn)
    local occupied = {}
    for _, w in ipairs(windows or {}) do
        if w.address ~= self_address and w.workspace and w.workspace.id then
            if key_fn(w) == key then
                occupied[w.workspace.id] = true
            end
        end
    end
    return occupied
end

--- Pick the first remembered workspace that is not already taken.
---
--- Returns nil when the entry is empty or every remembered workspace already holds a
--- window of this app -- in which case hyprplace does nothing and Hyprland decides
--- (AC-3). We never guess beyond what we remember.
---@param entry table|nil
---@param occupied table<integer, boolean>
---@return integer|nil
function M.choose(entry, occupied)
    if not entry or not entry.workspaces then
        return nil
    end
    for _, ws in ipairs(entry.workspaces) do
        if not occupied[ws] then
            return ws
        end
    end
    return nil
end

return M
