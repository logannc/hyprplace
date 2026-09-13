-- Probe config for the contained test compositor.
-- Answers the open questions in docs/DESIGN.required.md empirically.
-- This is a HARNESS config, not hyprplace itself.

hl.config({ debug   = { enable_stdout_logs = true } })
hl.config({ xwayland = { enabled = false } })  -- no Xwayland -> no stray coredumps

hl.monitor({ output = "HEADLESS-1", mode = "1920x1080@60", position = "auto",       scale = 1 })
hl.monitor({ output = "HEADLESS-2", mode = "1920x1080@60", position = "auto-right", scale = 1 })
hl.monitor({ output = "", disabled = true })   -- hides the nested WAYLAND-N window

-- Q1: does `hyprctl reload` re-execute this file, and is the Lua VM persistent?
--   PROBE.loads == 1 after a reload -> fresh VM, subscriptions cannot stack.
--   PROBE.loads == 2 after a reload -> persistent VM + re-executed file; check
--   whether each event now fires its handler twice (stacking).
_G.PROBE = _G.PROBE or { loads = 0, events = {}, handlers = 0 }
_G.PROBE.loads = _G.PROBE.loads + 1

local function note(fmt, ...)
    table.insert(_G.PROBE.events, string.format(fmt, ...))
end

local function describe(w)
    if type(w) ~= "table" and type(w) ~= "userdata" then return "arg=" .. type(w) end
    local ok, s = pcall(function()
        return string.format("class=%q initial_class=%q title=%q ws=%s pid=%s xw=%s",
            tostring(w.class), tostring(w.initial_class), tostring(w.title),
            tostring(w.workspace and w.workspace.id), tostring(w.pid), tostring(w.xwayland))
    end)
    return ok and s or ("describe failed: " .. tostring(s))
end

-- Q2: is `class` populated at window.open_early, especially before map?
hl.on("window.open_early", function(w)
    _G.PROBE.handlers = _G.PROBE.handlers + 1
    note("open_early: %s", describe(w))
end)

hl.on("window.open", function(w)
    note("open: %s", describe(w))
end)

hl.on("window.class", function(w)
    note("class_event: %s", describe(w))
end)

-- Q3: does OUR OWN dispatch echo back as window.move_to_workspace?
_G.PROBE.guard = false
hl.on("window.move_to_workspace", function(w, ws)
    note("move_to_workspace: guard=%s ws_arg=%s %s",
        tostring(_G.PROBE.guard), tostring(ws and (ws.id or ws)), describe(w))
end)

hl.on("window.close", function(w)
    note("close: %s", describe(w))
end)

-- Helper the harness calls over the repl to perform a guarded move.
function _G.PROBE_move(addr, ws)
    for _, w in ipairs(hl.get_windows()) do
        if w.address == addr then
            _G.PROBE.guard = true
            hl.dispatch(hl.dsp.window.move({ window = w, workspace = ws }))
            _G.PROBE.guard = false
            return "moved"
        end
    end
    return "window not found"
end

function _G.PROBE_dump()
    return string.format("loads=%d handlers=%d\n%s",
        _G.PROBE.loads, _G.PROBE.handlers, table.concat(_G.PROBE.events, "\n"))
end
