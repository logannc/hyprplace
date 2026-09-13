-- What hyprplace would record for an app, given a window and the current layout.
--
-- Shared by the plugin and the CLI tools for the same reason as policy.lua: a tool that
-- predicted something different from what the plugin actually records would be worse
-- than no tool.

local M = {}

--- The distribution that would be recorded for `w`'s app if learning happened now.
---
--- Every live window sharing the key contributes its workspace, duplicates included,
--- with `w` itself contributing `ws_id` (its new or current workspace) rather than
--- whatever the list says.
---
--- `w`'s workspace is included even when `w` is absent from `windows`, which happens on
--- close: without this, closing the last window of an app would record an empty
--- distribution and forget it entirely.
---@param w table
---@param windows table[]
---@param ws_id integer
---@param key string
---@param key_fn fun(o: table): string|nil
---@return integer[]
function M.distribution(w, windows, ws_id, key, key_fn)
    local dist, saw_self = {}, false
    for _, other in ipairs(windows or {}) do
        if other.workspace and other.workspace.id and key_fn(other) == key then
            if other.address == w.address then
                saw_self = true
                dist[#dist + 1] = ws_id
            else
                dist[#dist + 1] = other.workspace.id
            end
        end
    end
    if not saw_self then
        dist[#dist + 1] = ws_id
    end
    table.sort(dist)
    return dist
end

return M
