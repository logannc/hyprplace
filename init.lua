-- hyprplace -- remember which workspace each app lives on, and put it back there.
--
--   require("hyprplace").setup({ ... })
--
-- Read docs/DESIGN.required.md before changing behaviour here. Several things that look
-- like defensive paranoia below are load-bearing and were measured, not guessed:
--
--   * Our own move dispatch echoes back as window.move_to_workspace, synchronously
--     inside hl.dispatch. The guard flag is necessary, and because the echo is
--     synchronous a plain boolean is sufficient.
--   * hl.dsp.window.move follows focus unless follow=false is passed. AC-2 requires it.
--   * hyprctl reload destroys the Lua VM, so all state here is rebuilt from disk on
--     load and nothing may be cached only in _G across a reload.
--   * This runs INSIDE the compositor process. Every handler is pcall-wrapped; an error
--     in hyprplace must never take the compositor down (AC-6).

local Config    = require("hyprplace.config")
local DB        = require("hyprplace.db")
local Identity  = require("hyprplace.identity")
local Learn     = require("hyprplace.learn")
local Placement = require("hyprplace.placement")
local Policy    = require("hyprplace.policy")

local M = {
    _cfg   = nil,
    _state = nil,
    -- True while we are dispatching our own move, so the echo is not learned from.
    _guard = false,
    -- Learning is frozen during unsettled periods -- session start, config reload and
    -- monitor hotplug -- because the compositor, hyprsplit and autostart all move
    -- windows then, and none of it is user intent.
    _settling = false,
    -- Set once the compositor is shutting down. Teardown closes every window, and
    -- monitors are removed first, so workspaces reflow and windows pile up. Recording
    -- any of that would overwrite good state with garbage on the way out.
    _shutdown = false,
    _dirty = false,
    _save_timer = nil,
    _subs = {},
}

-- ---------------------------------------------------------------------------
-- logging

local function log(fmt, ...)
    if M._cfg and M._cfg.debug then
        print("[hyprplace] " .. string.format(fmt, ...))
    end
end

