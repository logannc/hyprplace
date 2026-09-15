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
local Tag       = require("hyprplace.tag")

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
    -- Windows whose identity was not knowable at open, awaiting a title or a deadline.
    -- Keyed by address, never by window object: the window may be gone by the time we
    -- look again, so it is re-resolved from hl.get_windows() at the moment we act.
    _pending = {},
    -- One repeating sweep for every pending window, disabled while none are pending.
    -- Per-window oneshots would be simpler but cannot be retracted -- HL.Timer has no
    -- cancel -- and a timer that fires after the user has moved the window would break
    -- AC-4. Deadlines are counted in sweep ticks so no wall clock is needed.
    _sweep = nil,
    -- window.title fires for every title change of every window, so the subscription is
    -- held only while something is actually pending.
    _title_sub = nil,
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

--- The window with this address, as the compositor sees it right now.
---@param windows table[]
---@param address string
---@return table|nil
local function by_address(windows, address)
    for _, w in ipairs(windows or {}) do
        if w.address == address then
            return w
        end
    end
    return nil
end

--- Carry out a verdict. Split from the decision so the deferred path, which decides at
--- a different moment, acts through exactly the same code.
local function apply(w, verdict)
    if verdict.outcome == "skip" then
        log("skip %s: %s", tostring(verdict.key), verdict.detail)
        return
    end

    -- Acting on an entry is evidence it is still in use: refresh recency so an app you
    -- keep reopening never expires, even if you never explicitly move it. Applies to
    -- `stay` too -- the window being in the right place is still use.
    DB.touch(M._state, verdict.key, os.time())
    schedule_save()

    if verdict.outcome == "stay" then
        return
    end

    -- Note: the target workspace need not exist yet. At session start most workspaces
    -- do not, and Hyprland creates one on demand -- which is exactly what we want when
    -- restoring after a reboot.
    log("placing %q -> workspace %d", tostring(verdict.key), verdict.target)
    M._guard = true
    local ok, err = pcall(function()
        hl.dispatch(hl.dsp.window.move({ window = w, workspace = verdict.target, follow = false }))
    end)
    M._guard = false
    if not ok then
        print("[hyprplace] move failed: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- deferred placement
--
-- Some windows cannot be identified when they open. A Firefox window's tag arrives in a
-- title event some time after the window maps, so deciding at window.open_early would
-- decide on an identity that is not there yet. Such a window is held: hyprplace watches
-- for the title, and acts when the identity completes or when the deadline passes.
--
-- AC-4 is what constrains the whole mechanism. hyprplace may place a window only while
-- the user has not touched it, so any deliberate move -- or the window closing -- drops
-- it from the pending set for good.

local sweep, on_title

--- Stop sweeping and stop listening for titles once nothing is waiting.
local function idle_if_empty()
    if next(M._pending) then
        return
    end
    if M._sweep then
        M._sweep:set_enabled(false)
    end
    if M._title_sub then
        M._title_sub:remove()
        M._title_sub = nil
    end
end

local function defer(w)
    local address = w.address
    if not address or M._pending[address] then
        return
    end
    local poll = math.max(1, M._cfg.defer_poll_ms or 250)
    local ticks = math.max(1, math.ceil((M._cfg.defer_timeout_ms or 0) / poll))
    M._pending[address] = { ticks = ticks }

    if not M._sweep then
        M._sweep = hl.timer(guarded("defer-sweep", function() sweep() end),
            { timeout = poll, type = "repeat" })
    else
        M._sweep:set_enabled(true)
    end
    if not M._title_sub then
        M._title_sub = hl.on("window.title", guarded("title", function(w2) on_title(w2) end))
    end
end

--- Drop a window from the pending set. Called whenever the user acts on it.
local function cancel_pending(address, why)
    if not address or not M._pending[address] then
        return
    end
    M._pending[address] = nil
    log("deferral cancelled (%s)", why)
    idle_if_empty()
end

--- Decide for a window whose deferral is over, one way or the other.
local function decide_now(address, may_defer, why)
    local windows = hl.get_windows()
    local w = by_address(windows, address)
    if not w then
        return -- closed while we waited
    end
    local verdict = Placement.decide(w, windows, M._state, M._cfg, { may_defer = may_defer })
    if verdict.outcome == "defer" then
        return -- still incomplete; keep waiting
    end
    M._pending[address] = nil
    log("deferred decision (%s): %s", why, verdict.detail)
    apply(w, verdict)
    idle_if_empty()
end

--- Tick every pending deadline; decide for the ones that ran out.
function sweep()
    if M._shutdown then
        M._pending = {}
        idle_if_empty()
        return
    end
    for address, p in pairs(M._pending) do
        p.ticks = p.ticks - 1
        if p.ticks <= 0 then
            -- Deadline reached: decide on what is known, which is exactly what would
            -- have happened without deferral.
            decide_now(address, false, "timed out")
        end
    end
    idle_if_empty()
end

--- A pending window's title changed; its identity may now be complete.
---@param w table|nil
function on_title(w)
    local address = w and w.address
    if not address or not M._pending[address] then
        return -- not waiting on this one; the common case, kept cheap
    end
    decide_now(address, true, "tag arrived")
end

--- Place a window, or start waiting if it cannot be identified yet.
local function place(w)
    if not M._cfg then
        return
    end
    local windows = hl.get_windows()
    local verdict = Placement.decide(w, windows, M._state, M._cfg)
    if verdict.outcome == "defer" then
        log("defer %s: %s", tostring(verdict.class), verdict.detail)
        defer(w)
        return
    end
    apply(w, verdict)
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

    DB.observe(M._state, key, distribution, os.time())
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
    -- A deliberate move is a single focused window being moved on its own. Mass moves
    -- (hyprsplit swap_monitors) do not carry focus for every window they touch.
    if w and w.active == false then
        return
    end
    -- The user has acted on this window, so hyprplace must not place it afterwards
    -- (AC-4). Cancelled even while learning is frozen: the freeze exists to stop us
    -- *recording* a startup reflow, not to license overriding the user during it.
    cancel_pending(w and w.address, "user moved the window")
    if frozen() then
        return -- session start, reload or hotplug reflow: not user intent
    end
    local id = ws and (type(ws) == "table" and ws.id or ws) or (w.workspace and w.workspace.id)
    remember(w, id, "move")
end

local function on_close(w)
    cancel_pending(w and w.address, "window closed")
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
    M._pending = {}
    idle_if_empty()
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

    -- Reset explicitly rather than relying on a fresh VM: `hyprctl reload` does give
    -- us one, but setup() is also the seam the tests drive, and a leaked pending set
    -- would make them depend on each other.
    M._pending   = {}
    M._sweep     = nil
    M._title_sub = nil

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
