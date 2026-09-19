# hypr-tags

A Firefox WebExtension that gives each window a stable identity hyprplace can read.

Firefox tells Wayland nothing that distinguishes one of its windows from another: every
window shares an `app_id` and a pid, so at `window.open_early` hyprplace sees nine
identical `firefox` windows and can only guess which is which. This extension assigns
each window a tag, keeps it in the session store so it survives a restart, and publishes
it as a title preface:

```
[work] Inbox - Mozilla Firefox
```

The title is the only channel an extension can write and a compositor can read. The full
design, and why native messaging was rejected, is in
[../docs/FIREFOX-TAGS.md](../docs/FIREFOX-TAGS.md).

## Contract with the plugin

This is the whole interface. The extension never learns anything about workspaces, and
hyprplace never sets or renames a tag -- there is no channel in that direction.

- A tag matches `[A-Za-z0-9_-]{1,32}`, bracketed, anchored at the start of the title,
  followed by a space. `tag.lua` implements the reading side, and a test asserts the two
  definitions have not drifted apart.
- **A window appears untagged and is tagged a moment later.** This is the normal case at
  startup, not an error: Hyprland sees a restored window before this script has run. The
  plugin must wait rather than decide at open, which is what `defer_classes` and
  `defer_timeout_ms` are for.
- Untagged windows -- private, popups, picture-in-picture, and any window before its
  preface lands -- get no special handling. They fall through to ordinary class-based
  placement.
- A rename is just a title change to a new tag. The plugin treats it as a new identity;
  the old one expires under the TTL on its own.

## Status: not yet signed

`gecko.id` is **`hypr-tags@lcspace.net`**, bound to the AMO account that signs it. It
can technically be changed while the extension is unlisted and undistributed -- a new id
is simply a new extension, and nobody has the old one installed -- but after the first
signing run it is a decision with consequences, so treat it as settled.

Signing is **unlisted / self-distributed**: the extension never appears on AMO, and the
signed `.xpi` comes back for direct download. Release Firefox loads only signed
extensions, so this is what makes it installable in a normal profile.

```sh
npx web-ext lint -s extension                              # always, before signing
npx web-ext sign -s extension -a dist --channel unlisted   # burns the version number
```

`web-ext sign` reads two environment variables, which are the two halves of the AMO API
credential under different names:

| web-ext | AMO developer hub calls it | shape |
|---|---|---|
| `WEB_EXT_API_KEY` | **JWT issuer** | `user:12345678:123` |
| `WEB_EXT_API_SECRET` | **JWT secret** | 64 hex characters |

**A version string can be signed exactly once.** A failed submission burns it, so lint
first and bump `manifest.json` rather than retrying the same number.

Installing the result in a normal profile needs no root and no enterprise policy -- open
the `.xpi` (`firefox /path/to/hypr-tags.xpi`) and accept the prompt. The
`policies.json` path described in ../docs/FIREFOX-TAGS.md is for installing it on
*other people's* machines, and is not needed to run it on your own.

For development, no signing is required:

```sh
npx web-ext run -s extension          # scratch profile, auto-reload, no signing
```

That opens a real Firefox window in a throwaway profile, and `-s extension` must point
at this directory. Add `--profile-path <dir> --keep-profile-changes` to reuse a profile
across runs, which is what makes session restore -- and so tag persistence -- testable
without signing anything.

Verify from the compositor side:

```sh
hyprctl clients -j | jq -r '.[] | select(.class | test("firefox")) | .title'
```

## Files

| | |
|---|---|
| `manifest.json` | MV2. A persistent background script is simpler here than an MV3 event page, which would be unloaded between window events |
| `background.js` | Tag assignment, collision handling, and the title preface |
| `popup.html` / `popup.js` | Renaming a window's tag |

## Notes on the implementation

- **Operations are serialized.** Assigning a tag reads every window's tag and then
  writes one; two windows opening at once would interleave those steps and could pick
  the same tag.
- **`ensureTag` is idempotent.** A restored window arrives through both the startup
  sweep and `onCreated`.
- **The preface is applied after the collision check, not before.** Publishing the
  stored tag immediately would be faster, but a window that then has to be re-tagged
  would have published an identity the compositor may already have acted on. A late
  placement is recoverable; a wrong one is not.
- **`titlePreface` is not persisted**, so every window is swept each time the script
  starts -- at browser startup, and on install, enable or reload. The tags themselves
  come back from the session store.
- Startup is O(windows²) session reads. At realistic window counts this is nothing, and
  it buys the collision guarantee above.

## Prerequisite

Firefox must restore the previous session (`browser.startup.page = 3`). Without it no
windows are restored, and the feature is a harmless no-op.
