"""End-to-end test of programs.firefox webext/immutable in headless Firefox.

Each phase launches the home-manager launcher (which applies the state bundle
before exec'ing Firefox), waits for the test extension to report what
browser.storage returns, asks it to make runtime changes, then quits Firefox
through Marionette. Privileged assertions (locked prefs, policies, add-on
state) also go through Marionette in chrome context.
"""

import json
import os
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

SPEC = json.load(open(os.environ["SPEC"]))
PROFILE = os.environ["PROFILE"]
NIX_BUILD_TOP = os.environ["NIX_BUILD_TOP"]
TEST, INTRUDER = SPEC["testId"], SPEC["intruderId"]

state = {"reports": {}, "done": set(), "errors": [], "todo": {}}
cond = threading.Condition()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        reply = {}
        with cond:
            if self.path == "/report":
                state["reports"][body["id"]] = body
                reply = state["todo"] if body["id"] == TEST else {}
            elif self.path == "/done":
                state["done"].add(body["id"])
            else:
                state["errors"].append(body)
            cond.notify_all()
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 8737), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()


class Marionette:
    def __init__(self, port=2828, timeout=120):
        deadline = time.time() + timeout
        while True:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=60)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.5)
        self.buf = b""
        self.msgid = 0
        self._recv()  # greeting
        self.cmd("WebDriver:NewSession", {"capabilities": {}})
        self.cmd("Marionette:SetContext", {"value": "chrome"})

    def _recv(self):
        while b":" not in self.buf:
            self.buf += self.sock.recv(65536)
        n, rest = self.buf.split(b":", 1)
        n = int(n)
        while len(rest) < n:
            rest += self.sock.recv(65536)
        self.buf = rest[n:]
        return json.loads(rest[:n])

    def cmd(self, name, params=None):
        self.msgid += 1
        data = json.dumps([0, self.msgid, name, params or {}]).encode()
        self.sock.sendall(str(len(data)).encode() + b":" + data)
        while True:
            msg = self._recv()
            if msg[1] == self.msgid:
                if msg[2]:
                    raise RuntimeError(f"{name}: {msg[2]}")
                return msg[3]

    def script(self, body):
        return self.cmd("WebDriver:ExecuteScript", {"script": body, "args": []})["value"]

    def quit(self):
        try:
            self.cmd("Marionette:Quit", {"flags": ["eForceQuit"]})
        except (OSError, RuntimeError, ValueError):
            pass


