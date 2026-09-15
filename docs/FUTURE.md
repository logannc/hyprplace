# hyprplace — Near-term work and feature exploration

Optional doc. Not required reading — consult when planning work beyond the MVP.

**Sequencing:** see below. The original plan -- finish the MVP, test it in real use, then
explore -- was changed once the Firefox tag design landed. The near-term items may land
at any point, since they are known needs rather than open questions.

---

## Agreed sequence

Firefox is most of the windows in the session this is built for, and every Firefox
window currently collapses to the single key `firefox`. Testing the MVP before Firefox
windows have identities would not be a partial test, it would be a *misleading* one:
placement would scatter them across the remembered distribution by position, which is
hard to tell apart from either working or failing. So real-use testing moves after the
tag work.

| # | Phase | Notes |
|---|---|---|
| 0 | Restate AC-4; record the deferral decision | Done. The old wording forbade the feature |
| 1 | Deferred-decision machinery | The bottleneck: tags and title sampling both need it |
| 2 | The extension, in dev mode | `extension/` here; `web-ext run`, unsigned, throwaway id |
| 3 | Tag identity tier | Tier 0, above class + cmdline |
| 4 | Live MVP testing | The full thing, including the three unverified assumptions |
| 5 | Distribution | AMO, signing, `policies.json`, root. Separately invoked |

**Not measured, configured.** An earlier plan added a title-timing instrument to
`hyprplace watch` and measured real Firefox restarts to derive the deferral timeout.
Dropped: the timeout is a config value with a default, and tuning a number by hand
against your own session is cheaper than building an instrument to derive it.

**Compositor testing stays deferred, and the risk is accepted.** A harness smoke test
after phase 1 was considered and declined. The consequence is understood: phases 1 and 3
change the placement path of a plugin that has never run in a compositor, so a failure
at phase 4 could come from the MVP or from the new machinery, and separating them will
cost more then than the smoke test would have cost now.

---

## Near-term (between MVP and the exploration exercise)

These are wanted, not speculative. The MVP ships a minimal version of each; the design
work is in choosing policy, not in whether to have the feature.

### TTL expiration

State must not grow unbounded. A window seen once a year ago is not useful information.

- MVP: every entry carries a `seen` timestamp; entries older than `ttl_days` are dropped
  when the DB is loaded.
- **Decided:** placement refreshes `seen`. Acting on an entry is evidence it is still in
  use, so an app you keep reopening never expires even if you never explicitly move it.
  The refresh updates recency only; it does not reorder the workspace slots.
- Open: what the default TTL should be, and whether it should be per-class rather than
  global.

### Which windows are worth remembering at all

Some classes carry no useful state across a close. A terminal reopened is a *different*
terminal — the session is gone, so putting it back on its old workspace is noise. But
there are real exceptions: a terminal always launched as `kitty btop` is a persistent,
identifiable thing and belongs on its workspace.

This is exactly what the layered identity model already distinguishes: a bare `kitty` has
no distinguishing cmdline, while `kitty btop` does.

- MVP: `require_cmdline` — a list of class patterns for which hyprplace only remembers and
  places windows that have a distinguishing cmdline. Defaults to empty, so nothing is
  excluded until we choose.
- Open: what the defaults should be, whether the rule wants to be per-class policy rather
  than one global list, and whether "volatile" should be inferred (e.g. a window whose
  cmdline is just the bare binary) rather than configured.

### Teaching hyprplace about a binary

Flags are dropped from the cmdline fingerprint by default, and `keep_flags` allowlists
the useful ones per binary. Choosing those patterns by hand is exactly the kind of thing
a user should not have to do in a config file.

- A `hyprplace teach <window>` flow that shows the argv, lets you pick which tokens are
  identity, and writes the allowlist entry.
- Related to the keybind escape hatch below: "this window is not being recognized" is the
  moment the user wants to teach, and the keybind is how they say so.
- Could the useful flags be inferred? A flag whose value differs between two runs of the
  same binary is volatile by definition, so observing across restarts would find them
  without being told.

### Configuration surface generally

Both of the above imply a real config story: where user config lives, how it merges with
defaults, and how it is reloaded. Worth designing once rather than growing ad hoc.

---

## Feature exploration exercise (after MVP + testing)

Open questions to brainstorm, not decisions. Recorded so they are not lost.

### Is there more to learn between the existing lifecycle points?

hyprplace currently observes `window.open_early`, `window.move_to_workspace`, and
`window.close`. A window's useful identity may not be fully formed at open:

- `window.title` fires on every title change. A window whose title only becomes
  meaningful after it settles (an editor opening a project, a browser loading a page)
  might be recognizable a second after open but not at open.