--- Wrap a handler so a failure is logged and contained (AC-6).
local function guarded(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            print(string.format("[hyprplace] error in %s: %s", name, tostring(err)))
        end
    end
end

-- ---------------------------------------------------------------------------
-- policy

--- Should hyprplace have anything to do with this window at all?
--- Shared with the CLI tools; see policy.lua.
---@param w table
---@param windows table[]
---@return boolean
local function tracked(w, windows)
    local ok = Policy.decide(w, windows, M._cfg)
    return ok
end

local function key_fn(windows)
    return function(w)
        local key = Identity.key_for(w, windows, M._cfg)
        return key
    end
end

-- ---------------------------------------------------------------------------
-- persistence

--- Write immediately if there is anything pending.
local function flush_save()
    if not M._dirty then
        return
    end
    M._dirty = false
    local ok, err = DB.save(M._cfg.db_path, M._state)
    if not ok then
        print("[hyprplace] failed to save db: " .. tostring(err))
    else
        log("saved %s", M._cfg.db_path)
    end
end

local function schedule_save()
    M._dirty = true
    if M._save_timer then
        return
    end
    M._save_timer = hl.timer(guarded("save", function()
        M._save_timer = nil
        flush_save()
    end), { timeout = M._cfg.save_debounce_ms, type = "oneshot" })
end

-- ---------------------------------------------------------------------------
-- placement

local function place(w)
    if not M._cfg then
        return
    end
    local windows = hl.get_windows()
    if not tracked(w, windows) then
        return
    end

    local key = Identity.key_for(w, windows, M._cfg)
    local entry = DB.lookup(M._state, key)
    if not entry then
        log("no record for %q", tostring(key))
        return
    end

    local counts = Placement.count_workspaces(windows, key, w.address, key_fn(windows))
    local target = Placement.choose(entry, counts)
    if not target then
        log("every remembered slot for %q is filled", tostring(key))
        return
    end

    -- Acting on an entry is evidence it is still in use: refresh recency so an app you
    -- keep reopening never expires, even if you never explicitly move it.
    DB.touch(M._state, key, os.time())
    schedule_save()

    if w.workspace and w.workspace.id == target then
        return
    end

    -- Note: the target workspace need not exist yet. At session start most workspaces
    -- do not, and Hyprland creates one on demand -- which is exactly what we want when
    -- restoring after a reboot.
    log("placing %q -> workspace %d", tostring(key), target)
    M._guard = true
    local ok, err = pcall(function()
        hl.dispatch(hl.dsp.window.move({ window = w, workspace = target, follow = false }))
    end)
    M._guard = false
    if not ok then
        print("[hyprplace] move failed: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- learning

--- Record the whole observed distribution for `w`'s app.
---
--- Not just `w`'s own workspace: an app can have several windows, and remembering only
--- the one that happened to move would lose the rest. The subject window's workspace is
--- forced in, because on `window.close` it is unclear whether the closing window is
--- still in the window list -- and if it is not, closing the last window of an app
--- would record an empty distribution and forget it entirely (breaking AC-1).
local function remember(w, ws_id, why)
    if not ws_id then
        return
    end
    local windows = hl.get_windows()
    if not tracked(w, windows) then
        return
    end
    local key = Identity.key_for(w, windows, M._cfg)
    if not key then
        return
    end

    local distribution = Learn.distribution(w, windows, ws_id, key, key_fn(windows))

    DB.observe(M._state, key, distribution, os.time(), M._cfg.max_slots)
    log("learned (%s) %q -> %d window(s)", why, key, #distribution)
    schedule_save()
end

--- Is learning currently frozen? Placement is unaffected -- restoring windows at
--- session start is the whole point; it is only *recording* that must pause.
local function frozen()
    return M._shutdown or M._settling
end

local function on_move(w, ws)
    if M._guard then
        return -- our own placement echoing back
    end
    if frozen() then
        return -- session start, reload or hotplug reflow: not user intent
    end
    -- A deliberate move is a single focused window being moved on its own. Mass moves
    -- (hyprsplit swap_monitors) do not carry focus for every window they touch.
    if w and w.active == false then
        return
    end
    local id = ws and (type(ws) == "table" and ws.id or ws) or (w.workspace and w.workspace.id)
    remember(w, id, "move")
end

local function on_close(w)
    if frozen() then
        -- Compositor teardown closes every window. Recording then would rewrite the
        -- whole DB with whatever the collapsing session looked like.
        return
    end
    -- Essential for AC-1: a window the user never explicitly moved is only ever
    -- recorded here.
    if w and w.workspace then
        remember(w, w.workspace.id, "close")
    end
end

local function begin_settle(ms)
    M._settling = true
    hl.timer(guarded("settle", function()
        M._settling = false
        log("settled; learning resumed")
    end), { timeout = ms or M._cfg.monitor_settle_ms, type = "oneshot" })
end

local function on_shutdown()
    -- Freeze first, then persist: whatever we know right now is the last good state.
    M._shutdown = true
    flush_save()
    log("shutdown: state frozen and flushed")
end

-- ---------------------------------------------------------------------------
-- setup

---@param user_config table|nil
---@return table
function M.setup(user_config)
    M._cfg = Config.build(user_config)
    DB.ensure_dir(M._cfg.db_path)

    local state = DB.load(M._cfg.db_path)
    local dropped
    state, dropped = DB.prune(state, M._cfg.ttl_days, os.time())
    M._state = state
    if dropped > 0 then
        log("pruned %d expired entries", dropped)
        schedule_save()
    end

    M._subs = {
        hl.on("window.open_early",       guarded("open_early", place)),
        hl.on("window.move_to_workspace", guarded("move", on_move)),
        hl.on("window.close",            guarded("close", on_close)),
        hl.on("monitor.added",           guarded("monitor.added", function() begin_settle() end)),
        hl.on("monitor.removed",         guarded("monitor.removed", function() begin_settle() end)),
        hl.on("hyprland.shutdown",       guarded("shutdown", on_shutdown)),
    }

    -- Start frozen. setup() runs during config load, which happens both at session
    -- start and on every `hyprctl reload` -- exactly the two moments when windows get
    -- moved en masse by something other than the user. Relying on the hyprland.start
    -- event instead would depend on handler ordering against hyprsplit's reflow.
    begin_settle(M._cfg.startup_settle_ms)

    log("ready (db=%s, %d entries)", M._cfg.db_path, (function()
        local n = 0
        for _ in pairs(M._state.entries) do n = n + 1 end
        return n
    end)())

    return M
end

--- Current state, for inspection and tests.
function M.state()
    return M._state
end

function M.config()
    return M._cfg
end

return M
