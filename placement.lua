-- Choosing where a window should go. No `hl` dependency, so it runs identically inside
-- the compositor and inside the CLI tools.
--
-- `decide` is the single implementation of the placement decision. The plugin acts on
-- its verdict and the tools render it, so `hyprplace plan` and `hyprplace watch` cannot
-- drift from what actually happens.

local Config   = require("hyprplace.config")
local DB       = require("hyprplace.db")
local Identity = require("hyprplace.identity")
local Policy   = require("hyprplace.policy")
local Tag      = require("hyprplace.tag")

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

--- Is this window's identity still incomplete, such that deciding now would decide on
--- the wrong thing?
---
--- Only one case today: a class listed in `defer_classes` whose title carries no tag.
--- The tag arrives in a title event some time after the window maps, so the snapshot at
--- `window.open_early` is not yet the window's identity.
---@param w table
---@param cfg table
---@return boolean
function M.incomplete(w, cfg)
    local class = Policy.class_of(w)
    if not class or not Config.matches(class, cfg.defer_classes) then
        return false
    end
    return Tag.of(w.title) == nil
end

--- The placement verdict for one window.
---
--- outcome is one of:
---   skip   hyprplace does nothing and Hyprland decides (AC-3)
---   stay   the window is already on the workspace it belongs to
---   move   the window should be moved to `target`
---   defer  the identity is not knowable yet; wait and decide again
---
--- `opts.may_defer` is true by default, so the tools show the same "defer" a running
--- plugin would choose. The plugin passes false once the deadline has passed, which
--- turns the same call into the decision it would have made without deferral at all.
---@param w table
---@param windows table[]
---@param state table
---@param cfg table
---@param opts table|nil
---@return table
function M.decide(w, windows, state, cfg, opts)
    local may_defer = not opts or opts.may_defer ~= false
    local tracked, reason = Policy.decide(w, windows, cfg)
    local key = Identity.key_for(w, windows, cfg)
    local verdict = {
        key     = key,
        tracked = tracked,
        reason  = reason,
        ws      = w.workspace and w.workspace.id,
        address = w.address,
        class   = Policy.class_of(w) or "(none)",
        tag     = Tag.of(w.title),
    }

    if not tracked then
        verdict.outcome = "skip"
        verdict.detail  = Policy.EXPLAIN[reason] or reason
        return verdict
    end

    -- Before the DB is consulted: looking up a key derived from an identity that has
    -- not arrived yet would place the window on whatever the incomplete key remembers.
    if may_defer and M.incomplete(w, cfg) then
        verdict.outcome = "defer"
        verdict.detail  = string.format("waiting up to %dms for a window tag",
            cfg.defer_timeout_ms or 0)
        return verdict
    end

    local entry = key and DB.lookup(state, key)
    if not entry then
        verdict.outcome = "skip"
        verdict.detail  = "no record for this key"
        return verdict
    end
    verdict.remembered = entry.workspaces

    local counts = M.count_workspaces(windows, key, w.address,
        function(o) return (Identity.key_for(o, windows, cfg)) end)
    local target = M.choose(entry, counts)
    if not target then
        verdict.outcome = "skip"
        verdict.detail  = "every remembered slot is already filled"
        return verdict
    end

    verdict.target = target
    if verdict.ws == target then
        verdict.outcome = "stay"
        verdict.detail  = "already on workspace " .. tostring(target)
    else
        verdict.outcome = "move"
        verdict.detail  = string.format("workspace %s -> %d", tostring(verdict.ws), target)
    end
    return verdict
end

return M
