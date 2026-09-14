# hyprplace — Development Environment

**Principle: nothing we do may affect anything outside the dev environment.**
No system modification, no installs, no writes to the live config, and no possibility of
the harness addressing the live compositor. Every rail below exists to enforce that.

## Why a dedicated compositor at all

hyprplace runs *inside* the compositor process. Its behavior depends on real event
ordering (`window.open_early` vs `window.class`), real dispatch semantics, and real
multi-monitor workspace assignment. None of that can be observed from outside, and none of
it can be safely exercised on a live desktop — a bad dispatch scatters real windows.

## Components

| Piece | Location | Notes |
|-------|----------|-------|
| Source tree | `~/workspace/Hyprland-v0.56.2` | `git worktree` off `~/workspace/Hyprland-upstream`, detached at tag `v0.56.2` |
| Built compositor | `<tree>/build/Hyprland` | debug build, commit `efb50993` |
| Upstream harness | `<tree>/build/hyprtester/hyprtester` | built by `-DTESTS=true` |
| Unit tests (upstream) | `<tree>/build/hyprland_gtests` | pure unit tests, no compositor |
| Test runtime dir | `/run/user/1000/hpt` | ephemeral, must stay ≤25 chars |

### Why v0.56.2 rather than main

`efb50993` is the exact commit the installed `/usr/bin/Hyprland` reports, so test results
need no translation. It also builds against the system's existing dependencies untouched
(`aquamarine 0.14.0` satisfies its `>= 0.9.3`), whereas upstream `main` requires
`aquamarine >= 0.15.0`, which is not packaged here and would have to be built into a
private prefix.

## Building

```sh
# one-time: worktree + submodules (git, not jj — jj has no submodule support)
cd ~/workspace/Hyprland-upstream
git worktree add ~/workspace/Hyprland-v0.56.2 v0.56.2
cd ~/workspace/Hyprland-v0.56.2
git submodule update --init subprojects/hyprland-protocols subprojects/udis86

# build (~3 min on 32 cores); -DTESTS=true comes from the debug target
make debug
```

**Do not init `subprojects/tracy`** and do not set `USE_TRACY` — it is enormous and slow to
compile, and nothing here needs it. It is off by default; keep it that way.

To remove everything: `git worktree remove ~/workspace/Hyprland-v0.56.2`.

## Running the contained compositor

Use the harness script; it applies every rail below and refuses to address the live
instance:

```sh
./harness/compositor.sh start                 # launches, invisible, isolated
./harness/compositor.sh cmd output create headless HEADLESS-1
./harness/compositor.sh repl 'return #hl.get_monitors()'
./harness/compositor.sh stop                  # graceful, then verified, then cleaned up
```

`CONFIG=<file>` selects the config (default `harness/probe.lua`). The rest of this
section documents what the script does, and is the reference if it ever needs changing.

```sh
TESTDIR=/run/user/$(id -u)/hpt
mkdir -p $TESTDIR && chmod 700 $TESTDIR

env -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    XDG_RUNTIME_DIR="$TESTDIR" \
    WAYLAND_DISPLAY="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" \
    AQ_DRM_DEVICES=/nonexistent \
    HYPRLAND_NO_SD_NOTIFY=1 HYPRLAND_NO_SD_VARS=1 HYPRLAND_NO_CRASHREPORTER=1 \
    ~/workspace/Hyprland-v0.56.2/build/Hyprland --config <test.lua> &
```

Minimal `test.lua`:

```lua
hl.config({ debug = { enable_stdout_logs = true } })
hl.monitor({ output = "HEADLESS-1", mode = "1920x1080@60", position = "auto",       scale = 1 })
hl.monitor({ output = "HEADLESS-2", mode = "1920x1080@60", position = "auto-right", scale = 1 })
hl.monitor({ output = "", disabled = true })   -- disables the nested window
hl.config({ xwayland = { enabled = false } })  -- see Artifacts, below
```

Launch with `ulimit -c 0` set, so a crashing test process cannot deposit a core dump in
the system's coredump store.

Then create the outputs and probe:

```sh
SIG=$(basename $(ls -d $TESTDIR/hypr/*/ | head -1))
q() { XDG_RUNTIME_DIR=$TESTDIR hyprctl -i "$SIG" "$@"; }

q output create headless HEADLESS-1
q output create headless HEADLESS-2
q -j monitors
q repl 'return #hl.get_monitors()'
q dispatch exit          # shutdown
```

Always address the instance explicitly with `-i "$SIG"` and the scratch
`XDG_RUNTIME_DIR`. Never use a bare `hyprctl` inside the harness.

## The four non-obvious constraints

Each of these was discovered by hitting it. They are not optional.

**1. Headless-only does not work.**
`CHeadlessBackend::drmFD()` and `drmRenderNodeFD()` both return `-1`. Aquamarine's
`CBackend::start()` walks the implementations looking for a DRM fd to build a GBM
allocator; finding none it logs *"Cannot open backend: no allocator available"* and
returns false. So the compositor **must** nest to borrow the host's DRM node — the Wayland
backend obtains one from the host (`Wayland.cpp:396-403`, render node preferred).
Upstream avoids this entirely by running its tests in a QEMU VM with `-device
virtio-gpu-pci`. There is no qemu here, so nesting is the only option.

