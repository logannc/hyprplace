-- Should hyprplace have anything to do with this window?
--
-- Extracted so the plugin and the CLI tools share exactly one implementation: a tool
-- that reported a different verdict from the running plugin would be worse than no tool.

local Config   = require("hyprplace.config")
local Identity = require("hyprplace.identity")

local M = {}

-- Verdict reasons. `OK` means tracked; everything else explains the refusal.
M.OK            = "ok"
M.NO_CLASS      = "no-class"
M.IGNORED       = "ignored-class"
M.NEEDS_CMDLINE = "needs-cmdline"

M.EXPLAIN = {
    [M.OK]            = "tracked",
    [M.NO_CLASS]      = "window has no class",
    [M.IGNORED]       = "class matches ignore_classes",
    [M.NEEDS_CMDLINE] = "class is in require_cmdline but has no distinguishing cmdline",
}

--- The class to fingerprint by, preferring the live class over the initial one.
---@param w table|nil
---@return string|nil
function M.class_of(w)
    if not w then
        return nil
    end
    local class = w.class
    if not class or class == "" then
        class = w.initial_class
    end
    if not class or class == "" then
        return nil
    end
    return class
end

--- Decide whether a window is tracked, and say why not when it is not.
---@param w table
---@param windows table[]
---@param cfg table
---@return boolean tracked, string reason
function M.decide(w, windows, cfg)
    local class = M.class_of(w)
    if not class then
        return false, M.NO_CLASS
    end
    if Config.matches(class, cfg.ignore_classes) then
        return false, M.IGNORED
    end
    if Config.matches(class, cfg.require_cmdline)
        and not Identity.has_cmdline_identity(w, windows, cfg) then
        return false, M.NEEDS_CMDLINE
    end
    return true, M.OK
end

return M
