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
M.IGNORED_FLOAT = "floating"
M.IGNORED_TAG   = "ignored-tag"
M.NEEDS_CMDLINE = "needs-cmdline"

M.EXPLAIN = {
    [M.OK]            = "tracked",
    [M.NO_CLASS]      = "window has no class",
    [M.IGNORED]       = "class matches ignore_classes",
    [M.IGNORED_FLOAT] = "window is floating, and ignore_floating is on",
    [M.IGNORED_TAG]   = "window tag matches ignore_tags",
    [M.NEEDS_CMDLINE] = "class is in require_cmdline but has no tag or distinguishing cmdline",
}

--- A window's Hyprland tags, normalized for matching.
---
--- Tags applied by a window rule are stored with a `*` suffix to mark them dynamic, so
--- `tag = "+floating-window"` in the config becomes `floating-window*` on the window.
--- Hyprland's own CTagKeeper::isTagged treats the two as the same tag; so do we, or a
--- pattern written to match what the user put in their rules would never fire.
---@param w table|nil
---@return string[]
function M.tags_of(w)
    local tags = w and w.tags
    if type(tags) == "string" then
        tags = { tags }
    end
    if type(tags) ~= "table" then
        return {}
    end
    local out = {}
    for _, tag in ipairs(tags) do
        if type(tag) == "string" and tag ~= "" then
            out[#out + 1] = (tag:gsub("%*$", ""))
        end
    end
    return out
end

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
    -- Before anything is fingerprinted: a floating window is usually a dialog, and
    -- dialogs belong where the focus is rather than where one last appeared.
    if cfg.ignore_floating and w and w.floating == true then
        return false, M.IGNORED_FLOAT
    end
    -- Tags before cmdline: a window the user has classified is classified, and there is
    -- no point fingerprinting something we are about to ignore.
    for _, tag in ipairs(M.tags_of(w)) do
        if Config.matches(tag, cfg.ignore_tags) then
            return false, M.IGNORED_TAG
        end
    end
    if Config.matches(class, cfg.require_cmdline)
        and not Identity.has_specific_identity(w, windows, cfg) then
        return false, M.NEEDS_CMDLINE
    end
    return true, M.OK
end

return M
