// hypr-tags: give each Firefox window a stable identity a compositor can read.
//
// Firefox exposes no per-window identity to Wayland. The only channel an extension can
// write and a compositor can read is the window title, so each normal window gets a tag
// stored in the session store -- which survives session restore -- and published as a
// title preface: `[work] Inbox - Mozilla Firefox`.
//
// This is deliberately observe-only from the compositor's side. There is no native
// messaging host and no way for the plugin to set or rename a tag; see
// ../docs/FIREFOX-TAGS.md for why that boundary is where it is. Keeping it means this
// file is small enough to read in full before trusting it, which is the point.

const KEY = "hyprTag";
const TAG_RE = /^[A-Za-z0-9_-]{1,32}$/;

// Tag assignment reads every window's tag and then writes one. Two windows opening at
// once would interleave those steps and could pick the same tag, so every operation
// runs to completion before the next begins.
let chain = Promise.resolve();

function serialize(fn) {
  const run = chain.then(() => fn());
  // The queue must stay resolved. Chaining `chain = chain.then(fn, fn)` would hand the
  // *next* operation the previous failure as its argument -- so one rejected rename
  // would make the following window silently skip tagging -- and would leave a rejected
  // promise with no handler. Callers still see the real result.
  chain = run.then(() => {}, () => {});
  return run;
}

const randomTag = () =>
  Array.from(crypto.getRandomValues(new Uint8Array(4)),
             (b) => b.toString(16).padStart(2, "0")).join("");

const applyPreface = (windowId, tag) =>
  browser.windows.update(windowId, { titlePreface: `[${tag}] ` });

// Tags held by other live windows. O(windows) session reads per call, and the startup
// loop calls it once per window, so startup is O(windows^2) -- fine at realistic window
// counts, and the cost is paid in session-store reads rather than anything visible.
async function liveTags(exceptId) {
  const taken = new Set();
  for (const w of await browser.windows.getAll()) {
    if (w.id === exceptId) continue;
    const t = await browser.sessions.getWindowValue(w.id, KEY);
    if (t) taken.add(t);
  }
  return taken;
}

// Idempotent: a restored window can arrive through both the startup sweep and
// onCreated, and running twice must be harmless.
async function ensureTag(win) {
  if (win.type !== "normal" || win.incognito) return;

  const taken = await liveTags(win.id);
  let tag = await browser.sessions.getWindowValue(win.id, KEY);

  // Re-tag when the stored value is missing, malformed -- a corrupted or hand-edited
  // session store -- or already held by a live window, which happens when a closed
  // window is reopened after its tag was given away.
  if (!tag || !TAG_RE.test(tag) || taken.has(tag)) {
    do { tag = randomTag(); } while (taken.has(tag));
    await browser.sessions.setWindowValue(win.id, KEY, tag);
  }

  // Deliberately after the collision check, not before. Applying the stored preface
  // first would get the tag onto the title sooner, but a window that then has to be
  // re-tagged would have published an identity the compositor may already have acted
  // on -- and a wrong placement is worse than a slightly later one.
  await applyPreface(win.id, tag);
}

async function renameTag(windowId, tag) {
  if (!TAG_RE.test(tag)) throw new Error("Tag must match [A-Za-z0-9_-]{1,32}");
  const taken = await liveTags(windowId);
  if (taken.has(tag)) throw new Error(`Tag "${tag}" is already in use`);
  await browser.sessions.setWindowValue(windowId, KEY, tag);
  await applyPreface(windowId, tag);
  return tag;
}

browser.windows.onCreated.addListener((w) => serialize(() => ensureTag(w)));

// titlePreface is per-window state that is not persisted, so it has to be reapplied to
// every window each time this script starts: at browser startup, and when the extension
// is installed, enabled or reloaded. The tags themselves come back from the session
// store, so windows keep the identities they had.
browser.windows.getAll().then((ws) => ws.forEach((w) => serialize(() => ensureTag(w))));

browser.runtime.onMessage.addListener((msg) => {
  // Returning a Promise is how Firefox delivers an async response to the popup.
  if (msg.type === "get") {
    return browser.sessions.getWindowValue(msg.windowId, KEY);
  }
  if (msg.type === "rename") {
    return serialize(() => renameTag(msg.windowId, msg.tag));
  }
});
