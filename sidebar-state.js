(() => {
  const storageKey = "doubledata.docs.sidebar.v1";
  if (window.__doubleDataSidebarState) return;
  window.__doubleDataSidebarState = true;

  let choices = new Map();
  try {
    const saved = JSON.parse(sessionStorage.getItem(storageKey) || "[]");
    if (Array.isArray(saved)) {
      choices = new Map(saved.filter((entry) =>
        Array.isArray(entry) && entry.length === 2 &&
        typeof entry[0] === "string" && entry[0].length <= 512 &&
        typeof entry[1] === "boolean"
      ).slice(-100));
    }
  } catch {
    // Keep the same behaviour in memory when browser storage is unavailable.
  }

  function groupPath(button) {
    const sidebar = button.closest("#sidebar");
    if (!sidebar) return null;
    const path = [];
    for (let node = button.parentElement; node && node !== sidebar; node = node.parentElement) {
      if (node.matches("li[data-title]")) path.unshift(node.dataset.title);
    }
    return path.length ? path : null;
  }

  function save() {
    if (choices.size > 100) choices = new Map([...choices].slice(-100));
    try {
      sessionStorage.setItem(storageKey, JSON.stringify([...choices]));
    } catch {
      // Storage restrictions must not interrupt navigation.
    }
  }

  let restoring = false;
  let scheduled = false;
  let passes = 0;

  function restore() {
    scheduled = false;
    let changed = false;
    for (const button of document.querySelectorAll("#sidebar button[aria-expanded]")) {
      const path = groupPath(button);
      if (!path) continue;
      const wanted = choices.get(JSON.stringify(path));
      if (wanted === undefined || button.getAttribute("aria-expanded") === String(wanted)) continue;
      restoring = true;
      try {
        button.click();
      } finally {
        restoring = false;
      }
      changed = true;
    }
    // Opening a parent mounts its child groups. Restore those on the next frame.
    if (changed && ++passes < 8) {
      scheduled = true;
      requestAnimationFrame(restore);
    }
  }

  function scheduleRestore() {
    if (scheduled) return;
    scheduled = true;
    passes = 0;
    requestAnimationFrame(restore);
  }

  document.addEventListener("click", (event) => {
    if (restoring || !(event.target instanceof Element)) return;
    const button = event.target.closest("#sidebar button[aria-expanded]");
    if (!button) return;
    const path = groupPath(button);
    if (!path) return;
    for (let depth = 1; depth < path.length; depth++) {
      choices.set(JSON.stringify(path.slice(0, depth)), true);
    }
    choices.set(JSON.stringify(path), button.getAttribute("aria-expanded") !== "true");
    save();
    scheduleRestore();
  }, true);

  window.addEventListener("mintlify:navigate", scheduleRestore);
  scheduleRestore();
})();
