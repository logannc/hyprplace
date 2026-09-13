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
    eq(merged.max_slots, d.max_slots, "unspecified keys keep defaults")

    ok(Config.matches("Kitty", { "^kitty$" }), "matches case-insensitively")
    ok(not Config.matches("kitty", { "^alacritty$" }), "non-match returns false")
    ok(not Config.matches(nil, { "^kitty$" }), "nil class never matches")
    ok(not Config.matches("", { "" }), "empty class never matches")
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
    DB.record(s, "firefox", 3, 1000, 8)
    DB.record(s, "kitty\0kitty btop", 21, 1001, 8)
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

group("db.record")
do
    local s = DB.empty()
    DB.record(s, "k", 1, 100, 3)
    DB.record(s, "k", 2, 101, 3)
    eq(s.entries["k"].workspaces[1], 2, "most recent first")
    eq(s.entries["k"].workspaces[2], 1, "previous retained behind it")

    DB.record(s, "k", 1, 102, 3)
    eq(s.entries["k"].workspaces[1], 1, "re-recording moves to front")
    eq(#s.entries["k"].workspaces, 2, "and does not duplicate")

    DB.record(s, "k", 5, 103, 3)
    DB.record(s, "k", 6, 104, 3)
    eq(#s.entries["k"].workspaces, 3, "capped at max_slots")
end

group("db.touch")
do
    local s = DB.empty()
    DB.record(s, "k", 5, 100, 8)
    DB.record(s, "k", 3, 101, 8)   -- order is now {3, 5}
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
    DB.record(s, "fresh", 1, now, 8)
    DB.record(s, "stale", 1, now - (91 * 86400), 8)
    local _, dropped = DB.prune(s, 90, now)
    eq(dropped, 1, "one entry expired")
    ok(s.entries["fresh"] ~= nil, "fresh entry kept")
    eq(s.entries["stale"], nil, "stale entry dropped")

    local s2 = DB.empty()
    DB.record(s2, "old", 1, 0, 8)
    local _, d2 = DB.prune(s2, 0, now)
    eq(d2, 0, "ttl of 0 disables expiry")
end

group("db.save/load round trip")
do
    local path = os.tmpname()
    local s = DB.empty()
    DB.record(s, "firefox", 7, 12345, 8)
    local saved, err = DB.save(path, s)
    ok(saved, "save succeeded (" .. tostring(err) .. ")")
    eq(DB.load(path).entries["firefox"].workspaces[1], 7, "loaded what we saved")
    eq(next(DB.load("/nonexistent/hyprplace/db.lua").entries), nil, "missing file -> empty")
    os.remove(path)
end

-- ------------------------------------------------------------------------ placement

local Placement = require("hyprplace.placement")

group("placement")
do
    local key_of = function(w) return w.class end
    local a = support.window({ class = "kitty", address = "0xa", workspace = 1 })
    local b = support.window({ class = "kitty", address = "0xb", workspace = 2 })
    local c = support.window({ class = "firefox", address = "0xc", workspace = 3 })

    local occ = Placement.occupied_workspaces({ a, b, c }, "kitty", "0xa", key_of)
    ok(occ[2], "counts another window of the same app")
    ok(not occ[1], "excludes the window being placed")
    ok(not occ[3], "ignores other apps")

    eq(Placement.choose({ workspaces = { 2, 1, 5 } }, { [2] = true }), 1,
        "skips occupied and takes the next remembered")
    eq(Placement.choose({ workspaces = { 2 } }, { [2] = true }), nil,
        "all remembered taken -> no placement")
    eq(Placement.choose(nil, {}), nil, "no entry -> no placement")
    eq(Placement.choose({ workspaces = {} }, {}), nil, "empty entry -> no placement")
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

local function fresh(windows, user_cfg)
    package.loaded["hyprplace"] = nil
    local h = support.fake_hl(windows)
    _G.hl = h
    local cfg = user_cfg or {}
    cfg.db_path = cfg.db_path or os.tmpname()
    local hp = require("hyprplace").setup(cfg)
    return hp, h, cfg.db_path
end

group("setup")
do
    local _, h = fresh({})
    ok(h.handlers["window.open_early"], "subscribes to window.open_early")
    ok(h.handlers["window.move_to_workspace"], "subscribes to window.move_to_workspace")
    ok(h.handlers["window.close"], "subscribes to window.close")
    ok(h.handlers["monitor.added"], "subscribes to monitor.added")
end

group("placement dispatch")
do
    local w = support.window({ class = "firefox", address = "0xa", workspace = 9 })
    local hp, h = fresh({ w })
    DB.record(hp.state(), "firefox", 3, os.time(), 8)

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
    DB.record(hp2.state(), "firefox", 3, os.time(), 8)
    h2.handlers["window.open_early"](w2)
    eq(#h2.dispatched, 0, "already on the remembered workspace -> no dispatch")

    local w3 = support.window({ class = "hyprland-run", address = "0xc", workspace = 9 })
    local hp3, h3 = fresh({ w3 })
    DB.record(hp3.state(), "hyprland-run", 1, os.time(), 8)
    h3.handlers["window.open_early"](w3)
    eq(#h3.dispatched, 0, "ignore_classes are never placed")
end

group("the self-move guard")
do
    -- The compositor echoes our own move back synchronously; without the guard we would
    -- learn from our own placement. This is the measured behaviour, replayed.
    --
    -- The entry is {5, 3} with another window already on 5, so placement picks 3. If the
    -- echo were learned, DB.record would promote 3 to the front and the order would flip
    -- to {3, 5}. Order is therefore the discriminator -- `seen` is not, because placement
    -- legitimately refreshes it.
    local w     = support.window({ class = "firefox", address = "0xa", workspace = 9 })
    local other = support.window({ class = "firefox", address = "0xb", workspace = 5 })
    local hp, h = fresh({ w, other })
    h.echo_move = true
    DB.record(hp.state(), "firefox", 3, 1000, 8)
    DB.record(hp.state(), "firefox", 5, 1001, 8)   -- order {5, 3}

    h.handlers["window.open_early"](w)
    eq(h.dispatched[1].args.workspace, 3, "placed on the first free remembered slot")
    eq(hp.state().entries["firefox"].workspaces[1], 5,
        "the echo of our own move did not reorder the slots")
    eq(hp.state().entries["firefox"].workspaces[2], 3, "second slot still second")
end

group("placement refreshes recency")
do
    local w = support.window({ class = "firefox", address = "0xa", workspace = 9 })
    local hp, h = fresh({ w })
    DB.record(hp.state(), "firefox", 3, 1000, 8)
    h.handlers["window.open_early"](w)
    ok(hp.state().entries["firefox"].seen > 1000,
        "an app you keep reopening does not expire, even if never moved")

    -- Also refreshed when the window is already where it belongs and no move is needed.
    local w2 = support.window({ class = "discord", address = "0xb", workspace = 3 })
    local hp2, h2 = fresh({ w2 })
    DB.record(hp2.state(), "discord", 3, 1000, 8)
    h2.handlers["window.open_early"](w2)
    eq(#h2.dispatched, 0, "no move needed")
    ok(hp2.state().entries["discord"].seen > 1000, "but recency still refreshed")
end

group("learning from real moves")
do
    local w = support.window({ class = "firefox", address = "0xa", workspace = 3 })
    local hp, h = fresh({ w })
    h.handlers["window.move_to_workspace"](w, { id = 7 })
    eq(hp.state().entries["firefox"].workspaces[1], 7, "a user move is learned")

    -- Mass moves (hyprsplit swap_monitors) do not carry focus on every window.
    local u = support.window({ class = "discord", address = "0xb", workspace = 3, active = false })
    local hp2, h2 = fresh({ u })
    h2.handlers["window.move_to_workspace"](u, { id = 7 })
    eq(hp2.state().entries["discord"], nil, "an unfocused window's move is not learned")

    -- Monitor hotplug reflows whole workspaces; a KVM swap must not rewrite the db.
    local m = support.window({ class = "signal", address = "0xc", workspace = 3 })
    local hp3, h3 = fresh({ m })
    h3.handlers["monitor.added"]()
    h3.handlers["window.move_to_workspace"](m, { id = 7 })
    eq(hp3.state().entries["signal"], nil, "moves during monitor settling are ignored")
    h3.flush_timers()
    h3.handlers["window.move_to_workspace"](m, { id = 7 })
    eq(hp3.state().entries["signal"].workspaces[1], 7, "learning resumes after settling")
end

group("learning on close (AC-1)")
do
    -- A window the user never explicitly moved is only ever recorded here.
    local w = support.window({ class = "firefox", address = "0xa", workspace = 3 })
    local hp, h = fresh({ w })
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
    h.handlers["window.close"](bare)
    eq(hp.state().entries["kitty"], nil, "a bare terminal is not remembered")

    local btop = support.window({ class = "kitty", pid = 100, address = "0xb", workspace = 21 })
    local hp2, h2 = fresh({ btop }, { require_cmdline = { "^kitty$" } })
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
    h.handlers["window.close"](w)
    eq(next(DB.load(path).entries), nil, "not written synchronously")
    h.flush_timers()
    eq(DB.load(path).entries["firefox"].workspaces[1], 3, "written when the timer fires")
    os.remove(path)
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

-- --------------------------------------------------------------------------- report

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
