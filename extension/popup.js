// The rename UI. All validation lives in background.js -- this only reports what it
// says -- so the popup cannot be the reason an invalid tag gets stored.

const $ = (id) => document.getElementById(id);

(async () => {
  const win = await browser.windows.getCurrent();
  const cur = await browser.runtime.sendMessage({ type: "get", windowId: win.id });

  $("cur").textContent = cur ?? "(none)";
  $("tag").value = cur ?? "";
  $("tag").focus();
  $("tag").select();

  const save = async () => {
    $("err").textContent = "";
    try {
      const tag = await browser.runtime.sendMessage(
        { type: "rename", windowId: win.id, tag: $("tag").value.trim() });
      $("cur").textContent = tag;
      window.close();
    } catch (e) {
      $("err").textContent = e.message;
    }
  };

  $("save").addEventListener("click", save);
  $("tag").addEventListener("keydown", (e) => { if (e.key === "Enter") save(); });
})();
