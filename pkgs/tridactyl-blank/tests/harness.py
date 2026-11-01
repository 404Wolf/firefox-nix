"""Drive the home-manager Firefox with addons.tridactyl over Marionette.

For each colour scheme: build a fresh profile from the home-manager files,
start the launcher (which applies the extension state before exec'ing
Firefox), then check the first window, Ctrl+T, the binds and the colours.
Screenshots land in $out.
"""

import base64
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import time

from PIL import Image

PROFILE = os.environ["PROFILE"]
UUID = os.environ["UUID"]
OUT = os.environ["out"]
USERCONFIG = json.loads(os.environ["USERCONFIG"])
NEWTAB = f"moz-extension://{UUID}/static/newtab.html"

failures = []


def check(ok, msg):
    print(("ok   " if ok else "FAIL ") + msg, flush=True)
    if not ok:
        failures.append(msg)


def wait_for(fn, timeout=30, interval=0.25):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            last = fn()
            if last:
                return last
        except RuntimeError as e:  # page mid-load, context gone, ...
            last = e
        time.sleep(interval)
    return last


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
        self.context("chrome")

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

    def context(self, ctx):
        self.cmd("Marionette:SetContext", {"value": ctx})

    def chrome(self, body):
        self.context("chrome")
        return self.cmd("WebDriver:ExecuteScript", {"script": body, "args": []})["value"]

    def select_tab(self):
        """Point content-context commands at the tab selected in the UI."""
        index = self.chrome("return gBrowser.tabContainer.selectedIndex")
        self.context("content")
        handles = self.cmd("WebDriver:GetWindowHandles")
        handles = handles["value"] if isinstance(handles, dict) else handles
        self.cmd("WebDriver:SwitchToWindow", {"handle": handles[index]})

    def content(self, body):
        """Run in the selected tab's page, with Xray waived (page globals visible)."""
        self.select_tab()
        return self.cmd(
            "WebDriver:ExecuteScript", {"script": body, "args": [], "sandbox": None}
        )["value"]

    def keys(self, text):
        self.select_tab()
        actions = []
        for ch in text:
            actions += [{"type": "keyDown", "value": ch}, {"type": "keyUp", "value": ch}]
        self.cmd(
            "WebDriver:PerformActions",
            {"actions": [{"type": "key", "id": "kbd", "actions": actions}]},
        )
        self.cmd("WebDriver:ReleaseActions")

    def pixel(self, name):
        self.content("return 1")
        png = base64.b64decode(self.cmd("WebDriver:TakeScreenshot", {"full": False})["value"])
        with open(f"{OUT}/{name}.png", "wb") as f:
            f.write(png)
        return Image.open(io.BytesIO(png)).convert("RGB").getpixel((5, 5))

    def quit(self):
        try:
            self.cmd("Marionette:Quit", {"flags": ["eForceQuit"]})
        except (OSError, RuntimeError, ValueError):
            pass


SCHEMES = {
    # Firefox's default theme, content forced light / dark.
    "light": {
        "extensions.activeThemeID": "default-theme@mozilla.org",
        "ui.systemUsesDarkTheme": 0,
        "layout.css.prefers-color-scheme.content-override": 1,
    },
    "dark": {
        "extensions.activeThemeID": "default-theme@mozilla.org",
        "ui.systemUsesDarkTheme": 1,
        "layout.css.prefers-color-scheme.content-override": 0,
    },
    # Developer Edition's own dark theme, which sets the new tab colours.
    "devedition-theme": {},
}


def fresh_profile(prefs):
    shutil.rmtree(os.environ["HOME"], ignore_errors=True)
    os.makedirs(f"{PROFILE}/extensions")
    shutil.copy(os.environ["PROFILES_INI"], f"{PROFILE}/../profiles.ini")
    shutil.copy(os.environ["USER_JS"], f"{PROFILE}/user.js")
    for f in os.listdir(os.environ["EXTENSIONS"]):
        shutil.copy(os.path.join(os.environ["EXTENSIONS"], f), f"{PROFILE}/extensions/{f}")
    subprocess.run(["chmod", "-R", "u+w", os.environ["HOME"]], check=True)
    with open(f"{PROFILE}/user.js", "a") as f:
        for k, v in prefs.items():
            f.write(f"user_pref({json.dumps(k)}, {json.dumps(v)});\n")


TRI_STATE = """
const tri = window.tri;
return tri && tri.config && {
  hintchars: tri.config.get("hintchars"),
  smoothscroll: tri.config.get("smoothscroll"),
  ctrlF: tri.config.get("nmaps", "<C-f>") ?? null,
  q: tri.config.get("nmaps", "Q") ?? null,
  nixtest: tri.config.get("searchurls", "nixtest") ?? null,
  google: tri.config.get("searchurls", "google") ?? null,
  indicator: document.querySelector(".TridactylStatusIndicator")?.textContent ?? null,
};
"""

TAB_STATE = """
return (async () => {
await SessionStore.promiseAllWindowsRestored;
return {
  tabs: gBrowser.tabs.length,
  url: gBrowser.currentURI.spec,
  urlbar: gURLBar.value,
  urlbarFocused: gURLBar.focused,
  pageFocused: document.activeElement === gBrowser.selectedBrowser,
  closed: SessionStore.getClosedTabCountForWindow(window),
};
})();
"""


