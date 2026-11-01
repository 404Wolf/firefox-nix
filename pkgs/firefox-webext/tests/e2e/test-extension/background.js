// Reports what the extension sees in browser.storage to the test harness,
// then applies whatever runtime changes the harness asks for.
const HARNESS = "http://127.0.0.1:8737";

async function post(path, body) {
  const res = await fetch(HARNESS + path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return res.json();
}

(async () => {
  const id = browser.runtime.id;
  try {
    const report = {
      id,
      version: browser.runtime.getManifest().version,
      commands: Object.fromEntries(
        (await browser.commands.getAll()).map((c) => [c.name, c.shortcut || ""]),
      ),
      local: await browser.storage.local.get(null),
      sync: await browser.storage.sync.get(null),
      managed: await browser.storage.managed.get(null).catch((e) => ({ error: String(e) })),
    };
    const todo = await post("/report", report);
    if (todo.local) await browser.storage.local.set(todo.local);
    if (todo.sync) await browser.storage.sync.set(todo.sync);
    for (const [name, shortcut] of Object.entries(todo.commands || {})) {
      await browser.commands.update({ name, shortcut });
    }
    await post("/done", { id });
  } catch (e) {
    await post("/error", { id, error: String(e) });
  }
})();
