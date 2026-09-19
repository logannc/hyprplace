-- hyprplace unit tests. Run: `make test` (or `lua tests/run.lua` from the repo root).
--
-- Everything here runs without a compositor: pure logic directly, and the event
-- handlers via a fake `hl` (tests/support.lua).

local script = debug.getinfo(1, "S").source:sub(2)
local ROOT = script:match("^(.*)/tests/[^/]*$") or "."

local support = dofile(ROOT .. "/tests/support.lua")
support.install_loader(ROOT)

-- --------------------------------------------------------------------------- runner

local passed, failed, current = 0, 0, "?"
local function group(name) current = name end
local function ok(cond, what)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.write(string.format("  FAIL  %s: %s\n", current, what))
    end
end
local function eq(a, b, what)
    if a == b then
        passed = passed + 1
    else
        failed = failed + 1
        io.write(string.format("  FAIL  %s: %s\n         expected %s\n         got      %s\n",
            current, what, tostring(b), tostring(a)))
    end
end

-- --------------------------------------------------------------------------- config

local Config = require("hyprplace.config")

group("config")
do
    local d = Config.defaults()
    ok(d.ttl_days > 0, "has a positive default ttl")
    ok(type(d.ignore_classes) == "table", "has ignore_classes")

    local merged = Config.build({ ttl_days = 5, debug = true })
    eq(merged.ttl_days, 5, "user override wins")
    eq(merged.debug, true, "user override applies to booleans")
    eq(merged.ttl_days ~= nil and merged.save_debounce_ms, d.save_debounce_ms,
        "unspecified keys keep defaults")

    ok(Config.matches("Kitty", { "^kitty$" }), "matches case-insensitively")
    ok(not Config.matches("kitty", { "^alacritty$" }), "non-match returns false")
    ok(not Config.matches(nil, { "^kitty$" }), "nil class never matches")
    ok(not Config.matches("", { "" }), "empty class never matches")
end