def run(scheme):
    print(f"--- {scheme}", flush=True)
    fresh_profile(SCHEMES[scheme])
    log = open(f"firefox-{scheme}.log", "w")
    env = dict(os.environ, MOZ_HEADLESS="1", MOZ_REMOTE_ALLOW_SYSTEM_ACCESS="1",
               MOZ_HEADLESS_WIDTH="1024", MOZ_HEADLESS_HEIGHT="768")
    proc = subprocess.Popen(
        [os.environ["LAUNCHER"], "--headless", "--no-remote", "--profile", PROFILE, "--marionette"],
        env=env, stdout=log, stderr=subprocess.STDOUT,
    )
    m = None
    try:
        m = Marionette()

        # First window: straight onto the blank page, nothing else opened.
        first = wait_for(lambda: m.chrome(TAB_STATE)["url"].startswith(NEWTAB) and m.chrome(TAB_STATE))
        if not isinstance(first, dict):
            first = m.chrome(TAB_STATE)
        print("     first window:", first, flush=True)
        check(first["url"].startswith(NEWTAB), f"{scheme}: first window opens the blank page ({first['url']})")
        check(first["tabs"] == 1, f"{scheme}: no tutorial or what's-new tab ({first['tabs']} tabs)")
        check(first["urlbar"] == "", f"{scheme}: first window address bar is empty")
        check(first["pageFocused"] and not first["urlbarFocused"], f"{scheme}: first window focuses the page")

        tri = wait_for(lambda: (s := m.content(TRI_STATE)) and s.get("indicator") and s, timeout=30)
        print("     tridactyl:", tri, flush=True)
        tri = tri if isinstance(tri, dict) else {}
        check(tri.get("indicator") == "normal", f"{scheme}: content.js runs on the page (mode indicator)")
        check(tri.get("hintchars") == "qwer", f"{scheme}: Nix setting applied (hintchars)")
        check(tri.get("smoothscroll") == "true", f"{scheme}: boolean setting stored as \"true\"")
        check(tri.get("ctrlF") is None, f"{scheme}: <c-f> = null unbinds <C-f>")
        check(tri.get("q") == USERCONFIG["nmaps"]["Q"], f"{scheme}: Nix bind present")
        check(tri.get("nixtest") == "https://example.invalid/?q=", f"{scheme}: search URL added")
        check(bool(tri.get("google")), f"{scheme}: defaults still merged in (searchurls.google)")
        check(m.content("return document.title") == "New Tab", f"{scheme}: title is New Tab")

        blank_bg = m.pixel(f"{scheme}-blank")

        # The Nix bind does something.
        m.keys("Q")
        title = wait_for(lambda: m.content("return document.title") == "bound by nix" and "bound by nix", timeout=10)
        check(title == "bound by nix", f"{scheme}: pressing Q runs the Nix bind ({title})")

        # Ctrl+T.
        m.chrome("BrowserCommands.openTab()")
        state = wait_for(
            lambda: (s := m.chrome(TAB_STATE))["tabs"] == 2 and "?focus" in s["url"] and s,
            timeout=15,
        )
        wait_for(lambda: m.chrome(TAB_STATE)["closed"] == 0, timeout=5)
        state = m.chrome(TAB_STATE)
        print("     after Ctrl+T:", state, flush=True)
        check(state["tabs"] == 2, f"{scheme}: Ctrl+T adds exactly one tab ({state['tabs']})")
        check(state["url"].startswith(NEWTAB), f"{scheme}: Ctrl+T opens the blank page ({state['url']})")
        check(state["urlbar"] == "", f"{scheme}: Ctrl+T address bar is empty ({state['urlbar']!r})")
        check(state["pageFocused"] and not state["urlbarFocused"], f"{scheme}: Ctrl+T focuses the page")
        check(state["closed"] == 0, f"{scheme}: nothing in Reopen Closed Tab ({state['closed']})")

        # Reloading the replacement tab must not close anything (the token is
        # one-shot).
        m.chrome("gBrowser.reload(); return 1")
        time.sleep(2)
        check(m.chrome(TAB_STATE)["tabs"] == 2, f"{scheme}: reloading the new tab closes nothing")

        # A default bind: `:` opens the command line.
        wait_for(lambda: m.content("return document.querySelector('.TridactylStatusIndicator')"))
        m.keys(":")
        frame = wait_for(lambda: m.content(
            "const f = document.getElementById('cmdline_iframe');"
            "return f && !f.classList.contains('hidden') && f.className"), timeout=10)
        check(isinstance(frame, str), f"{scheme}: ':' opens the command line ({frame})")

        # Firefox's own page, for the colour.
        m.chrome(
            "gBrowser.selectedBrowser.loadURI(Services.io.newURI('about:home'),"
            " {triggeringPrincipal: Services.scriptSecurityManager.getSystemPrincipal()});"
            "return 1"
        )
        wait_for(lambda: m.chrome("return gBrowser.currentURI.spec") == "about:home")
        time.sleep(2)
        home_bg = m.pixel(f"{scheme}-about-home")
        check(blank_bg == home_bg, f"{scheme}: background matches about:home (blank={blank_bg} home={home_bg})")
    except Exception as e:  # noqa: BLE001 - report and keep the logs
        failures.append(f"{scheme}: {e!r}")
        print(f"FAIL {scheme}: {e!r}", flush=True)
    finally:
        if m:
            m.quit()
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()


for scheme in SCHEMES:
    run(scheme)

if failures:
    for f in sorted(os.listdir(".")):
        if f.startswith("firefox-") and f.endswith(".log"):
            print(f"== {f}\n" + open(f).read()[-3000:])
    print(f"{len(failures)} check(s) failed")
    sys.exit(1)
print("all checks passed")