- Would a short "settling" observation window after open produce better identity than the
  single snapshot at `open_early`? What would it cost in complexity and in surprise —
  re-placing a window a second after it appeared would be jarring.
- Are `window.urgent`, `window.fullscreen`, or `window.active` informative for placement,
  or just noise?

### Delayed title resolution, and where titles belong

> For Firefox specifically there is a better answer than heuristics: a WebExtension that
> publishes a stable per-window tag through the title. See
> [FIREFOX-TAGS.md](FIREFOX-TAGS.md). It does not remove the need for this section --
> title heuristics remain the fallback for every other multi-window app -- but it does
> mean Firefox should not be the app this design is tuned around. The two share the
> "observe after open" machinery described below, which should be built once for both.

Seven Firefox windows share one pid and one class, so nothing distinguishes them at
`window.open_early`. Their *titles* do. But the title is not set when the window maps --
it arrives some time later.

The obvious shape is a per-class "wait for the title to settle" option, parallel to
`require_cmdline`: for these classes, do not fingerprint at open; observe for N ms and
use what the title becomes.

What we believe about Firefox specifically, to be confirmed by measurement:

- `browser.sessionstore.restore_on_demand` defaults to true, so restored tabs are lazy
  and the page does not load until focused.
- Titles are held in sessionstore separately from page content, and unloaded tabs display
  their stored titles -- so the window title should resolve without a page load and
  without focus.
- Unmeasured: the delay after map, whether background windows resolve as promptly as the
  focused one, and whether the title changes *again* once the tab really loads.

`hyprplace watch` can measure all three against a real Firefox restart.

**The harder problem is not timing.** Titles are stable across a *restore* but not across
*usage*: session restore brings the same tabs back, but navigating a window changes its
title and staleness sets in immediately. `kitty btop` is stable because argv does not
change while the window lives; "Search Results -- Mozilla Firefox" stops being true on the next
click.

So titles may belong as a **slot-assignment tiebreaker** rather than as part of the
identity key: the key stays `firefox`, and the title only decides which of the remembered
slots a given window claims. A wrong guess then costs a misplaced window instead of a
poisoned key that never matches again -- the Steam failure mode, which we should not
reintroduce by another route.

#### Sampling rather than subscribing

For the navigation case -- a window whose title changes as it is used -- the title has to
be watched over time, not read once. Polling is the right mechanism, not a compromise:

- `hl.on("window.title")` fires on every title change of every window: every page load,
  every tab switch, every terminal that rewrites its title per command. That is an
  unbounded-frequency handler in the compositor's hot path.
- A repeating `hl.timer` over `hl.get_windows()` is O(windows) every N seconds --
  bounded and predictable. `hl.timer` already supports `type = "repeat"`.
- A slow interval is sufficient. This is identity, not telemetry. Around **10s** is the
  starting point.

**The plugin's sampler and `hyprplace watch` are not the same kind of poller**, and
should not share an interval or a config key:

| | `watch` | plugin sampler |
|---|---|---|
| Audience | a person staring at a shell | nobody |
| Requirement | low latency, immediate feedback | eventual accuracy |
| Missing an intermediate state | a visible failure | irrelevant |
| Interval | 0.25s | ~10s |

The plugin only needs whatever a window *settled* on, so intermediate titles it never
observes cost nothing. `watch` is the opposite: the user just did something and wants to
see it reflected, and anything undone inside one interval looks like nothing happened --
which is precisely how the 1s default was caught being too slow.

Two consequences of a ~10s sampler:

- A window that lives less than one interval is never sampled at all, so the learn-time
  title read stays as the fallback. This is the same requirement noted above, arrived at
  from the other direction.
- Dwell weighting still works, just coarsely. It is a statistical sample of what a window
  displayed over its life, and at 10s a window open for an hour still yields ~360
  observations -- far more than enough to separate a stable title from a churning one.

Sampling also yields two things the event does not:

- **Dwell time.** The instantaneous title at learn time is a coin flip; you may catch a
  window mid-navigation. Sampling shows which title a window spent its life displaying,
  which is the stable signal underneath the noise.
- **Volatility detection.** A title unchanged for an hour is worth keying on. One that
  differs every sample (a terminal running `top`, a player counting timestamps) is noise,
  and sampling identifies it as noise without being told.

Keep the learn-time title as a fallback: a window opened and closed inside one sampling
interval would otherwise never be sampled at all.

Constraints, since this runs inside the compositor: no `/proc` reads in the sampler, and
the work must stay proportional to the window count.