group("example_config documents every option")
do
    -- example_config.lua is the reference users copy from. Two lists of the same
    -- options drift; these assertions are what stop that.
    local f = assert(io.open(ROOT .. "/example_config.lua", "r"))
    local text = f:read("a")
    f:close()

    local example = assert(loadfile(ROOT .. "/example_config.lua"))()
    local d = Config.defaults()

    local function deep_eq(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end

    for key in pairs(d) do
        -- Mentioned, not necessarily set: db_path's default is computed from the
        -- environment, so the example documents it in a comment instead.
        ok(text:find(key, 1, true) ~= nil, key .. " is documented in example_config")
    end

    for key, value in pairs(example) do
        ok(d[key] ~= nil, key .. " in example_config is a real option")
        ok(deep_eq(value, d[key]), key .. " in example_config matches the default")
    end

    ok(deep_eq(Config.build(example), Config.build({})),
        "loading the example changes nothing -- it is the defaults")
end

-- ------------------------------------------------------------------------- identity

local Identity = require("hyprplace.identity")

group("identity.normalize_cmdline")
do
    eq(Identity.normalize_cmdline(nil), nil, "nil argv -> nil")
    eq(Identity.normalize_cmdline({}), nil, "empty argv -> nil")
    eq(Identity.normalize_cmdline({ "kitty" }), nil, "bare binary adds nothing over class")
    eq(Identity.normalize_cmdline({ "/usr/bin/kitty" }), nil, "bare absolute binary -> nil")
    eq(Identity.normalize_cmdline({ "/usr/bin/kitty", "btop" }), "kitty btop",
        "strips leading directories")
    eq(Identity.normalize_cmdline({ "uwsm", "app", "--", "kitty", "btop" }), "kitty btop",
        "strips the uwsm wrapper")
    eq(Identity.normalize_cmdline({ "env", "FOO=1", "kitty", "btop" }), "kitty btop",
        "strips env and VAR=value prefixes")
    eq(Identity.normalize_cmdline({ "uwsm", "app", "--", "kitty" }), nil,
        "wrapper around a bare binary is still nothing")
end

group("identity flag handling")
do
    -- Real Steam argv: 800+ chars, and -steampid/-buildid/-startcount all change on
    -- every launch, so a key built from them could never match a stored record.
    local steam = { "/home/u/.local/share/Steam/ubuntu12_32/steamwebhelper",
        "-nocrashdialog", "-steampid=3416", "-buildid=1788652215", "-startcount=0",
        "--enable-features=Foo" }
    eq(Identity.normalize_cmdline(steam), nil,
        "an all-flags argv yields no fingerprint, so the class tier is used")

    eq(Identity.normalize_cmdline({ "kitty", "--working-directory=/home/u/x" }), nil,
        "flags are dropped by default")
    eq(Identity.normalize_cmdline({ "kitty", "btop" }), "kitty btop",
        "positional arguments are always kept")
    eq(Identity.normalize_cmdline({ "kitty", "--hold", "btop" }), "kitty btop",
        "flags dropped, positionals kept, in one argv")

    local cfg = { keep_flags = { kitty = { "^%-%-working%-directory=" } } }
    eq(Identity.normalize_cmdline({ "kitty", "--working-directory=/home/u/x" }, cfg),
        "kitty --working-directory=/home/u/x",
        "an allowlisted flag is kept for that binary")
    eq(Identity.normalize_cmdline({ "kitty", "--hold", "--working-directory=/x" }, cfg),
        "kitty --working-directory=/x",
        "only the allowlisted flag is kept")
    eq(Identity.normalize_cmdline({ "alacritty", "--working-directory=/x" }, cfg), nil,
        "the allowlist is per binary, not global")

    local many = { "app" }
    for n = 1, 60 do many[#many + 1] = "argument" .. n end
    local capped = Identity.normalize_cmdline(many, { max_cmdline_len = 40 })
    eq(#capped, 40, "long fingerprints are capped")
end

group("identity.key_for")
do
    local real = Identity.read_cmdline
    Identity.read_cmdline = function(pid)
        if pid == 100 then return { "kitty", "btop" } end
        if pid == 200 then return { "kitty" } end
        return nil
    end

    local w_btop = support.window({ class = "kitty", pid = 100, address = "0xa" })
    local w_bare = support.window({ class = "kitty", pid = 200, address = "0xb" })
    local key1 = Identity.key_for(w_btop, { w_btop, w_bare })
    local key2 = Identity.key_for(w_bare, { w_btop, w_bare })
    eq(key1, "kitty\0kitty btop", "cmdline tier distinguishes kitty btop")
    eq(key2, "kitty", "bare kitty falls back to the class tier")
    ok(key1 ~= key2, "the two terminals get different keys")

    -- One pid serving several windows (Firefox, Electron): cmdline is meaningless.
    local f1 = support.window({ class = "firefox", pid = 100, address = "0xc" })
    local f2 = support.window({ class = "firefox", pid = 100, address = "0xd" })
    eq(Identity.key_for(f1, { f1, f2 }), "firefox", "shared pid falls back to class")

    eq(Identity.key_for(support.window({ class = "", pid = 1 }), {}), nil,
        "classless window has no key")

    local _, tier = Identity.key_for(w_btop, { w_btop })
    eq(tier, "cmdline", "reports which tier matched")
    ok(Identity.has_cmdline_identity(w_btop, { w_btop }), "btop has cmdline identity")
    ok(not Identity.has_cmdline_identity(w_bare, { w_bare }), "bare kitty does not")

    Identity.read_cmdline = real
end

-- ------------------------------------------------------------------------------- db

local DB = require("hyprplace.db")

group("db.serialize/deserialize")
do
    local s = DB.empty()
    DB.observe(s, "firefox", { 3 }, 1000)
    DB.observe(s, "kitty\0kitty btop", { 21 }, 1001)
    local round = DB.deserialize(DB.serialize(s))
    eq(round.version, DB.VERSION, "version survives")
    eq(round.entries["firefox"].workspaces[1], 3, "workspace survives")
    eq(round.entries["kitty\0kitty btop"].seen, 1001, "timestamp survives")
    ok(round.entries["kitty\0kitty btop"] ~= nil, "keys with embedded NUL survive")
end

group("db corruption is contained")
do
    eq(next(DB.deserialize("this is not lua").entries), nil, "garbage -> empty db")
    eq(next(DB.deserialize("return 42").entries), nil, "non-table -> empty db")
    eq(next(DB.deserialize(nil).entries), nil, "nil -> empty db")
    eq(next(DB.deserialize("os.exit(1)").entries), nil, "no ambient access in the sandbox")
end

group("db.observe")
do
    local s = DB.empty()
    DB.observe(s, "k", { 4, 2, 2 }, 100)
    eq(#s.entries["k"].workspaces, 3, "duplicates are kept -- multiplicity matters")
    eq(s.entries["k"].workspaces[1], 2, "stored sorted for stable ordering")
    eq(s.entries["k"].workspaces[3], 4, "sorted ascending")
    eq(s.entries["k"].seen, 100, "timestamp recorded")

    -- A snapshot replaces; it does not accumulate. Otherwise a workspace you reopen on
    -- constantly would crowd out the others.
    DB.observe(s, "k", { 9 }, 101)
    eq(#s.entries["k"].workspaces, 1, "a later observation replaces the earlier one")
    eq(s.entries["k"].workspaces[1], 9, "with the newly observed distribution")

    -- Deliberately uncapped: a bound could only ever lose a window's home, and an
    -- ordinary session with nine Firefox windows already hit the old one.
    local big = {}
    for n = 1, 40 do big[n] = n end
    DB.observe(s, "k", big, 102)
    eq(#s.entries["k"].workspaces, 40, "no cap -- every window keeps its home")

    DB.observe(s, "empty", {}, 103)
    eq(s.entries["empty"], nil, "an empty observation records nothing")
end

group("db.touch")
do
    local s = DB.empty()
    DB.observe(s, "k", { 5, 3 }, 101)   -- sorted to {3, 5}
    ok(DB.touch(s, "k", 999), "touch reports it found the entry")
    eq(s.entries["k"].seen, 999, "seen is refreshed")
    eq(s.entries["k"].workspaces[1], 3, "slot order is not disturbed")
    eq(s.entries["k"].workspaces[2], 5, "second slot is not disturbed")
    ok(not DB.touch(s, "missing", 999), "touching an absent key reports false")
end

group("db.prune")
do
    local now = 1000000
    local s = DB.empty()
    DB.observe(s, "fresh", { 1 }, now)
    DB.observe(s, "stale", { 1 }, now - (91 * 86400), 8)
    local _, dropped = DB.prune(s, 90, now)
    eq(dropped, 1, "one entry expired")
    ok(s.entries["fresh"] ~= nil, "fresh entry kept")
    eq(s.entries["stale"], nil, "stale entry dropped")

    local s2 = DB.empty()
    DB.observe(s2, "old", { 1 }, 0)
    local _, d2 = DB.prune(s2, 0, now)
    eq(d2, 0, "ttl of 0 disables expiry")
end

group("db.save/load round trip")
do
    local path = os.tmpname()
    local s = DB.empty()
    DB.observe(s, "firefox", { 7 }, 12345)
    local saved, err = DB.save(path, s)
    ok(saved, "save succeeded (" .. tostring(err) .. ")")
    eq(DB.load(path).entries["firefox"].workspaces[1], 7, "loaded what we saved")
    eq(next(DB.load("/nonexistent/hyprplace/db.lua").entries), nil, "missing file -> empty")
    os.remove(path)
end

-- ------------------------------------------------------------------------ placement

local Placement = require("hyprplace.placement")

group("placement counts windows per workspace")
do
    local key_of = function(w) return w.class end
    local a = support.window({ class = "kitty", address = "0xa", workspace = 1 })
    local b = support.window({ class = "kitty", address = "0xb", workspace = 2 })
    local c = support.window({ class = "kitty", address = "0xc", workspace = 2 })
    local d = support.window({ class = "firefox", address = "0xd", workspace = 3 })

    local counts = Placement.count_workspaces({ a, b, c, d }, "kitty", "0xa", key_of)
    eq(counts[2], 2, "counts two windows on the same workspace")
    eq(counts[1], nil, "excludes the window being placed")
    eq(counts[3], nil, "ignores other apps")
end

group("placement.choose")
do
    eq(Placement.choose({ workspaces = { 2, 1, 5 } }, { [2] = 1 }), 1,
        "skips a filled slot and takes the next")
    eq(Placement.choose({ workspaces = { 2 } }, { [2] = 1 }), nil,
        "every slot filled -> no placement")
    eq(Placement.choose(nil, {}), nil, "no entry -> no placement")
    eq(Placement.choose({ workspaces = {} }, {}), nil, "empty entry -> no placement")

    -- The case that motivated all of this: several windows of one app on one workspace.
    local entry = { workspaces = { 3, 3, 4 } }
    eq(Placement.choose(entry, {}), 3, "first window goes to 3")
    eq(Placement.choose(entry, { [3] = 1 }), 3, "second also goes to 3 -- remembered twice")
    eq(Placement.choose(entry, { [3] = 2 }), 4, "third moves on to 4")
    eq(Placement.choose(entry, { [3] = 2, [4] = 1 }), nil, "fourth has nowhere remembered")
end

-- --------------------------------------------------------------------------- policy

local Policy = require("hyprplace.policy")

group("policy.decide")
do
    local cfg = Config.build({ ignore_classes = { "^hyprland%-run$" }, require_cmdline = { "^kitty$" } })
    local real = Identity.read_cmdline
    Identity.read_cmdline = function(pid)
        if pid == 100 then return { "kitty", "btop" } end
        return { "kitty" }
    end

    local function decide(w, all) return Policy.decide(w, all or { w }, cfg) end

    local plain = support.window({ class = "firefox", pid = 1 })
    local okp, reason = decide(plain)
    ok(okp, "an ordinary window is tracked")
    eq(reason, Policy.OK, "with the ok reason")

    local _, r2 = decide(support.window({ class = "", initial_class = "", pid = 1 }))
    eq(r2, Policy.NO_CLASS, "classless window reports no-class")

    local _, r3 = decide(support.window({ class = "hyprland-run", pid = 1 }))
    eq(r3, Policy.IGNORED, "ignore_classes reports ignored-class")

    local _, r4 = decide(support.window({ class = "kitty", pid = 200 }))
    eq(r4, Policy.NEEDS_CMDLINE, "bare terminal reports needs-cmdline")

    local okb = decide(support.window({ class = "kitty", pid = 100 }))
    ok(okb, "a terminal with a distinguishing cmdline is tracked")

    ok(Policy.EXPLAIN[Policy.NEEDS_CMDLINE], "every reason has a human explanation")

    eq(Policy.class_of(support.window({ class = "", initial_class = "Foo" })), "Foo",
        "falls back to initial_class")
    eq(Policy.class_of(nil), nil, "nil window has no class")

    Identity.read_cmdline = real
end

-- ----------------------------------------------------------------- handlers via hl

-- Everything the suite writes, removed at the end. setup() writes a state file, a
-- config cache and a log, and without explicit overrides they land in the user's real
-- ~/.local/state/hyprplace -- which running the tests must never touch.
--
-- Snapshotted before anything runs rather than checked for absence at the end: on a
-- machine where hyprplace is actually installed these files exist and are none of the
-- suite's business. What must not happen is the suite changing them.
local function snapshot(path)
    local f = io.open(path, "rb")
    if not f then
        return false, nil
    end
    local text = f:read("a")
    f:close()
    return true, text
end

local REAL_PATHS = {}
do
    local d = Config.defaults()
    for _, path in ipairs({ d.db_path, d.cache_path, d.log_path }) do
        if path then
            local existed, content = snapshot(path)
            REAL_PATHS[#REAL_PATHS + 1] =
                { path = path, existed = existed, content = content }
        end
    end
end

local tmpfiles = {}
local function tmpfile()
    local path = os.tmpname()
    tmpfiles[#tmpfiles + 1] = path
    return path
end

local function fresh(windows, user_cfg)
    package.loaded["hyprplace"] = nil
    local h = support.fake_hl(windows)
    _G.hl = h
    local cfg = user_cfg or {}
    cfg.db_path = cfg.db_path or tmpfile()
    cfg.cache_path = cfg.cache_path or tmpfile()
    cfg.log_path = cfg.log_path == nil and tmpfile() or cfg.log_path
    local hp = require("hyprplace").setup(cfg)
    return hp, h, cfg.db_path
end

group("setup")
do
    local _, h = fresh({})
    ok(h.handlers["window.open_early"], "subscribes to window.open_early")
    ok(h.handlers["window.move_to_workspace"], "subscribes to window.move_to_workspace")
    ok(h.handlers["window.close"], "subscribes to window.close")
    -- Deliberately NOT subscribed. A hotplug migrates whole workspaces between
    -- monitors; windows keep the workspace they are on, so nothing hyprplace records
    -- changes and there is no window.move_to_workspace to mislearn from. A freeze here
    -- guarded against nothing and only collided with the startup one.
    eq(h.handlers["monitor.added"], nil, "does not subscribe to monitor.added")
    eq(h.handlers["monitor.removed"], nil, "nor to monitor.removed")
end

group("placement dispatch")
do
    local w = support.window({ class = "firefox", address = "0xa", workspace = 9 })
    local hp, h = fresh({ w })
    DB.observe(hp.state(), "firefox", { 3 }, os.time(), 8)

    h.handlers["window.open_early"](w)
    eq(#h.dispatched, 1, "dispatched exactly one move")
    local args = h.dispatched[1].args
    eq(args.workspace, 3, "moved to the remembered workspace")
    eq(args.follow, false, "AC-2: follow=false so focus does not move")
    eq(args.window, w, "moved the right window")
end

group("placement declines when it should")
do
    local w = support.window({ class = "unknown-app", address = "0xa", workspace = 9 })
    local _, h = fresh({ w })
    h.handlers["window.open_early"](w)
    eq(#h.dispatched, 0, "AC-3: no record -> no dispatch")

    local w2 = support.window({ class = "firefox", address = "0xb", workspace = 3 })
    local hp2, h2 = fresh({ w2 })
    DB.observe(hp2.state(), "firefox", { 3 }, os.time(), 8)
    h2.handlers["window.open_early"](w2)
    eq(#h2.dispatched, 0, "already on the remembered workspace -> no dispatch")

    local w3 = support.window({ class = "hyprland-run", address = "0xc", workspace = 9 })
    local hp3, h3 = fresh({ w3 })
    DB.observe(hp3.state(), "hyprland-run", { 1 }, os.time(), 8)
    h3.handlers["window.open_early"](w3)
    eq(#h3.dispatched, 0, "ignore_classes are never placed")
end

group("the self-move guard")
do
    -- The compositor echoes our own move back synchronously; without the guard we would
    -- learn from our own placement. This is the measured behaviour, replayed.
    --
    -- The entry is {3, 5} with another window already on 5, so placement picks 3. If the
    -- echo were learned, the observation would collapse the entry to the two windows'
    -- actual workspaces and the remembered 5 would be lost. Slot contents are therefore
    -- the discriminator -- `seen` is not, because placement legitimately refreshes it.
    local w     = support.window({ class = "firefox", address = "0xa", workspace = 9 })
    local other = support.window({ class = "firefox", address = "0xb", workspace = 5 })
    local hp, h = fresh({ w, other })
    h.echo_move = true
    DB.observe(hp.state(), "firefox", { 5, 3 }, 1000)   -- sorted to {3, 5}

    h.handlers["window.open_early"](w)
    eq(h.dispatched[1].args.workspace, 3, "placed on the first free remembered slot")
    eq(#hp.state().entries["firefox"].workspaces, 2,
        "the echo of our own move was not learned from")
    eq(hp.state().entries["firefox"].workspaces[1], 3, "slots intact")
    eq(hp.state().entries["firefox"].workspaces[2], 5, "both slots intact")
end

group("placement refreshes recency")
do
    local w = support.window({ class = "firefox", address = "0xa", workspace = 9 })
    local hp, h = fresh({ w })
    DB.observe(hp.state(), "firefox", { 3 }, 1000)
    h.handlers["window.open_early"](w)
    ok(hp.state().entries["firefox"].seen > 1000,
        "an app you keep reopening does not expire, even if never moved")

    -- Also refreshed when the window is already where it belongs and no move is needed.
    local w2 = support.window({ class = "discord", address = "0xb", workspace = 3 })
    local hp2, h2 = fresh({ w2 })
    DB.observe(hp2.state(), "discord", { 3 }, 1000)
    h2.handlers["window.open_early"](w2)
    eq(#h2.dispatched, 0, "no move needed")
    ok(hp2.state().entries["discord"].seen > 1000, "but recency still refreshed")
end

group("learning from real moves")
do
    local w = support.window({ class = "firefox", address = "0xa", workspace = 3 })
    local hp, h = fresh({ w })
    h.flush_timers()
    h.handlers["window.move_to_workspace"](w, { id = 7 })
    eq(hp.state().entries["firefox"].workspaces[1], 7, "a user move is learned")

    -- Mass moves (hyprsplit swap_monitors) do not carry focus on every window.
    local u = support.window({ class = "discord", address = "0xb", workspace = 3, active = false })
    local hp2, h2 = fresh({ u })
    h2.flush_timers()
    h2.handlers["window.move_to_workspace"](u, { id = 7 })
    eq(hp2.state().entries["discord"], nil, "an unfocused window's move is not learned")

    -- A mass move carries focus for at most one of the windows it touches, which is
    -- what separates hyprsplit's swap_monitors from a user dragging a window.
    local a = support.window({ class = "signal", address = "0xc", workspace = 3 })
    local b = support.window({ class = "signal", address = "0xd", workspace = 3,
        active = false })
    local hp3, h3 = fresh({ a, b })
    h3.flush_timers()   -- clear the startup freeze
    h3.handlers["window.move_to_workspace"](b, { id = 7 })
    eq(hp3.state().entries["signal"], nil, "the unfocused half of a mass move is ignored")
end

group("multi-window apps record their whole distribution")
do
    -- The case from a live session: seven Firefox windows across 2,3,3,4,4,32,1. Three
    -- of them share workspace 3. Remembering a set would place only one there.
    local real = Identity.read_cmdline
    Identity.read_cmdline = function() return nil end

    local ws = { 2, 3, 3, 4, 4, 32, 1 }
    local wins = {}
    for i, id in ipairs(ws) do
        wins[i] = support.window({ class = "firefox", pid = 500 + i,
                                   address = "0x" .. i, workspace = id })
    end
    local hp, h = fresh(wins)
    h.flush_timers()
    h.handlers["window.close"](wins[1])

    local slots = hp.state().entries["firefox"].workspaces
    eq(#slots, 7, "all seven windows are remembered, not five distinct workspaces")
    local threes = 0
    for _, id in ipairs(slots) do if id == 3 then threes = threes + 1 end end
    eq(threes, 2, "workspace 3 is remembered twice over")

    -- And placement can fill them: with two already on 3, a third window still goes to 3.
    local entry = hp.state().entries["firefox"]
    eq(Placement.choose(entry, {}), 1, "first window takes the lowest remembered slot")
    eq(Placement.choose(entry, { [1] = 1, [2] = 1, [3] = 1 }), 3,
        "a second window still goes to 3, because 3 was remembered twice")

    Identity.read_cmdline = real
end

group("closing the last window still records it")
do
    -- If the closing window is absent from the window list, a naive distribution would
    -- be empty and the app would be forgotten entirely -- breaking AC-1.
    local w = support.window({ class = "signal", address = "0xa", workspace = 33 })
    local hp, h = fresh({})          -- window list does NOT contain the closing window
    h.flush_timers()
    h.handlers["window.close"](w)
    eq(hp.state().entries["signal"].workspaces[1], 33,
        "the closing window's own workspace is recorded regardless")
end

group("session lifecycle freeze")
do
    -- At session start the compositor, hyprsplit and autostart all move windows before
    -- anything settles. Learning then would overwrite good state with the transient
    -- layout -- and then place windows there next boot.
    local w = support.window({ class = "firefox", address = "0xa", workspace = 1 })
    local hp, h = fresh({ w })
    DB.observe(hp.state(), "firefox", { 3 }, 1000)

    h.handlers["window.move_to_workspace"](w, { id = 1 })
    eq(hp.state().entries["firefox"].workspaces[1], 3,
        "a move during startup settling does not overwrite the record")
    h.handlers["window.close"](w)
    eq(hp.state().entries["firefox"].workspaces[1], 3,
        "nor does a close during startup settling")

    h.flush_timers()
    h.handlers["window.move_to_workspace"](w, { id = 1 })
    eq(hp.state().entries["firefox"].workspaces[1], 1, "learning resumes once settled")

    -- Placement must keep working while frozen: restoring windows at session start is
    -- the entire point of the plugin.
    local w2 = support.window({ class = "discord", address = "0xb", workspace = 1 })
    local hp2, h2 = fresh({ w2 })
    DB.observe(hp2.state(), "discord", { 31 }, 1000)
    h2.handlers["window.open_early"](w2)
    eq(h2.dispatched[1].args.workspace, 31, "placement still happens during startup")
end

group("shutdown freeze")
do
    -- Teardown closes every window, and monitors are removed first, so workspaces
    -- reflow and windows pile onto whatever is left.
    local w = support.window({ class = "firefox", address = "0xa", workspace = 3 })
    local hp, h, path = fresh({ w })
    h.flush_timers()
    h.handlers["window.close"](w)
    h.flush_timers()
    eq(DB.load(path).entries["firefox"].workspaces[1], 3, "good state recorded while up")

    h.handlers["hyprland.shutdown"]()
    local collapsed = support.window({ class = "firefox", address = "0xb", workspace = 1 })
    h.handlers["window.close"](collapsed)
    h.handlers["window.move_to_workspace"](collapsed, { id = 1 })
    eq(hp.state().entries["firefox"].workspaces[1], 3,
        "teardown closes and reflows are not recorded")
    os.remove(path)
end

group("shutdown flushes pending writes")
do
    -- Saves are debounced, so a shutdown inside the debounce window would lose the
    -- last thing learned.
    local w = support.window({ class = "signal", address = "0xa", workspace = 33 })
    local hp, h, path = fresh({ w })
    h.flush_timers()
    h.handlers["window.close"](w)
    eq(next(DB.load(path).entries), nil, "still pending")
    h.handlers["hyprland.shutdown"]()
    eq(DB.load(path).entries["signal"].workspaces[1], 33, "shutdown flushed it to disk")
    os.remove(path)
end

group("learning on close (AC-1)")
do
    -- A window the user never explicitly moved is only ever recorded here.
    local w = support.window({ class = "firefox", address = "0xa", workspace = 3 })
    local hp, h = fresh({ w })
    h.flush_timers()
    h.handlers["window.close"](w)
    eq(hp.state().entries["firefox"].workspaces[1], 3, "close records the workspace")
end

group("require_cmdline policy")
do
    local real = Identity.read_cmdline
    Identity.read_cmdline = function(pid)
        if pid == 100 then return { "kitty", "btop" } end
        return { "kitty" }
    end

    local bare = support.window({ class = "kitty", pid = 200, address = "0xa", workspace = 3 })
    local hp, h = fresh({ bare }, { require_cmdline = { "^kitty$" } })
    h.flush_timers()
    h.handlers["window.close"](bare)
    eq(hp.state().entries["kitty"], nil, "a bare terminal is not remembered")

    local btop = support.window({ class = "kitty", pid = 100, address = "0xb", workspace = 21 })
    local hp2, h2 = fresh({ btop }, { require_cmdline = { "^kitty$" } })
    h2.flush_timers()
    h2.handlers["window.close"](btop)
    eq(hp2.state().entries["kitty\0kitty btop"].workspaces[1], 21,
        "but `kitty btop` is remembered")

    Identity.read_cmdline = real
end

group("errors are contained (AC-6)")
do
    local hp, h = fresh({})
    -- A window object that explodes on field access must not escape the handler.
    local hostile = setmetatable({}, { __index = function() error("boom") end })
    local success = pcall(function() h.handlers["window.open_early"](hostile) end)
    ok(success, "a throwing window does not propagate out of the handler")
end

group("persistence is debounced")
do
    local w = support.window({ class = "firefox", address = "0xa", workspace = 3 })
    local hp, h, path = fresh({ w })
    h.flush_timers()
    h.handlers["window.close"](w)
    eq(next(DB.load(path).entries), nil, "not written synchronously")
    h.flush_timers()
    eq(DB.load(path).entries["firefox"].workspaces[1], 3, "written when the timer fires")
    os.remove(path)
end

-- ------------------------------------------------------------------------------ tag

local Tag = require("hyprplace.tag")

group("tag.of")
do
    eq(Tag.of("[work] Inbox - Mozilla Firefox"), "work", "a tagged title yields its tag")
    eq(Tag.of("[3f9a1c2b] Something"), "3f9a1c2b", "the default hex form")
    eq(Tag.of("[a_b-C9] x"), "a_b-C9", "the full alphabet: letters, digits, _ and -")
    eq(Tag.of("[t] "), "t", "a one-character tag with an empty title")

    eq(Tag.of("Inbox - Mozilla Firefox"), nil, "an untagged title has no tag")
    eq(Tag.of(""), nil, "an empty title")
    eq(Tag.of(nil), nil, "no title at all")
    eq(Tag.of("[work]No space"), nil, "the space after the bracket is required")
    eq(Tag.of("x [work] y"), nil, "the tag must be anchored at the start")
    eq(Tag.of("[has space] x"), nil, "spaces are not in the alphabet")
    eq(Tag.of("[has.dot] x"), nil, "punctuation outside the alphabet is rejected")
    eq(Tag.of("[" .. string.rep("a", 33) .. "] x"), nil, "over 32 characters is rejected")
    eq(Tag.of("[" .. string.rep("a", 32) .. "] x"), string.rep("a", 32), "exactly 32 is fine")

    -- The reason for being strict: ordinary titles begin with brackets often enough
    -- that a loose match would invent identities for windows that have none.
    eq(Tag.of("[1/3] Downloading - Mozilla Firefox"), nil, "a bracketed progress counter")
    eq(Tag.of("[Draft] Re: budget"), "Draft", "a bracketed word IS matched -- see note")
end

group("the tag format matches the extension")
do
    -- The alphabet is written twice, in two languages: TAG_RE in the extension's
    -- background.js and the pattern in tag.lua. They must agree, or the plugin will
    -- either reject tags the extension issues or accept tags it never would.
    local f = assert(io.open(ROOT .. "/extension/background.js", "r"))
    local js = f:read("a")
    f:close()

    local alphabet, max = js:match("TAG_RE%s*=%s*/%^%[([^%]]+)%]{1,(%d+)}%$/")
    ok(alphabet ~= nil, "found TAG_RE in background.js")
    eq(alphabet, "A-Za-z0-9_-", "the extension's alphabet is the one tag.lua reads")
    eq(tonumber(max), Tag.MAX_LEN, "and the length bound matches Tag.MAX_LEN")

    -- Sampled from the extension's alphabet rather than asserted about the pattern
    -- string, so a rewrite of either side that changes behaviour still fails.
    for _, ch in ipairs({ "a", "Z", "7", "_", "-" }) do
        eq(Tag.of("[x" .. ch .. "] t"), "x" .. ch, ch .. " is accepted by both")
    end
    for _, ch in ipairs({ " ", ".", "/", "]", "%" }) do
        eq(Tag.of("[x" .. ch .. "] t"), nil, "'" .. ch .. "' is accepted by neither")
    end

    -- The preface format the extension writes, read back by the plugin.
    eq(Tag.of("[" .. string.rep("0", 8) .. "] Inbox - Mozilla Firefox"),
        string.rep("0", 8), "the default 8-hex-character tag round trips")
end

group("tag.strip")
do
    eq(Tag.strip("[work] Inbox"), "Inbox", "the preface is removed")
    eq(Tag.strip("Inbox"), "Inbox", "an untagged title is unchanged")
    eq(Tag.strip("[has space] x"), "[has space] x", "a non-tag prefix is left alone")
    eq(Tag.strip(nil), "", "nil renders as empty")
end

-- ------------------------------------------------------------- overlapping freezes

group("a shorter freeze cannot cut a longer one short")
do
    -- The only freeze left is the one setup() starts, so overlaps come from reloading
    -- twice in quick succession: `hyprctl reload` while the previous freeze is running.
    local w = support.window({ class = "kitty", address = "0xa", workspace = 3 })
    local hp, h = fresh({ w }, { startup_settle_ms = 8000 })
    ok(hp._settling, "setup starts frozen")

    local timers = #h.timers
    hp.setup({ startup_settle_ms = 8000,
        db_path = tmpfile(), cache_path = tmpfile(), log_path = tmpfile() })
    -- Equal deadlines: the running freeze already covers the new one, so it needs no
    -- timer of its own -- and must not get one that could thaw the first early.
    eq(#h.timers, timers, "a reload of equal length reuses the running freeze")
    ok(hp._settling, "and the freeze holds")

    h.flush_timers()
    ok(not hp._settling, "thawing when it expires")
end

group("a longer freeze started inside a shorter one wins")
do
    local w = support.window({ class = "kitty", address = "0xa", workspace = 3 })
    local hp, h = fresh({ w }, { startup_settle_ms = 2000 })
    local short_timer = h.timers[#h.timers]

    hp.setup({ startup_settle_ms = 8000,
        db_path = tmpfile(), cache_path = tmpfile(), log_path = tmpfile() })
    ok(hp._settling, "the second, longer freeze is running")

    short_timer.cb()
    ok(hp._settling, "the superseded timer does not thaw it")

    h.flush_timers()
    ok(not hp._settling, "its own timer does")
end

group("freezing actually stops learning")
do
    -- The point of all of the above, stated as behaviour rather than bookkeeping.
    local w = support.window({ class = "kitty", address = "0xa", workspace = 3 })
    local hp, h = fresh({ w }, { startup_settle_ms = 2000 })
    local short_timer = h.timers[#h.timers]

    hp.setup({ startup_settle_ms = 8000,
        db_path = tmpfile(), cache_path = tmpfile(), log_path = tmpfile() })
    short_timer.cb()

    h.handlers["window.move_to_workspace"](w, { id = 9 })
    eq(next(hp.state().entries), nil, "a move during an overlapping freeze is not learned")

    h.flush_timers()
    h.handlers["window.move_to_workspace"](w, { id = 9 })
    ok(hp.state().entries["kitty"] ~= nil, "and is learned once thawed")
end

-- ------------------------------------------------------------------ ignore_floating

group("floating windows are skipped by default")
do
    local cfg = Config.build({})
    ok(cfg.ignore_floating, "the default is on")

    -- The case it exists for: an unlock dialog shares a class with the main window,
    -- so remembering it teaches hyprplace the app lives on two workspaces and the next
    -- dialog gets sent to one of them.
    local dialog = support.window({ class = "myvault", address = "0xa", workspace = 3,
        floating = true })
    local main = support.window({ class = "myvault", address = "0xb", workspace = 14 })

    local tracked, reason = Policy.decide(dialog, { dialog, main }, cfg)
    ok(not tracked, "the floating dialog is not tracked")
    eq(reason, Policy.IGNORED_FLOAT, "and says why")
    ok(Policy.decide(main, { dialog, main }, cfg), "the tiled main window still is")

    eq(Placement.decide(dialog, { dialog, main }, DB.empty(), cfg).outcome, "skip",
        "so it is never placed")

    local off = Config.build({ ignore_floating = false })
    ok(Policy.decide(dialog, { dialog }, off), "and it can be turned off")

    -- Absent rather than false: a window list that does not carry the field at all
    -- must not be read as "everything is floating".
    local unknown = support.window({ class = "kitty", address = "0xc", workspace = 3 })
    unknown.floating = nil
    ok(Policy.decide(unknown, { unknown }, cfg), "an unknown floating state is not excluded")
end

group("a floating dialog is not learned from")
do
    local dialog = support.window({ class = "myvault", address = "0xa", workspace = 3,
        floating = true })
    local hp, h = fresh({ dialog })
    h.flush_timers() -- let the startup freeze lapse

    h.handlers["window.move_to_workspace"](dialog, { id = 5 })
    eq(next(hp.state().entries), nil, "moving it records nothing")

    h.handlers["window.close"](dialog)
    eq(next(hp.state().entries), nil, "and neither does closing it")
end

-- --------------------------------------------------------------------- ignore_tags

group("policy.tags_of")
do
    eq(#Policy.tags_of(nil), 0, "no window")
    eq(#Policy.tags_of({}), 0, "no tags")
    eq(#Policy.tags_of({ tags = "solo" }), 1, "a bare string is one tag")
    eq(Policy.tags_of({ tags = "solo" })[1], "solo", "and is returned as given")

    -- Hyprland marks a rule-applied tag dynamic by storing it with a trailing star, so
    -- `tag = "+floating-window"` in a window rule arrives here as `floating-window*`.
    eq(Policy.tags_of({ tags = { "floating-window*" } })[1], "floating-window",
        "the dynamic marker is stripped, as Hyprland's own isTagged does")
    eq(Policy.tags_of({ tags = { "manual" } })[1], "manual", "a static tag is unchanged")

    local many = Policy.tags_of({ tags = { "a*", "b", "", 7 } })
    eq(#many, 2, "empty and non-string entries are dropped")
    eq(many[1] .. many[2], "ab", "the rest survive in order")
end

group("ignore_tags excludes a window whatever its class")
do
    local cfg = Config.build({ ignore_tags = { "^floating%-window$" } })

    -- The case this exists for: a password manager's unlock dialog and its main
    -- window share a class, so ignore_classes can only take both or neither -- but
    -- the user's rules already tag the app, and a tag is what distinguishes it.
    local dialog = support.window({ class = "myvault", address = "0xa", workspace = 3 })
    dialog.tags = { "floating-window*" }
    local tracked, reason = Policy.decide(dialog, { dialog }, cfg)
    ok(not tracked, "a tagged window is not tracked")
    eq(reason, Policy.IGNORED_TAG, "and says which rule excluded it")
    ok(Policy.EXPLAIN[reason]:find("ignore_tags", 1, true) ~= nil, "readably")

    local plain = support.window({ class = "myvault", address = "0xb", workspace = 3 })
    ok(Policy.decide(plain, { plain }, cfg), "an untagged window of the same class is")

    local other = support.window({ class = "kitty", address = "0xc", workspace = 3 })
    other.tags = { "something-else*" }
    ok(Policy.decide(other, { other }, cfg), "a tag that does not match does not exclude")

    eq(Placement.decide(dialog, { dialog }, DB.empty(), cfg).outcome, "skip",
        "so it is never placed")

    -- Nor learned from: the DB filling with dialogs is how this started.
    local w = support.window({ class = "myvault", address = "0xd", workspace = 3 })
    w.tags = { "floating-window*" }
    local hp, h = fresh({ w }, { ignore_tags = { "^floating%-window$" } })
    h.flush_timers()
    h.handlers["window.close"](w)
    eq(next(hp.state().entries), nil, "closing a tagged window records nothing")
end

-- ------------------------------------------------------------------ the plugin's log

group("identity.render")
do
    eq(Identity.render("firefox\0tag:work"), "firefox + tag:work", "a tag key")
    eq(Identity.render("org.kde.dolphin\0dolphin /home/logan"),
        "org.kde.dolphin + dolphin /home/logan",
        "the NUL is shown, not left invisible to run two words together")
    eq(Identity.render("firefox"), "firefox", "a plain key is unchanged")
    eq(Identity.render(nil), "(none)", "nothing")
    eq(Identity.render(""), "(none)", "empty")
end

group("the log records what happened, not just that it did")
do
    local log_path = tmpfile()
    local w = support.window({ class = "okular", address = "0xa", workspace = 3 })
    local hp, h = fresh({ w }, { debug = true, log_path = log_path })

    local function log_text()
        local f = assert(io.open(log_path, "r"))
        local text = f:read("a")
        f:close()
        return text
    end

    ok(log_text():find("ready", 1, true) ~= nil,
        "loading is recorded even before anything happens")

    h.flush_timers() -- let the startup freeze lapse
    w.workspace = { id = 6 }
    h.handlers["window.move_to_workspace"](w, { id = 6 })

    local text = log_text()
    ok(text:find("learned", 1, true) ~= nil, "a learned move is recorded")
    ok(text:find("workspace 6", 1, true) ~= nil,
        "including which workspace -- the fact the line exists to record")

    -- An error must reach the file whatever `debug` says; AC-6 contains failures, and
    -- a contained failure nobody can see is barely better than a crash.
    local quiet_log = tmpfile()
    local hp2, h2 = fresh({}, { debug = false, log_path = quiet_log })
    local hostile = setmetatable({}, { __index = function() error("boom") end })
    h2.handlers["window.open_early"](hostile)

    local f = assert(io.open(quiet_log, "r"))
    local quiet = f:read("a")
    f:close()
    ok(quiet:find("error in open_early", 1, true) ~= nil,
        "the error is written with debug off")
    ok(quiet:find("skip", 1, true) == nil, "but the verbose tracing is not")
end

-- ------------------------------------------------------- workspace ids from the wild

group("workspace ids are unwrapped, whatever shape they arrive in")
do
    local hp = fresh({})
    local id_of = hp._workspace_id
    ok(id_of ~= nil, "the resolver is reachable")

    eq(id_of(7), 7, "a plain number")
    eq(id_of({ id = 7 }), 7, "a table with an id")
    eq(id_of(nil), nil, "nothing")
    eq(id_of({}), nil, "a table with no id")
    eq(id_of("22"), nil, "a string is not an id, even a numeric-looking one")
    eq(id_of(true), nil, "a value that cannot be indexed at all")
    eq(id_of({ id = "22" }), nil, "an id that is not a number")

    -- The live failure: Hyprland hands over an HL.Workspace *userdata*, so a
    -- `type(ws) == "table"` check falls through and yields the object itself. Real
    -- userdata cannot be built from pure Lua, so this cannot be reproduced exactly --
    -- which is precisely why the implementation is duck-typed on `.id` rather than
    -- testing the type. What is reproducible is the damage it caused; see below.
    local proxy = setmetatable({}, { __index = function(_, k)
        if k == "id" then return 22 end
    end })
    eq(id_of(proxy), 22, "an object that only answers through __index")
end

group("the DB refuses ids it could not read back")
do
    -- Exactly what reached the state file on the first live run:
    --   ["steam"] = { workspaces = { HL.Workspace(22:22) }, seen = ... }
    -- tostring() on a workspace object produced a token that is not Lua, so the next
    -- load() failed and silently emptied the entire DB.
    local hl_workspace = setmetatable({ id = 22 }, {
        __tostring = function() return "HL.Workspace(22:22)" end,
    })

    local state = DB.empty()
    DB.observe(state, "steam", { hl_workspace }, 100)
    eq(next(state.entries), nil, "an unusable id is dropped rather than stored")

    -- The invariant that matters, independent of how a bad value got in: whatever is
    -- in the table, what we write must be readable.
    local hostile = DB.empty()
    hostile.entries["steam"] = {
        workspaces = { 3, hl_workspace, "22", true, 4.0 }, seen = 100,
    }
    local text = DB.serialize(hostile)
    local back, corrupt = DB.deserialize(text)
    ok(not corrupt, "serialized output always parses")
    eq(back.entries["steam"].workspaces[1], 3, "the good ids survive")
    eq(#back.entries["steam"].workspaces, 2, "and the three unusable ones are gone")
    eq(back.entries["steam"].workspaces[2], 4, "a float id is written as an integer")

    DB.observe(state, "ok", { 3, 4 }, 100)
    eq(#state.entries["ok"].workspaces, 2, "ordinary ids are unaffected")
end

group("a corrupt state file is reported, not silently swallowed")
do
    local _, corrupt = DB.deserialize("return { version = 1, entries = { x = HL.Foo(1) } }")
    ok(corrupt, "unparseable content is flagged")

    local _, c2 = DB.deserialize("")
    ok(not c2, "an empty file is a first run, not corruption")
    local _, c3 = DB.deserialize(nil)
    ok(not c3, "nor is a missing one")
    local _, c4 = DB.deserialize("return 5")
    ok(c4, "valid Lua of the wrong shape is corruption")

    local state, c5 = DB.deserialize(DB.serialize(DB.empty()))
    ok(not c5, "our own output round trips clean")
    eq(next(state.entries), nil, "as empty")

    local path = tmpfile()
    local f = assert(io.open(path, "w"))
    f:write("this is not lua")
    f:close()
    local loaded, c6 = DB.load(path)
    ok(c6, "load reports it too")
    eq(next(loaded.entries), nil, "and falls back to empty")
end

-- --------------------------------------------------------------- identity: tag tier

group("the tag tier outranks cmdline and class")
do
    local cfg = Config.build({})
    local real = Identity.read_cmdline
    Identity.read_cmdline = function() return { "/usr/lib/firefox/firefox", "--new-window" } end

    -- Two windows, one process: exactly the case the cmdline tier cannot resolve.
    local a = support.window({ class = "firefox", address = "0xa", pid = 500,
        title = "[work] Inbox" })
    local b = support.window({ class = "firefox", address = "0xb", pid = 500,
        title = "[play] Reddit" })
    local windows = { a, b }

    local ka, ta = Identity.key_for(a, windows, cfg)
    local kb, tb = Identity.key_for(b, windows, cfg)
    eq(ta, "tag", "a tagged window uses the tag tier")
    eq(tb, "tag", "so does the other")
    eq(ka, "firefox\0tag:work", "keyed by class and tag")
    ok(ka ~= kb, "two windows of one process now have different identities")

    -- The same two windows without tags collapse, which is the problem tier 0 solves.
    a.title, b.title = "Inbox", "Reddit"
    eq(Identity.key_for(a, windows, cfg), Identity.key_for(b, windows, cfg),
        "untagged, they are indistinguishable")
    eq(select(2, Identity.key_for(a, windows, cfg)), "class", "falling back to class")

    -- A tag outranks a perfectly good cmdline, too.
    local solo = support.window({ class = "kitty", address = "0xc", pid = 900,
        title = "[term] btop" })
    Identity.read_cmdline = function() return { "/usr/bin/kitty", "btop" } end
    eq(select(2, Identity.key_for(solo, { solo }, cfg)), "tag",
        "a tag wins over a distinguishing cmdline")
    solo.title = "btop"
    eq(select(2, Identity.key_for(solo, { solo }, cfg)), "cmdline",
        "and without it the cmdline tier still works")

    Identity.read_cmdline = real
end

group("a tag cannot be confused with a cmdline")
do
    local cfg = Config.build({})
    local real = Identity.read_cmdline
    -- A binary whose normalized cmdline is exactly what a tag key looks like.
    Identity.read_cmdline = function() return { "/usr/bin/thing", "tag:work" } end

    local spoof = support.window({ class = "firefox", address = "0xa", pid = 1,
        title = "no tag here" })
    local tagged = support.window({ class = "firefox", address = "0xb", pid = 2,
        title = "[work] x" })

    local spoofed = Identity.key_for(spoof, { spoof }, cfg)
    local genuine = Identity.key_for(tagged, { tagged }, cfg)
    eq(spoofed, "firefox\0thing tag:work", "the cmdline keeps its binary name")
    eq(genuine, "firefox\0tag:work", "so it cannot collide with a tag key")
    ok(spoofed ~= genuine, "the two identities stay distinct")

    Identity.read_cmdline = real
end

group("require_cmdline accepts a tag as identity")
do
    local cfg = Config.build({ require_cmdline = { "^kitty$" } })
    local real = Identity.read_cmdline
    Identity.read_cmdline = function() return { "/usr/bin/kitty" } end

    local bare = support.window({ class = "kitty", address = "0xa", pid = 1, title = "~" })
    ok(not Policy.decide(bare, { bare }, cfg), "a bare terminal is still excluded")

    -- A tag answers the question require_cmdline is really asking: is this window
    -- distinguishable from every other window of its class?
    local tagged = support.window({ class = "kitty", address = "0xb", pid = 2,
        title = "[logs] ~" })
    ok(Policy.decide(tagged, { tagged }, cfg), "a tagged one is tracked on its tag alone")

    Identity.read_cmdline = real
end

group("losing a tag is a different identity, not a lost one")
do
    -- Disabling the extension, or a rename: the window simply keys differently, and
    -- the abandoned entry expires under the TTL. No migration logic needed.
    local cfg = Config.build({})
    local real = Identity.read_cmdline
    Identity.read_cmdline = function() return nil end

    local w = support.window({ class = "firefox", address = "0xa", pid = 1,
        title = "[work] Inbox" })
    eq(Identity.key_for(w, { w }, cfg), "firefox\0tag:work", "tagged")
    w.title = "[home] Inbox"
    eq(Identity.key_for(w, { w }, cfg), "firefox\0tag:home", "renamed is a new key")
    w.title = "Inbox"
    eq(Identity.key_for(w, { w }, cfg), "firefox", "untagged falls back to the class")

    Identity.read_cmdline = real
end

-- ------------------------------------------------------------------- deferral (pure)

group("placement defers an unidentifiable window")
do
    local cfg = Config.build({ defer_classes = { "^firefox$" }, defer_timeout_ms = 3000 })
    local state = { version = 1, entries = {} }
    DB.observe(state, "firefox", { 3 }, os.time())
    DB.observe(state, "firefox\0tag:work", { 5 }, os.time())

    local untagged = support.window({ class = "firefox", address = "0xa", workspace = 9 })
    local v = Placement.decide(untagged, { untagged }, state, cfg)
    eq(v.outcome, "defer", "an untagged firefox window is deferred")
    ok(v.detail:find("3000") ~= nil, "and says how long it will wait")
    eq(v.target, nil, "with no target chosen yet")

    local tagged = support.window({ class = "firefox", address = "0xb", workspace = 9,
        title = "[work] Inbox" })
    local tv = Placement.decide(tagged, { tagged }, state, cfg)
    eq(tv.outcome, "move", "a tagged firefox window decides immediately")
    eq(tv.tag, "work", "and the verdict carries the tag")
    eq(tv.target, 5, "placed by its own tag, not by what the class remembers")
    eq(tv.key, "firefox\0tag:work", "on the tag key")

    local kitty = support.window({ class = "kitty", address = "0xc", workspace = 9 })
    ok(Placement.decide(kitty, { kitty }, state, cfg).outcome ~= "defer",
        "a class not in defer_classes is never deferred")

    -- The timeout path: same call, deferral spent.
    local final = Placement.decide(untagged, { untagged }, state, cfg, { may_defer = false })
    eq(final.outcome, "move", "with may_defer false it decides on what is known")
    eq(final.target, 3, "which is the class-only placement")

    -- Deferral must not resurrect a window policy has already excluded.
    local ignored = Config.build({ defer_classes = { "^firefox$" },
        ignore_classes = { "^firefox$" } })
    eq(Placement.decide(untagged, { untagged }, state, ignored).outcome, "skip",
        "an ignored class is skipped, not deferred")
end

group("deferral is off by default")
do
    local cfg = Config.build({})
    local w = support.window({ class = "firefox", address = "0xa", workspace = 9 })
    eq(Placement.incomplete(w, cfg), false, "no defer_classes means nothing is deferred")
end

-- ----------------------------------------------------------------- deferral (plugin)

--- Set up a plugin with one deferrable firefox window remembered on workspace 3.
local function deferring(title)
    local w = support.window({ class = "firefox", address = "0xa", workspace = 9,
        title = title or "" })
    local hp, h, path = fresh({ w }, {
        defer_classes = { "^firefox$" },
        defer_timeout_ms = 1000,
        defer_poll_ms = 250,
    })
    DB.observe(hp.state(), "firefox", { 3 }, os.time())
    return w, hp, h, path
end

group("deferral holds a window instead of placing it")
do
    local w, hp, h = deferring()
    h.handlers["window.open_early"](w)

    eq(#h.dispatched, 0, "nothing is dispatched at open")
    ok(h.handlers["window.title"] ~= nil, "and window.title is subscribed while waiting")

    -- 1000ms timeout at 250ms per sweep is four ticks.
    for _ = 1, 3 do h.flush_timers() end
    eq(#h.dispatched, 0, "still waiting before the deadline")

    h.flush_timers()
    eq(#h.dispatched, 1, "placed when the deadline passes")
    eq(h.dispatched[1].args.workspace, 3, "on the remembered workspace")
    eq(h.handlers["window.title"], nil, "and the title subscription is dropped again")
end

group("deferral acts as soon as the identity arrives")
do
    local w, hp, h = deferring()
    DB.observe(hp.state(), "firefox\0tag:work", { 5 }, os.time())
    h.handlers["window.open_early"](w)
    eq(#h.dispatched, 0, "waiting")

    -- The extension applies its preface; the compositor reports a title change.
    w.title = "[work] Inbox - Mozilla Firefox"
    h.handlers["window.title"](w)

    eq(#h.dispatched, 1, "placed immediately, without waiting for the deadline")
    -- 5, not the 3 the bare `firefox` key remembers: waiting is what bought the tag.
    eq(h.dispatched[1].args.workspace, 5, "on the workspace its own tag remembers")
    eq(h.handlers["window.title"], nil, "the subscription is released")

    -- The deadline must not then fire a second placement.
    for _ = 1, 6 do h.flush_timers() end
    eq(#h.dispatched, 1, "and the expired deadline does not place it again")
end

group("a title change that is still untagged keeps waiting")
do
    local w, hp, h = deferring()
    h.handlers["window.open_early"](w)

    w.title = "Loading - Mozilla Firefox"
    h.handlers["window.title"](w)
    eq(#h.dispatched, 0, "an untagged title change is not an identity")
    ok(h.handlers["window.title"] ~= nil, "so it is still waiting")
end

group("a user move cancels a pending placement (AC-4)")
do
    local w, hp, h = deferring()
    h.handlers["window.open_early"](w)

    -- The user drags it somewhere while hyprplace is still waiting.
    w.workspace = { id = 7 }
    h.handlers["window.move_to_workspace"](w, { id = 7 })

    eq(h.handlers["window.title"], nil, "the deferral is dropped")
    for _ = 1, 6 do h.flush_timers() end
    eq(#h.dispatched, 0, "and hyprplace never places it")
end

group("cancellation survives the startup freeze")
do
    -- setup() starts frozen, so this move is not learned from -- but it is still the
    -- user touching the window, and AC-4 outranks the freeze.
    local w, hp, h = deferring()
    h.handlers["window.open_early"](w)
    h.handlers["window.move_to_workspace"](w, { id = 7 })
    for _ = 1, 6 do h.flush_timers() end
    eq(#h.dispatched, 0, "a move during the settle window still cancels")
end

group("a mass move does not cancel a pending placement")
do
    -- hyprsplit reflow does not carry focus, and must not be mistaken for user intent.
    local w, hp, h = deferring()
    h.handlers["window.open_early"](w)
    w.active = false
    h.handlers["window.move_to_workspace"](w, { id = 7 })
    w.active = true

    for _ = 1, 4 do h.flush_timers() end
    eq(#h.dispatched, 1, "the window is still placed when the deadline passes")
end

group("closing a pending window cancels it")
do
    local w, hp, h = deferring()
    h.handlers["window.open_early"](w)
    h.handlers["window.close"](w)

    eq(h.handlers["window.title"], nil, "the deferral is dropped")
    for _ = 1, 6 do h.flush_timers() end
    eq(#h.dispatched, 0, "nothing is dispatched for a window that is gone")
end

group("a window that vanishes before its deadline is not placed")
do
    local w, hp, h = deferring()
    h.handlers["window.open_early"](w)
    -- Gone from the compositor without a close event reaching us.
    h.windows = {}
    for _ = 1, 6 do h.flush_timers() end
    eq(#h.dispatched, 0, "the address no longer resolves, so nothing is dispatched")
end

group("shutdown abandons pending placements")
do
    local w, hp, h = deferring()
    h.handlers["window.open_early"](w)
    h.handlers["hyprland.shutdown"]()

    eq(h.handlers["window.title"], nil, "the subscription is released")
    for _ = 1, 6 do h.flush_timers() end
    eq(#h.dispatched, 0, "teardown never places anything")
end

group("two pending windows are tracked independently")
do
    local a = support.window({ class = "firefox", address = "0xa", workspace = 9 })
    local b = support.window({ class = "firefox", address = "0xb", workspace = 9 })
    local hp, h = fresh({ a, b }, {
        defer_classes = { "^firefox$" }, defer_timeout_ms = 1000, defer_poll_ms = 250,
    })
    DB.observe(hp.state(), "firefox", { 3, 4 }, os.time())

    h.handlers["window.open_early"](a)
    h.handlers["window.open_early"](b)
    eq(#h.dispatched, 0, "both are waiting")

    DB.observe(hp.state(), "firefox\0tag:one", { 21 }, os.time())
    a.title = "[one] x"
    h.handlers["window.title"](a)
    eq(#h.dispatched, 1, "resolving one does not resolve the other")
    ok(h.handlers["window.title"] ~= nil, "and the subscription is held for the other")

    for _ = 1, 4 do h.flush_timers() end
    eq(#h.dispatched, 2, "the second is placed at its deadline")
    eq(h.handlers["window.title"], nil, "only then is the subscription released")

    -- The payoff of tier 0: the tagged window goes where *it* belongs, and the
    -- untagged one falls back to the class key's slots. They are different
    -- identities, so they no longer compete for the same remembered positions.
    eq(h.dispatched[1].args.workspace, 21, "the tagged window goes where its tag says")
    eq(h.dispatched[2].args.workspace, 3, "the untagged one takes a class-key slot")
end

-- ----------------------------------------------------------------------------- json

local Json = require("hyprplace.json")

group("json scalars")
do
    eq(Json.decode("1"), 1, "integer")
    eq(Json.decode("-2.5"), -2.5, "negative float")
    eq(Json.decode("1e3"), 1000, "exponent")
    eq(Json.decode("true"), true, "true")
    eq(Json.decode("false"), false, "false")
    eq(Json.decode('"hi"'), "hi", "string")
    eq(tostring(Json.decode("null")), "null", "null is a sentinel, not nil")
    eq(Json.decode('  7  '), 7, "surrounding whitespace")
end

group("json strings")
do
    eq(Json.decode([["a\nb"]]), "a\nb", "escape sequences")
    eq(Json.decode([["q\"q"]]), 'q"q', "escaped quote")
    eq(Json.decode([["\u00e9"]]), "é", "\\u escape")
    eq(Json.decode([["\ud83d\ude00"]]), "😀", "surrogate pair")
    eq(Json.decode('"~/workspace/hyprplace"'), "~/workspace/hyprplace", "plain path")
end

group("json structures")
do
    local a = Json.decode("[1,2,3]")
    eq(#a, 3, "array length")
    eq(a[2], 2, "array indexing is 1-based")
    eq(#Json.decode("[]"), 0, "empty array")
    eq(next(Json.decode("{}")), nil, "empty object")

    local o = Json.decode('{"a":{"b":[1,{"c":true}]}}')
    eq(o.a.b[2].c, true, "nested access")

    -- Shaped like real hyprctl output.
    local clients = Json.decode(
        '[{"address":"0x1","class":"kitty","pid":100,"workspace":{"id":3,"name":"3"},"floating":false}]')
    eq(clients[1].class, "kitty", "client class")
    eq(clients[1].workspace.id, 3, "nested workspace id")
    eq(clients[1].floating, false, "false is preserved, not treated as absent")
end

group("json rejects bad input")
do
    ok(Json.decode("{") == nil, "truncated object")
    ok(Json.decode("[1,]") == nil, "trailing comma")
    ok(Json.decode('{"a" 1}') == nil, "missing colon")
    ok(Json.decode('"unterminated') == nil, "unterminated string")
    ok(Json.decode("1 2") == nil, "trailing content")
    ok(Json.decode(nil) == nil, "non-string input")
    local _, err = Json.decode("{")
    ok(type(err) == "string" and err:match("json"), "returns an error message")
end

-- ------------------------------------------------------------------------------ cli

local CLI = require("hyprplace.cli")

group("cli.hyprctl_cmd")
do
    eq(CLI.hyprctl_cmd({}, "clients"), "hyprctl -j clients", "plain live query")
    ok(CLI.hyprctl_cmd({ instance = "abc" }, "clients"):match('-i "abc"'), "targets an instance")
    ok(CLI.hyprctl_cmd({ runtime = "/run/x" }, "clients"):match('^XDG_RUNTIME_DIR="/run/x"'),
        "sets the runtime dir")
    ok(not CLI.hyprctl_cmd({}, "clients"):match("dispatch"), "never dispatches")
end

group("cli.fingerprint_rows")
do
    local real = Identity.read_cmdline
    Identity.read_cmdline = function(pid)
        if pid == 100 then return { "uwsm", "app", "--", "kitty", "btop" } end
        return { "firefox" }
    end
    local cfg = Config.build({ ignore_classes = { "^hyprland%-run$" } })

    local btop = support.window({ class = "kitty", pid = 100, address = "0xa", workspace = 21 })
    local ff   = support.window({ class = "firefox", pid = 200, address = "0xb", workspace = 1 })
    local run  = support.window({ class = "hyprland-run", pid = 300, address = "0xc", workspace = 1 })
    local rows = CLI.fingerprint_rows({ btop, ff, run }, cfg)

    eq(#rows, 3, "one row per window")
    eq(rows[1].key, "kitty\0kitty btop", "wrapper stripped in the derived key")
    eq(rows[1].tier, "cmdline", "reports the matching tier")
    eq(rows[1].would_record, 21, "would record the current workspace")
    eq(rows[2].tier, "class", "firefox falls back to class tier")
    ok(not rows[3].tracked, "ignored class is not tracked")
    eq(rows[3].would_record, nil, "and would record nothing")
    eq(rows[3].reason, Policy.IGNORED, "with the reason given")

    Identity.read_cmdline = real
end

group("cli.plan_rows")
do
    -- Without this the real /proc is read for these fake pids, and pid 1 (systemd) has a
    -- multi-argument cmdline, which would push every key into the cmdline tier.
    local real = Identity.read_cmdline
    Identity.read_cmdline = function() return nil end

    local cfg = Config.build({})
    local state = DB.empty()
    DB.observe(state, "firefox", { 3 }, os.time(), 8)

    local w = support.window({ class = "firefox", pid = 1, address = "0xa", workspace = 9 })
    local rows = CLI.plan_rows({ w }, state, cfg)
    eq(rows[1].outcome, "move", "would move to the remembered workspace")
    eq(rows[1].target, 3, "target is the remembered workspace")

    local at_home = support.window({ class = "firefox", pid = 1, address = "0xa", workspace = 3 })
    eq(CLI.plan_rows({ at_home }, state, cfg)[1].outcome, "stay", "already correct -> stay")

    local unknown = support.window({ class = "nope", pid = 1, address = "0xa", workspace = 1 })
    local r = CLI.plan_rows({ unknown }, state, cfg)[1]
    eq(r.outcome, "skip", "unknown app -> skip")
    ok(r.detail:match("no record"), "and says why")

    -- Two windows of one app, one remembered slot: the second has nowhere to go.
    local a = support.window({ class = "firefox", pid = 1, address = "0xa", workspace = 3 })
    local b = support.window({ class = "firefox", pid = 2, address = "0xb", workspace = 9 })
    local rows2 = CLI.plan_rows({ a, b }, state, cfg)
    eq(rows2[2].outcome, "skip", "second instance has no free remembered slot")
    ok(rows2[2].detail:match("filled"), "and says the slots are filled")

    Identity.read_cmdline = real
end

group("cli.db_rows")
do
    local cfg = Config.build({ ttl_days = 90 })
    local now = 1000000
    local state = DB.empty()
    DB.observe(state, "old", { 1 }, now - (10 * 86400), 8)
    DB.observe(state, "new", { 2 }, now)
    local rows = CLI.db_rows(state, cfg, now)
    eq(#rows, 2, "one row per entry")
    eq(rows[1].key, "new", "newest first")
    ok(math.abs(rows[2].age_days - 10) < 0.01, "age in days")
    ok(math.abs(rows[2].expires_in - 80) < 0.01, "expiry countdown")

    eq(CLI.db_rows(state, Config.build({ ttl_days = 0 }), now)[1].expires_in, nil,
        "no expiry shown when ttl is disabled")
end

group("json against real hyprctl output")
do
    -- tests/fixtures/clients.json is genuine `hyprctl -j clients` output, redacted.
    -- Synthetic fixtures cannot catch a real-world shape we failed to imagine.
    local f = assert(io.open(ROOT .. "/tests/fixtures/clients.json", "r"))
    local raw = f:read("a")
    f:close()

    local clients, err = Json.decode(raw)
    ok(clients ~= nil, "real output decodes (" .. tostring(err) .. ")")
    eq(#clients, 3, "all clients present")

    local by_class = {}
    for _, c in ipairs(clients) do by_class[c.class] = c end

    ok(by_class["kitty"] ~= nil, "kitty client found")
    eq(by_class["kitty"].workspace.id, 21, "nested workspace id survives")
    eq(by_class["kitty"].title, 'btop — "live" \\ stats 😀',
        "escaped quote, backslash, em dash and emoji all round-trip")
    eq(by_class["kitty"].floating, false, "false is preserved, not read as absent")
    eq(type(by_class["kitty"].at), "table", "array-valued fields decode as tables")
    eq(#by_class["kitty"].at, 2, "position is a two-element array")
    ok(by_class["kitty"].pid > 0, "pid is a number")
    eq(by_class["kitty"].xdgTag, "", "empty strings decode as empty, not nil")

    -- And it feeds the real pipeline.
    local windows = {}
    for _, c in ipairs(clients) do
        windows[#windows + 1] = {
            address = c.address, class = c.class, initial_class = c.initialClass,
            title = c.title, pid = c.pid,
            workspace = c.workspace and { id = c.workspace.id } or nil,
        }
    end
    local real_read = Identity.read_cmdline
    Identity.read_cmdline = function() return nil end
    local rows = CLI.fingerprint_rows(windows, Config.build({}))
    eq(#rows, 3, "fingerprint accepts windows built from real output")
    ok(rows[1].key ~= nil, "and derives a key from them")
    Identity.read_cmdline = real_read
end

group("cli.live_distribution")
do
    local real = Identity.read_cmdline
    Identity.read_cmdline = function() return nil end
    local cfg = Config.build({ ignore_classes = { "^hyprland%-run$" } })
    local wins = {
        support.window({ class = "firefox", pid = 1, address = "0xa", workspace = 4 }),
        support.window({ class = "firefox", pid = 2, address = "0xb", workspace = 3 }),
        support.window({ class = "firefox", pid = 3, address = "0xc", workspace = 3 }),
        support.window({ class = "hyprland-run", pid = 4, address = "0xd", workspace = 1 }),
    }
    local dist = CLI.live_distribution(wins, cfg)
    eq(#dist["firefox"], 3, "duplicates preserved")
    eq(dist["firefox"][1], 3, "sorted ascending")
    eq(dist["firefox"][3], 4, "sorted ascending")
    eq(dist["hyprland-run"], nil, "ignored classes excluded")
    Identity.read_cmdline = real
end

group("cli.diff_rows")
do
    local real = Identity.read_cmdline
    Identity.read_cmdline = function() return nil end
    local cfg = Config.build({})
    local state = DB.empty()
    DB.observe(state, "firefox", { 3, 3 }, os.time(), 8)
    DB.observe(state, "signal", { 33 }, os.time(), 8)
    DB.observe(state, "discord", { 31 }, os.time(), 8)

    local wins = {
        support.window({ class = "firefox", pid = 1, address = "0xa", workspace = 3 }),
        support.window({ class = "firefox", pid = 2, address = "0xb", workspace = 3 }),
        support.window({ class = "signal",  pid = 3, address = "0xc", workspace = 1 }),
        support.window({ class = "steam",   pid = 4, address = "0xd", workspace = 22 }),
    }
    local by_key = {}
    for _, r in ipairs(CLI.diff_rows(wins, state, cfg)) do by_key[r.key] = r end

    eq(by_key["firefox"].status, "match", "identical distributions match")
    eq(by_key["signal"].status, "differs", "signal is running somewhere unexpected")
    eq(by_key["signal"].actual[1], 1, "reports where it actually is")
    eq(by_key["signal"].remembered[1], 33, "and where it was remembered")
    eq(by_key["steam"].status, "unlearned", "running but never recorded")
    eq(by_key["discord"].status, "absent", "recorded but not running")

    eq(CLI.diff_rows(wins, state, cfg)[1].status, "differs", "disagreements sort first")
    Identity.read_cmdline = real
end

group("cli.expired_rows")
do
    local now = 1000000
    local cfg = Config.build({ ttl_days = 90 })
    local state = DB.empty()
    DB.observe(state, "fresh", { 1 }, now - 86400)
    DB.observe(state, "stale", { 1 }, now - (100 * 86400), 8)
    local rows = CLI.expired_rows(state, cfg, now)
    eq(#rows, 1, "one entry expired")
    eq(rows[1].key, "stale", "the stale one")
    eq(#CLI.expired_rows(state, Config.build({ ttl_days = 0 }), now), 0,
        "ttl disabled -> nothing expires")
end

group("cli.window_delta reports title changes")
do
    local function snap(title, ws)
        return { support.window({ class = "firefox", address = "0xa",
            workspace = ws or 3, title = title }) }
    end

    local d = CLI.window_delta(snap("Inbox"), snap("[work] Inbox"))
    eq(#d.retitled, 1, "a title change is reported")
    eq(d.retitled[1].from, "Inbox", "with the old title")
    eq(d.retitled[1].to, "[work] Inbox", "and the new one")
    eq(d.retitled[1].from_tag, nil, "untagged before")
    eq(d.retitled[1].to_tag, "work", "tagged after")
    ok(d.retitled[1].tagged, "and flagged as an identity change")

    -- The common case, and the reason watch filters: navigation.
    d = CLI.window_delta(snap("[work] Inbox"), snap("[work] Reddit"))
    eq(#d.retitled, 1, "a page change is still reported")
    ok(not d.retitled[1].tagged, "but is not an identity change")

    d = CLI.window_delta(snap("[work] x"), snap("[home] x"))
    ok(d.retitled[1].tagged, "a rename is an identity change")

    d = CLI.window_delta(snap("[work] x"), snap("x"))
    eq(d.retitled[1].to_tag, nil, "losing a tag is reported")
    ok(d.retitled[1].tagged, "and is an identity change")

    eq(#CLI.window_delta(snap("same"), snap("same")).retitled, 0,
        "an unchanged title is not a change")

    -- A window can be dragged and retitled between two polls; both happened.
    d = CLI.window_delta(snap("a", 3), snap("b", 4))
    eq(#d.moved, 1, "the move is reported")
    eq(#d.retitled, 1, "and so is the retitle")

    eq(#CLI.window_delta(nil, snap("x")).retitled, 0,
        "the first poll has nothing to compare against")
end

group("cli.window_delta")
do
    local a = support.window({ class = "kitty", address = "0xa", workspace = 1 })
    local b = support.window({ class = "firefox", address = "0xb", workspace = 2 })
    local b_moved = support.window({ class = "firefox", address = "0xb", workspace = 5 })

    local first = CLI.window_delta(nil, { a })
    eq(#first.appeared, 0, "the first snapshot reports nothing as new")

    local d = CLI.window_delta({ a, b }, { a, b_moved })
    eq(#d.moved, 1, "detects a move")
    eq(d.moved[1].from, 2, "from workspace")
    eq(d.moved[1].to, 5, "to workspace")
    eq(#d.appeared, 0, "no spurious appearances")

    local d2 = CLI.window_delta({ a }, { a, b })
    eq(#d2.appeared, 1, "detects a new window")
    eq(d2.appeared[1].address, "0xb", "the right one")

    local d3 = CLI.window_delta({ a, b }, { a })
    eq(#d3.vanished, 1, "detects a closed window")
    eq(d3.vanished[1].address, "0xb", "the right one")
end

group("plugin and tools share one placement decision")
do
    -- The point of Placement.decide: what `hyprplace plan` prints is produced by the
    -- same call the plugin acts on, so the tools cannot drift from reality.
    local real = Identity.read_cmdline
    Identity.read_cmdline = function() return nil end
    local cfg = Config.build({})
    local state = DB.empty()
    DB.observe(state, "firefox", { 3 }, os.time())

    local w = support.window({ class = "firefox", pid = 1, address = "0xa", workspace = 9 })
    local windows = { w }

    local direct = Placement.decide(w, windows, state, cfg)
    local viaCli = CLI.plan_rows(windows, state, cfg)[1]
    eq(viaCli.outcome, direct.outcome, "same outcome")
    eq(viaCli.target, direct.target, "same target")
    eq(viaCli.detail, direct.detail, "same explanation")

    -- And the plugin acts on exactly that verdict.
    local hp, h = fresh(windows)
    DB.observe(hp.state(), "firefox", { 3 }, os.time())
    h.handlers["window.open_early"](w)
    eq(h.dispatched[1].args.workspace, direct.target,
        "the plugin dispatches the target the tools predicted")

    Identity.read_cmdline = real
end

group("cli.would_record")
do
    local real = Identity.read_cmdline
    Identity.read_cmdline = function() return nil end
    local cfg = Config.build({ ignore_classes = { "^hyprland%-run$" } })

    -- Three firefox windows on 3,3,4. Moving the one on 4 to 5 should predict the whole
    -- new distribution, not just the moved window's destination.
    local a = support.window({ class = "firefox", pid = 1, address = "0xa", workspace = 3 })
    local b = support.window({ class = "firefox", pid = 2, address = "0xb", workspace = 3 })
    local c = support.window({ class = "firefox", pid = 3, address = "0xc", workspace = 4 })
    local wins = { a, b, c }

    local rec = CLI.would_record(c, wins, 5, cfg)
    eq(CLI.show_list(rec.distribution), "3,3,5",
        "the mover contributes its destination, the others their current workspaces")
    eq(rec.key, "firefox", "key reported")
    ok(rec.tracked, "tracked")

    -- Moving it back predicts the original distribution again.
    eq(CLI.show_list(CLI.would_record(c, wins, 4, cfg).distribution), "3,3,4",
        "moving back predicts the original distribution")

    local ignored = support.window({ class = "hyprland-run", pid = 9, address = "0xz", workspace = 1 })
    local r2 = CLI.would_record(ignored, { ignored }, 1, cfg)
    eq(r2.distribution, nil, "an ignored window predicts no record")
    eq(r2.reason, Policy.IGNORED, "and reports why")

    Identity.read_cmdline = real
end

group("learn.distribution")
do
    local Learn = require("hyprplace.learn")
    local key_of = function(w) return w.class end
    local a = support.window({ class = "kitty", address = "0xa", workspace = 1 })
    local b = support.window({ class = "kitty", address = "0xb", workspace = 2 })

    eq(CLI.show_list(Learn.distribution(a, { a, b }, 9, "kitty", key_of)), "2,9",
        "subject contributes its new workspace, sorted")
    eq(CLI.show_list(Learn.distribution(a, {}, 7, "kitty", key_of)), "7",
        "a subject absent from the list still contributes")
    eq(CLI.show_list(Learn.distribution(a, { b }, 7, "kitty", key_of)), "2,7",
        "absent subject is added alongside the others")
end

group("cli.show_list and short_title")
do
    eq(CLI.show_list({ 3, 3, 4 }), "3,3,4", "duplicates shown")
    eq(CLI.show_list({}), "-", "empty list")
    eq(CLI.show_list(nil), "-", "nil list")
    eq(CLI.short_title(nil), "", "nil title")
    eq(CLI.short_title("short", 44), "short", "short titles pass through")
    ok(#CLI.short_title(string.rep("x", 100), 20) <= 22, "long titles are truncated")
end

group("cli.show_key")
do
    eq(CLI.show_key("kitty\0kitty btop"), "kitty + kitty btop", "NUL rendered readably")
    eq(CLI.show_key("firefox"), "firefox", "plain key unchanged")
    eq(CLI.show_key("firefox\0tag:f533cc25"), "firefox + tag:f533cc25",
        "a tag key reads as well as a cmdline one does")
    eq(CLI.show_key(nil), "(none)", "nil key")
end

-- ------------------------------------------------------------------------ installer

local Installer = require("hyprplace.installer")

group("installer block editing")
do
    local original = '-- my config\nrequire("monitors")\nrequire("binds")\n'

    ok(not Installer.has_block(original), "clean config has no block")
    ok(not Installer.has_block(""), "empty config has no block")

    local wired, changed, err = Installer.upsert_block(original)
    ok(changed, "wiring reports a change")
    eq(err, nil, "wiring a clean file is not an error")
    ok(Installer.has_block(wired), "block is present afterwards")
    ok(wired:find(Installer.CALL, 1, true) ~= nil, "the setup call is there")
    ok(wired:find(Installer.CFG_BEGIN, 1, true) ~= nil, "with a config section")
    ok(wired:sub(1, #original) == original, "existing content is untouched at the front")
    ok(Installer.validate(wired), "the result parses as Lua")

    local again, changed2 = Installer.upsert_block(wired)
    ok(not changed2, "re-wiring reports no change")
    eq(again, wired, "and is byte-identical -- idempotent")

    -- The round trip that matters: uninstall must give back exactly what we found.
    eq(Installer.remove_block(wired), original, "removal restores the original byte for byte")
    eq(Installer.remove_block(original), original, "removing an absent block changes nothing")
end

group("installer preserves the config section")
do
    local wired = Installer.upsert_block('require("binds")\n')
    -- Stand in for a user editing between the inner markers.
    local edited = wired:gsub(
        Installer.CFG_BEGIN:gsub("%p", "%%%0") .. ".-" .. Installer.CFG_END:gsub("%p", "%%%0"),
        Installer.CFG_BEGIN .. "\n    ttl_days = 30,\n    debug = true,\n" .. Installer.CFG_END,
        1)
    ok(edited:find("ttl_days = 30", 1, true) ~= nil, "the fixture really was edited")

    local cfg = Installer.config_of(edited)
    eq(#cfg, 2, "both config lines are found")
    eq(cfg[1], "    ttl_days = 30,", "verbatim, indentation included")

    local again, changed, uerr = Installer.upsert_block(edited)
    eq(uerr, nil, "re-running over an edited config is not an error")
    ok(not changed, "re-running over an edited config changes nothing")
    eq(again, edited, "the user's settings survive byte for byte")

    -- The scaffolding is still regenerated even when the config is kept.
    local broken = edited:gsub('require%("hyprplace"%)%.setup%(hyprplace_cfg%)', "print('oops')", 1)
    local fixed, ch2 = Installer.upsert_block(broken)
    ok(ch2, "a damaged setup call is reported as changed")
    ok(fixed:find(Installer.CALL, 1, true) ~= nil, "and is restored")
    ok(not fixed:find("oops", 1, true), "with the junk gone")
    ok(fixed:find("ttl_days = 30", 1, true) ~= nil, "while the config is still preserved")
end

group("installer refuses rather than clobbering")
do
    local function refuses(text, what)
        local result, _, err = Installer.upsert_block(text)
        ok(result == nil and err ~= nil, what)
    end

    local wired = Installer.upsert_block("")

    refuses(wired .. wired, "two blocks")
    refuses(wired:gsub(Installer.END:gsub("%p", "%%%0"), "", 1), "block with no closing marker")
    refuses(Installer.END .. "\n", "closing marker with no block")
    refuses(wired:gsub(Installer.CFG_END:gsub("%p", "%%%0"), "", 1),
        "config section with no closing marker")
    refuses(Installer.CFG_BEGIN .. "\n" .. Installer.CFG_END .. "\n",
        "config markers outside any block")
    refuses(Installer.END .. "\n" .. Installer.BEGIN .. "\n", "markers in the wrong order")

    -- A block with no config section that is not a recognisable older one: someone
    -- has hand-written something in there and we must not destroy it.
    local handmade = Installer.BEGIN .. "\nrequire('hyprplace').setup({ ttl_days = 1 })\n"
        .. Installer.END .. "\n"
    refuses(handmade, "a hand-edited block with no config section")

    local result, _, err = Installer.upsert_block(handmade)
    ok(err:find("hand%-edited") ~= nil, "and says why")
    eq(result, nil, "returning no replacement text at all")
end

group("installer upgrades a pristine older block")
do
    -- Exactly what versions before the config section wrote. Nothing of the user's
    -- is in there, so rewriting it loses nothing.
    local old = 'require("binds")\n\n' .. Installer.BEGIN .. "\n"
        .. Installer.LEGACY_CALL .. "\n" .. Installer.END .. "\n"

    local upgraded, changed, err = Installer.upsert_block(old)
    eq(err, nil, "an old block is not an error")
    ok(changed, "it is reported as changed")
    ok(upgraded:find(Installer.CFG_BEGIN, 1, true) ~= nil, "a config section is added")
    ok(upgraded:find(Installer.CALL, 1, true) ~= nil, "and the call is updated")
    eq(select(2, upgraded:gsub(Installer.BEGIN, "")), 1, "still exactly one block")
    eq(Installer.remove_block(upgraded), 'require("binds")\n',
        "and it still uninstalls cleanly")
end

group("installer handles awkward files")
do
    local no_newline = 'require("binds")'
    local wired = Installer.upsert_block(no_newline)
    ok(Installer.has_block(wired), "a file with no trailing newline still gets wired")
    eq(Installer.remove_block(wired), no_newline .. "\n",
        "and unwiring yields the content with a newline")

    eq(Installer.remove_block(Installer.upsert_block("")), "", "empty file round trips to empty")
end

group("installer validates the result")
do
    ok(Installer.validate('require("binds")\n'), "valid Lua passes")
    ok(Installer.validate(Installer.block()), "a generated block is valid Lua on its own")

    local wired = Installer.upsert_block("")
    local unbalanced = wired:gsub(Installer.CFG_BEGIN:gsub("%p", "%%%0"),
        Installer.CFG_BEGIN .. "\n    ignore_classes = { \"^x$\",\n", 1)
    local rebuilt = Installer.upsert_block(unbalanced)
    local parses, verr = Installer.validate(rebuilt)
    ok(not parses, "an unbalanced brace in the config section is caught")
    ok(verr ~= nil and verr:find("hyprland.lua") ~= nil, "and reported against hyprland.lua")
end


group("installer shell quoting")
do
    eq(Installer.shell_quote("/plain/path"), "'/plain/path'", "plain path")
    eq(Installer.shell_quote("has space"), "'has space'", "spaces")
    eq(Installer.shell_quote("it's"), [['it'\''s']], "embedded single quote is escaped")
end

group("installer module list matches the Makefile")
do
    -- Two lists of the same files will drift; this catches it.
    local f = assert(io.open(ROOT .. "/Makefile", "r"))
    local mk = f:read("a")
    f:close()
    local src_line = mk:match("SRC%s*:=%s*([^\n]+)")
    ok(src_line ~= nil, "found SRC in the Makefile")

    local in_make = {}
    for name in src_line:gmatch("(%S+)") do in_make[name] = true end
    for _, m in ipairs(Installer.MODULES) do
        ok(in_make[m], m .. " is in the Makefile SRC list")
        in_make[m] = nil
    end
    eq(next(in_make), nil, "the Makefile lists nothing the installer would miss")
end

-- ---------------------------------------------------------------------- config cache

local Cache = require("hyprplace.cache")

group("cache round trip")
do
    local cfg = Config.build({
        defer_classes = { "^firefox$" },
        require_cmdline = { "^kitty$" },
        keep_flags = { kitty = { "^%-%-working%-directory=" } },
        ttl_days = 30,
        debug = true,
    })
    local back = Cache.deserialize(Cache.serialize(cfg))
    ok(back ~= nil, "a serialized config parses back")
    eq(back.ttl_days, 30, "numbers survive")
    eq(back.debug, true, "booleans survive")
    eq(back.defer_classes[1], "^firefox$", "arrays of patterns survive")
    eq(back.keep_flags.kitty[1], "^%-%-working%-directory=", "nested tables survive")
    eq(back.db_path, cfg.db_path, "paths survive")

    eq(Cache.serialize(cfg), Cache.serialize(Config.build(cfg)),
        "serialization is stable -- an unchanged config produces identical bytes")
end

group("cache handles awkward values")
do
    local back = Cache.deserialize(Cache.serialize({
        empty_table = {},
        ["a key with spaces"] = 1,
        ["end"] = 2,
        fraction = 0.5,
        negative = -3,
        quoted = 'he said "hi"',
        callback = function() end,
    }))
    ok(back ~= nil, "it parses")
    eq(next(back.empty_table), nil, "an empty table round trips")
    eq(back["a key with spaces"], 1, "keys needing brackets are quoted")
    eq(back["end"], 2, "a reserved word as a key is quoted")
    eq(back.fraction, 0.5, "floats survive")
    eq(back.negative, -3, "negatives survive")
    eq(back.quoted, 'he said "hi"', "embedded quotes survive")
    eq(back.callback, nil, "a value with no representation is skipped, not fatal")
end

group("cache rejects what it cannot trust")
do
    eq(Cache.deserialize(nil), nil, "nil")
    eq(Cache.deserialize(""), nil, "empty")
    eq(Cache.deserialize("this is not lua"), nil, "garbage")
    eq(Cache.deserialize("return 5"), nil, "not a table")
    eq(Cache.deserialize("return { version = 1 }"), nil, "no config key")
    eq(Cache.deserialize("return { version = 99, config = {} }"), nil,
        "a version we do not know")
    -- Loaded in an empty environment: a cache file cannot reach the host.
    eq(Cache.deserialize("return { version = 1, config = { x = os.time() } }"), nil,
        "a file trying to call out fails rather than running")
end

group("cache save is atomic and skips no-op writes")
do
    local path = tmpfile()
    local cfg = Config.build({ ttl_days = 7 })

    ok(Cache.save(path, cfg), "writes")
    eq(Cache.load(path).ttl_days, 7, "and loads back")

    local f = assert(io.open(path, "r"))
    local first = f:read("a")
    f:close()
    ok(Cache.save(path, cfg), "writing the same config again succeeds")
    f = assert(io.open(path, "r"))
    eq(f:read("a"), first, "and leaves the file byte-identical")
    f:close()

    ok(io.open(path .. ".tmp", "r") == nil, "no temp file is left behind")
    eq(Cache.load("/nonexistent/hyprplace/config.lua"), nil, "a missing cache is nil")
end

group("the plugin publishes its config for the tools")
do
    -- The drift this exists to close: with defer_classes set, the plugin defers a
    -- Firefox window while a tool running on defaults would report `move`.
    local cache_path = tmpfile()
    local w = support.window({ class = "firefox", address = "0xa", workspace = 9 })
    local hp, h = fresh({ w }, {
        cache_path = cache_path,
        defer_classes = { "^firefox$" },
        require_cmdline = { "^kitty$" },
    })
    DB.observe(hp.state(), "firefox", { 3 }, os.time())

    local published = Cache.load(cache_path)
    ok(published ~= nil, "setup writes the resolved config")
    eq(published.defer_classes[1], "^firefox$", "including what the user set")
    eq(published.ttl_days, Config.defaults().ttl_days, "and the defaults it resolved to")

    -- A tool built from the published config agrees with the plugin; one built from
    -- defaults does not.
    local tool_cfg = Config.build(published)
    eq(Placement.decide(w, { w }, hp.state(), tool_cfg).outcome, "defer",
        "a tool reading the cache reports what the plugin does")
    eq(Placement.decide(w, { w }, hp.state(), Config.build({})).outcome, "move",
        "and a tool on defaults would have reported something else")
end

-- ------------------------------------------------------------------- containment

group("the suite writes nothing outside its temp files")
do
    -- setup() writes three files, so a test that forgets to override one of the paths
    -- would silently write into the user's real state directory. This is the backstop.
    for _, before in ipairs(REAL_PATHS) do
        local existed, content = snapshot(before.path)
        local name = before.path:match("[^/]+$")
        if existed == before.existed and content == before.content then
            ok(true, "the real " .. name .. " is untouched")
        else
            -- A running hyprplace writing its own state mid-run would also land here,
            -- so say so rather than asserting the suite is guilty.
            ok(false, "the real " .. name .. " changed during the run"
                .. " (a test wrote it, or an installed hyprplace did)")
        end
    end
end

for _, path in ipairs(tmpfiles) do
    os.remove(path)
    os.remove(path .. ".tmp")
end

-- --------------------------------------------------------------------------- report

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