def run_phase(name, launcher, todo, privileged=None):
    print(f"--- phase {name}", flush=True)
    with cond:
        state["reports"].clear()
        state["done"].clear()
        state["todo"] = todo
    env = dict(os.environ, MOZ_HEADLESS="1", MOZ_REMOTE_ALLOW_SYSTEM_ACCESS="1")
    log = open(f"firefox-{name}.log", "w")
    proc = subprocess.Popen(
        [launcher, "--headless", "--no-remote", "--profile", PROFILE, "--marionette", "about:blank"],
        env=env,
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    try:
        with cond:
            ok = cond.wait_for(lambda: TEST in state["done"] or state["errors"], timeout=180)
        if state["errors"]:
            fail(f"extension error: {state['errors']}")
        if not ok:
            fail(f"phase {name}: test extension never reported")
        time.sleep(3)  # let a blocked extension report, if it (wrongly) runs
        result = None
        m = Marionette()
        if privileged:
            result = m.script(privileged)
            m.cmd("Marionette:SetContext", {"value": "content"})
            err = ""
            try:
                m.cmd("WebDriver:Navigate", {"url": "about:config"})
            except RuntimeError as e:
                err = str(e)
            url = m.cmd("WebDriver:GetCurrentURL")["value"]
            result["about_config_url"] = url
            result["about_config_blocked"] = "blockedByPolicy" in url + err
        m.quit()
        proc.wait(timeout=60)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        log.close()
    with cond:
        return dict(state["reports"]), result


failures = []


def fail(msg):
    print(f"FAIL: {msg}", flush=True)
    for f in sorted(os.listdir(".")):
        if f.startswith("firefox-") and f.endswith(".log"):
            print(f"== {f}\n" + open(f).read()[-4000:])
    sys.exit(1)


def check(cond_, msg):
    print(("ok   " if cond_ else "FAIL ") + msg, flush=True)
    if not cond_:
        failures.append(msg)


PRIVILEGED = """
return (async () => {
  const { AddonManager } = ChromeUtils.importESModule("resource://gre/modules/AddonManager.sys.mjs");
  const name = %(pref)s;
  const before = Services.prefs.getStringPref(name);
  let setError = null;
  try { Services.prefs.setStringPref(name, "https://example.com/changed"); } catch (e) { setError = String(e); }
  const after = Services.prefs.getStringPref(name);
  const policy = WebExtensionPolicy.getByID(%(test)s);
  const test = await AddonManager.getAddonByID(%(test)s);
  const intruder = await AddonManager.getAddonByID(%(intruder)s);
  return {
    locked: Services.prefs.prefIsLocked(name), before, after, setError,
    aboutConfigPolicy: Services.policies.getActivePolicies().BlockAboutConfig === true,
    chromeDevtoolsLocked: Services.prefs.prefIsLocked("devtools.chrome.enabled"),
    keepStorage: Services.prefs.getBoolPref("extensions.webextensions.keepStorageOnUninstall", false),
    testActive: test ? test.isActive : null,
    privateBrowsingAllowed: policy ? policy.privateBrowsingAllowed : null,
    uuid: policy ? policy.mozExtensionHostname : null,
    intruderActive: intruder ? intruder.isActive : null,
  };
})();
""" % {
    "pref": json.dumps(SPEC["lockedPref"]),
    "test": json.dumps(TEST),
    "intruder": json.dumps(INTRUDER),
}

local_declared = {**SPEC["localForce"], **SPEC["localDefaults"]}
sync_declared = {**SPEC["syncForce"], **SPEC["syncDefaults"]}
runtime = {
    "local": {
        "defKey": "user",
        "forceKey": "user",
        "runtime": "kept",
        # Accounts the extension creates at runtime (the template's ids).
        "acct_bob_login": "token",
        "acct_carol_login": "token",
        "acct_carol_def": "user",
    },
    "sync": {"syncDef": "user", "syncForce": "user", "runtimeSync": "kept"},
    "commands": {"cmd-set": "Alt+Shift+9", "cmd-untouched": "Alt+Shift+8"},
}
idb_dir = os.path.join(
    PROFILE, "storage", "default", f"moz-extension+++{SPEC['uuid']}^userContextId=4294967295"
)

# A: fresh profile. storage.local goes through storage.js -> IndexedDB import.
check(not os.path.exists(idb_dir), "A: no IndexedDB before first start")
reports, priv = run_phase("A-fresh", os.environ["LAUNCHER_OVERLAY"], runtime, PRIVILEGED)
r = reports[TEST]
check(r["local"] == local_declared, f"A: storage.local imported via storage.js: {r['local']}")
check(r["sync"] == sync_declared, f"A: storage.sync written to fresh database: {r['sync']}")
expected_commands = {"cmd-set": "Ctrl+Shift+Y", "cmd-unset": "", "cmd-untouched": "Alt+Shift+3"}
check(r["commands"] == expected_commands, f"A: shortcuts set, unset and left alone: {r['commands']}")
check(r["managed"] == SPEC["managed"], f"A: storage.managed from policy: {r['managed']}")
check(os.path.exists(idb_dir), "A: Firefox created the IndexedDB origin")
check(priv["locked"], f"A: {SPEC['lockedPref']} is locked")
check(
    priv["after"] == SPEC["lockedValue"] == priv["before"],
    f"A: locked pref ignores changes ({priv['before']!r} -> {priv['after']!r})",
)
check(priv["aboutConfigPolicy"] and priv["chromeDevtoolsLocked"], "A: BlockAboutConfig policy active")
check(priv["about_config_blocked"], f"A: about:config does not load ({priv['about_config_url']})")
check(priv["keepStorage"], "A: keepStorageOnUninstall set (storage.js import on first install)")
check(priv["testActive"] is True, "A: declared extension active with lockExtensions")
check(priv["privateBrowsingAllowed"] is True, "A: privateBrowsing allowed by policy")
check(priv["uuid"] == SPEC["uuid"], f"A: UUID pinned ({priv['uuid']})")
check(priv["intruderActive"] is not True, f"A: undeclared extension not running ({priv['intruderActive']})")
check(INTRUDER not in reports, "A: undeclared extension never reported")

# B: IndexedDB exists now, rows are written directly. Overlay keeps runtime keys.
reports, _ = run_phase("B-overlay", os.environ["LAUNCHER_OVERLAY"], {})
r = reports[TEST]
check(r["local"].get("forceKey") == "nix", "B: force key restored in IndexedDB")
check(r["local"].get("defKey") == "user", "B: default key keeps the runtime value")
check(r["local"].get("runtime") == "kept", "B: undeclared runtime key survives (overlay)")
check(r["local"].get("types") == SPEC["localForce"]["types"], "B: all value types round-trip")
check(r["local"].get("ключ-🔑") == "unicode key", "B: unicode key round-trips")
check(r["sync"].get("syncForce") == {"a": [1, 2]}, "B: sync force key restored")
check(r["sync"].get("syncDef") == "user", "B: sync default keeps the runtime value")
check(r["sync"].get("runtimeSync") == "kept", "B: sync runtime key survives (overlay)")
template_force = SPEC["localTemplates"]["accounts"]["force"]["acct_{id}_setting"]
templated = {
    "acct_bob_setting": template_force,
    "acct_carol_setting": template_force,
    "acct_alice_def": "nix-default",
    "acct_bob_def": "nix-default",
    "acct_carol_def": "user",
}
acct = {k: v for k, v in r["local"].items() if k.startswith("acct_")}
check(
    acct
    == {
        **templated,
        "acct_alice_setting": "explicit beats template",
        "acct_bob_login": "token",
        "acct_carol_login": "token",
    },
    f"B: template applied to every runtime id, explicit key wins, logins kept: {acct}",
)

check(
    reports[TEST]["commands"] == {**expected_commands, "cmd-untouched": "Alt+Shift+8"},
    f"B: declared shortcut reset, browser-set one kept: {reports[TEST]['commands']}",
)

# C: declarative state deletes undeclared keys.
reports, _ = run_phase("C-declarative", os.environ["LAUNCHER_DECLARATIVE"], {})
r = reports[TEST]
declarative_local = {**SPEC["localForce"], "defKey": "user", **templated}
check(
    r["local"] == declarative_local,
    f"C: storage.local is exactly the declared and templated keys: {sorted(r['local'])}",
)
check(
    r["sync"] == {**SPEC["syncForce"], "syncDef": "user"},
    f"C: storage.sync is exactly the declared keys: {sorted(r['sync'])}",
)

# E: dump decodes what Firefox itself wrote (phase A rows were written by Firefox).
out = subprocess.run(
    [os.environ["FIREFOX_WEBEXT"], "dump", "--profile", PROFILE, "--id", TEST],
    capture_output=True,
    text=True,
    check=True,
)
dumped = json.loads(out.stdout)[TEST]
check(dumped["local"] == r["local"], "E: dump matches storage.local as the extension sees it")
check(dumped["sync"] == r["sync"], "E: dump matches storage.sync as the extension sees it")
check(dumped["uuid"] == SPEC["uuid"], "E: dump reports the pinned UUID")

# F: re-applying is a no-op. "types" and the unicode key were last written by
# Firefox (storage.js import), so this also shows our bytes equal Firefox's.
out = subprocess.run(
    [os.environ["FIREFOX_WEBEXT"], "apply", "--manifest", os.environ["MANIFEST_DECLARATIVE"]],
    capture_output=True,
    text=True,
    check=True,
)
check(out.stdout.strip() == "", f"F: re-apply changes nothing: {out.stdout.strip()!r}")

# G: a rebuilt extension (new store path, same profile path, store mtime 1).
xpi_link = os.path.join(PROFILE, "extensions", f"{TEST}.xpi")
check(reports[TEST]["version"] == "1.0", "G: v1 running before the swap")
os.unlink(xpi_link)
os.symlink(os.environ["XPI_V2"], xpi_link)
ADDON_VERSION = """
return (async () => {
  const { AddonManager } = ChromeUtils.importESModule("resource://gre/modules/AddonManager.sys.mjs");
  const a = await AddonManager.getAddonByID(%s);
  return { version: a.version, updateDate: a.updateDate && a.updateDate.getTime() };
})();
""" % json.dumps(TEST)
reports, am = run_phase("G-stale", os.environ["FIREFOX_PLAIN"], {}, ADDON_VERSION)
print(
    f"info G: without apply, runtime v{reports[TEST]['version']}, AddonManager {am}",
    flush=True,
)
check(am["version"] == "1.0", f"G: bug reproduced: add-on database stale without apply ({am['version']})")
startup = os.path.join(PROFILE, "addonStartup.json.lz4")
subprocess.run(
    [os.environ["FIREFOX_WEBEXT"], "apply", "--manifest", os.environ["MANIFEST_DECLARATIVE"]],
    check=True,
)
check(os.path.exists(startup), "G: addonStartup.json.lz4 edited in place, not deleted")
ours = os.path.join(NIX_BUILD_TOP, "addonStartup-ours.lz4")
with open(startup, "rb") as src, open(ours, "wb") as dst:
    dst.write(src.read())
READ_OURS = """
return (async () => {
  const { AddonManager } = ChromeUtils.importESModule("resource://gre/modules/AddonManager.sys.mjs");
  const a = await AddonManager.getAddonByID(%s);
  const states = await IOUtils.readJSON(%s, { decompress: true });
  return { version: a.version, mtime: states["app-profile"].addons[%s].lastModifiedTime };
})();
""" % (json.dumps(TEST), json.dumps(ours), json.dumps(TEST))
reports, am = run_phase("G-apply", os.environ["LAUNCHER_DECLARATIVE"], {}, READ_OURS)
check(am["mtime"] == 0, f"G: Firefox decodes the rewritten addonStartup.json.lz4 (mtime {am['mtime']})")
check(reports[TEST]["version"] == "2.0", f"G: rebuilt extension runs (v{reports[TEST]['version']})")
check(am["version"] == "2.0", f"G: add-on database reloaded the rebuilt extension ({am['version']})")
check(
    reports[TEST]["local"] == declarative_local,
    "G: storage survives the upgrade",
)
out = subprocess.run(
    [os.environ["FIREFOX_WEBEXT"], "apply", "--manifest", os.environ["MANIFEST_DECLARATIVE"]],
    capture_output=True,
    text=True,
    check=True,
)
check(out.stdout.strip() == "", f"G: no refresh once recorded: {out.stdout.strip()!r}")
reports, am = run_phase("G-again", os.environ["LAUNCHER_DECLARATIVE"], {}, ADDON_VERSION)
check(reports[TEST]["version"] == "2.0" and am["version"] == "2.0", "G: still v2 on the next launch")

# D: applier refuses to touch a profile held by a live Firefox.
lock = os.path.join(PROFILE, "lock")
if os.path.lexists(lock):
    os.unlink(lock)
os.symlink(f"127.0.0.1:+{os.getpid()}", lock)
out = subprocess.run(
    [os.environ["FIREFOX_WEBEXT"], "apply", "--manifest", os.environ["MANIFEST"], "--strict"],
    capture_output=True,
    text=True,
)
check(out.returncode == 2 and "in use by Firefox" in out.stderr, f"D: locked profile skipped: {out.stderr.strip()}")
os.unlink(lock)

server.shutdown()
if failures:
    fail(f"{len(failures)} check(s) failed")
print("all checks passed")