#### Privacy: titles must not be stored in the clear

This one is a prerequisite, not a nicety. Real titles from a live session include
`Inbox (37) - <address> - Gmail` and the subreddit being read. Persisting them writes an
email address and browsing history to a plaintext file, which is a categorical change
from what hyprplace stores today (classes and argv).

We only ever need to *match* titles across sessions, never to read them back -- so store
a hash, not the text. Matching power is unchanged and no browsing history lands on disk.
The cost is that the tools cannot display a stored title directly, though `fingerprint`
could hash live titles and correlate, which is probably enough for debugging.

Be honest about what hashing buys: it is disclosure resistance, not anonymization. It
stops casual reading of the state file, which is the realistic risk. It does not stop
confirmation -- anyone holding the file can hash a guessed title and test for a match.
Do not describe it as anonymous.

#### Sampling must be optional, and off by default

Title sampling has to be a config switch so it can be turned off entirely.

If hyprplace is ever published, that switch should default to **disabled**, not
enabled-with-an-opt-out. Someone installing a workspace-placement plugin has not
consented to having window titles read and persisted, and opt-out puts the burden on the
people least likely to read the config. The plugin should be fully functional with
sampling off -- it is a disambiguation improvement for multi-window apps, not a
dependency.

Publishing tightens other defaults too, though the important ones are already right:
workspace ids are stored raw with no hyprsplit coupling, `require_cmdline` and
`keep_flags` are empty rather than tuned to one machine, and `ignore_classes` carries only
a launcher. The remaining question is the TTL default.

Related: this is the same machinery as "is there more to learn between lifecycle points"
below, and probably wants to be designed once for both.

### Keybinds as an escape hatch

The matcher will sometimes be wrong or unable to distinguish two windows. A manual
override may be more valuable than a cleverer matcher:

- A bind meaning "remember *this* window here, and be confident about it" — an explicit
  pin that outranks learned state.
- A bind meaning "stop tracking this window / forget this app."
- A bind to handle the genuinely-ambiguous case: teach hyprplace an identity for a window
  it cannot fingerprint on its own.

### DB inspection UI

- A bind that pops up a window showing current DB state: what keys exist, what workspace
  each maps to, when each was last seen, and which entries are about to expire.
- Would this be a terminal window (`kitty -e hyprplace-inspect`), an `hl.notification`, or
  something richer? A notification is cheap; a terminal is far more useful for debugging
  the matcher.
- Related: a "why did this window go here?" explain mode, showing which identity tier
  matched and what the alternatives were.

### Light process monitoring

Titles change and are sometimes unset early; `/proc` has more than cmdline (cwd, exe,
environ, parent pid). A process's cwd could distinguish two editor windows far better than
a title.

**Be careful here.** This runs inside the compositor process. Any `/proc` walking is
blocking I/O in a hot path, and anything periodic is a timer in the compositor's event
loop. Constraints to respect if we go down this road:

- No blocking reads in `window.open_early` beyond the single cmdline read already done.
- Anything periodic must be cheap, bounded, and cancellable.
- Reading another process's `environ` or `cwd` is a privacy consideration even for the
  user's own processes — worth an explicit opt-in rather than default-on.

### Session recovery: reopen what was open

Today hyprplace places windows you launch. It could also notice what is *missing*.

Give each entry an `active` flag recorded while the app is running. After a reboot you
arrive at a session where several entries are marked active but have no corresponding
process. That diff is a to-do list: these were open last time and are not now.

What to do with the diff is the design question:

- Relaunch silently — fastest, and the most likely to do something you did not want.
- A dialog with checkboxes: here is what was open, tick what to restore. Safer, and it
  doubles as a way to notice state you had forgotten about.
- Nothing automatic; just expose the diff to `hyprplace` as a command, and let a keybind
  or a script decide.

We already capture most of what a relaunch needs: the cmdline fingerprint *is* the
command, and `/proc` also has cwd. But note the gap this opens — placement only ever
*moves* windows the user chose to open, whereas this *starts processes*. Relaunching a
recorded argv is a meaningfully larger action, and it deserves an explicit opt-in and a
confirmation step rather than being folded into placement. Some apps also should never be
auto-restarted (installers, one-shot dialogs, anything mid-operation).

Interacts with the TTL question: an entry marked active at shutdown probably should not
expire while it is still "supposed" to be open.

### Other directions not yet considered

Deliberately open. Candidates to think about when we get there: per-monitor rather than
per-workspace memory for people who do not use hyprsplit's block scheme; handling grouped
and tabbed windows; interaction with special workspaces; and whether any of this should be
exposed to other tools over IPC.