**2. `WAYLAND_DISPLAY` must be an absolute path.**
A bare `wayland-1` is resolved relative to `XDG_RUNTIME_DIR`, which we have deliberately
pointed elsewhere. Pass the full `/run/user/1000/wayland-1`.

**3. `XDG_RUNTIME_DIR` must be ≤ ~25 characters.**
The instance signature is 62 chars, and `$XDG_RUNTIME_DIR/hypr/<sig>/.socket2.sock` must
fit in `sockaddr_un`'s 108 bytes. The scratchpad path (~95 chars) is far too long. The
failure mode is `Socket2 path is too long` followed by an opaque abort during startup.

**4. The nested window is hidden by the catch-all monitor rule.**
`hl.monitor({ output = "", disabled = true })` matches the Wayland backend's `WAYLAND-N`
output and disables it, so nothing appears on screen. Headless outputs are created at
*runtime* via `hyprctl output create headless` — declaring them with `hl.monitor()` only
configures them, it does not create them.

## Containment contract

| Lever | Prevents |
|-------|----------|
| isolated `XDG_RUNTIME_DIR` | the harness discovering or addressing the live instance |
| `AQ_DRM_DEVICES=/nonexistent` | any DRM / GPU access |
| `-u DISPLAY` | X11 fallback backend |
| `--config <test.lua>` | reading `~/.config/hypr` |
| `HYPRPLACE_DB=<scratch>` | writing `~/.local/state` |
| test config spawns nothing | apps landing on the live desktop |
| assert target sig ≠ `$HYPRLAND_INSTANCE_SIGNATURE` | belt-and-braces on all of the above |

Verified: across five compositor launches, four of which crashed, the live session stayed
at exactly its baseline (windows, monitors, instance count) every time.

**The isolated runtime dir is required, not cosmetic.** `hyprtester` selects its target
with `INSTANCES.back()` after checking only `kill(pid, 0)` — process existence, not socket
readiness. If the test compositor dies during startup in an unisolated run, that resolves
to the *live* session, which then receives `/output create headless`, `/plugin load`, and
`killAllWindows()`.

## Test tiers

**Tier 1 — pure Lua unit tests.** Key derivation, cmdline normalization, ordinal
assignment, DB serialization round-trip. Run against a fake `hl` table with the system
`lua` (5.5) in milliseconds. No compositor. This should cover most of the logic.

**Tier 2 — contained compositor probes.** Spawn the instance above, drive it with
`hyprctl -i <sig> repl`, assert on real event behavior. This is where the open questions
in `DESIGN.md` get answered.

**Upstream's `hyprtester`** is available and has strong prior art —
`hyprtester/src/tests/main/` includes `workspaces.cpp`, `window.cpp`, `state.cpp`,
`persistent.cpp` — but tests are written in C++ against a `test.lua` config. Reusing its
*pattern* (launch with `--config`, resolve signature, drive over the socket, reset between
cases, SIGKILL at the end) is more useful than adopting its C++ runner for a Lua plugin.
Note `make test` inherits the environment, so run from within a session it will nest
against the live compositor — apply the containment env above.

## Artifacts: what a test run leaves behind

**Inside the live compositor: nothing.** The `HEADLESS-N` outputs exist only in the test
compositor's own process memory — virtual outputs owned by its aquamarine backend. The host
compositor only ever sees a Wayland client connect and disconnect. Verified: after several
runs, `hyprctl monitors all` on the live session lists only the four real outputs, and
because the catch-all rule disables `WAYLAND-N`, the client never maps a surface.

**In the dev environment:** the instance directory and wayland socket under the test
`XDG_RUNTIME_DIR`, removed by the cleanup below.

**Outside, and this one is real:** if a test process crashes or is SIGKILLed,
`systemd-coredump` records a core in `/var/lib/systemd/coredump`, which is root-owned and
cannot be cleaned up from here. One 1.7 MB `Xwayland` core was produced this way — the
nested compositor starts `Xwayland :N` by default, and killing the parent made it abort.

Three mitigations, all applied above:

1. `hl.config({ xwayland = { enabled = false } })` — do not start Xwayland at all. Revisit
   only if XWayland window placement itself needs testing, and expect cores if so.
2. `ulimit -c 0` in the launch wrapper — no cores from our processes, period.
3. Shut down with `dispatch exit` and verify it worked, rather than reaching for SIGKILL.

## Cleanup

```sh
q dispatch exit                       # graceful; verify it actually exited
pgrep -af 'Hyprland-v0.56.2/build/Hyprland --config'
kill -TERM <pid>                      # only after confirming the cmdline matches
rm -rf /run/user/$(id -u)/hpt
```

Always confirm a pid's `/proc/<pid>/cmdline` contains `Hyprland-v0.56.2/build/Hyprland`
before signalling it. Never pattern-match on `Hyprland` alone.

## Upstream bug found along the way

`src/Compositor.cpp:340` reports `"CBackend::create() failed!"` from inside the
`if (!m_aqBackend->start())` branch. The message belongs to the null check ~10 lines
above, so a `start()` failure is misreported as a `create()` failure. This cost real
debugging time; worth a PR from the fork.
