# hyprplace — Near-term work and feature exploration

Optional doc. Not required reading — consult when planning work beyond the MVP.

**Sequencing:** finish the MVP, then *test* the MVP in real use, and only then run the
exploration exercise below. The near-term items may land earlier, since they are known
needs rather than open questions.

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
