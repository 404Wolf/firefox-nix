#!/usr/bin/env python3
"""Declarative WebExtension storage for Firefox profiles.

Subcommands:

  encode SPEC OUT    Build time (Nix sandbox). Turns a JSON spec into a state
                     bundle: storage.local rows pre-encoded exactly as Firefox
                     stores them in IndexedDB (key encoding + SpiderMonkey
                     structured clone + snappy), storage.sync JSON, and the
                     plain values for the storage.js fallback. Needs snappy.

  apply              Activation / launch time. Merges bundles into a closed
                     profile. Standard library only: rows are copied as bytes.

  dump               Decodes a profile's storage.local (IndexedDB) and
                     storage.sync for inspection or seeding. Needs snappy.

Firefox must be closed while a profile is written; apply skips locked profiles.
"""

import argparse
import base64
import json
import math
import os
import re
import sqlite3
import struct
import sys
import uuid as uuidlib

BUNDLE_VERSION = 1

# --- Firefox / SpiderMonkey constants ---------------------------------------

# storage.local lives in a reserved user context of the extension's origin.
STORAGE_USER_CONTEXT = 4294967295
IDB_OBJECT_STORE = "storage-local-data"
# IndexedDB file name for the "webExtensions-storage-local" database
# (hash + interleaved name, as computed by Firefox's GetDatabaseFilenameBase).
IDB_FILE_BASE = "3647222921wleabcEoxlt-eengsairo"
UUIDS_PREF = "extensions.webextensions.uuids"
MIGRATED_PREF = "extensions.webextensions.ExtensionStorageIDB.migrated."
# Firefox stores larger values outside the database (dom.indexedDB.dataThreshold).
IDB_DATA_THRESHOLD = 1024 * 1024

SC_FLOAT_MAX = 0xFFF00000
SC_HEADER = 0xFFF10000
SC_NULL = 0xFFFF0000
SC_UNDEFINED = 0xFFFF0001
SC_BOOLEAN = 0xFFFF0002
SC_INT32 = 0xFFFF0003
SC_STRING = 0xFFFF0004
SC_DATE = 0xFFFF0005
SC_REGEXP = 0xFFFF0006
SC_ARRAY = 0xFFFF0007
SC_OBJECT = 0xFFFF0008
SC_BOOLEAN_OBJECT = 0xFFFF000A
SC_STRING_OBJECT = 0xFFFF000B
SC_NUMBER_OBJECT = 0xFFFF000C
SC_BACK_REFERENCE = 0xFFFF000D
SC_MAP = 0xFFFF0011
SC_SET = 0xFFFF0012
SC_END_OF_KEYS = 0xFFFF0013
# Scope written in the header of every storage.local value we have observed.
SC_SCOPE = 3

SYNC_SCHEMA = """
CREATE TABLE storage_sync_data (
    ext_id TEXT NOT NULL PRIMARY KEY,
    data TEXT,
    sync_change_counter INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE storage_sync_mirror (
    guid TEXT NOT NULL PRIMARY KEY,
    ext_id TEXT UNIQUE,
    data TEXT
    CHECK((ext_id IS NULL AND data IS NULL) OR (ext_id IS NOT NULL AND data IS NOT NULL))
);
CREATE TABLE meta (
    key TEXT PRIMARY KEY,
    value NOT NULL
) WITHOUT ROWID;
PRAGMA user_version = 2;
"""


# --- IndexedDB key encoding (dom/indexedDB/Key.cpp) --------------------------

KEY_STRING = 0x30


def encode_key(key):
    out = bytearray([KEY_STRING])
    units = key.encode("utf-16-le")
    for i in range(0, len(units), 2):
        c = units[i] | (units[i + 1] << 8)
        if c <= 0x7E:
            out.append(c + 1)
        elif c <= 0x3FFF + 0x7F:
            c -= 0x7F
            out += bytes([(c >> 8) | 0x80, c & 0xFF])
        else:
            c = (c << 6) | 0x00C00000
            out += bytes([c >> 16, (c >> 8) & 0xFF, c & 0xFF])
    # Firefox trims the trailing terminator of a lone string key.
    return bytes(out)


def decode_key(raw):
    if not raw or raw[0] != KEY_STRING:
        return "$key:" + raw.hex()
    units = []
    i, n = 1, len(raw)
    while i < n and raw[i] != 0:
        b = raw[i]
        if not b & 0x80:
            units.append(b - 1)
            i += 1
        elif not b & 0x40:
            c = b << 8
            if i + 1 < n:
                c |= raw[i + 1]
            units.append(c - 0x8000 + 0x7F)
            i += 2
        else:
            c = b << 10
            if i + 1 < n:
                c |= raw[i + 1] << 2
            if i + 2 < n:
                c |= raw[i + 2] >> 6
            units.append(c & 0xFFFF)
            i += 3
    return b"".join(struct.pack("<H", u) for u in units).decode(
        "utf-16-le", errors="surrogatepass"
    )


# --- Structured clone (js/src/vm/StructuredClone.cpp) ------------------------

INDEX_KEY = re.compile(r"^(0|[1-9][0-9]{0,9})$")


def _is_index(key):
    return bool(INDEX_KEY.match(key)) and int(key) <= 0x7FFFFFFE


class Writer:
    def __init__(self):
        self.buf = bytearray()

    def pair(self, tag, data):
        self.buf += struct.pack("<II", data & 0xFFFFFFFF, tag)

    def string(self, s):
        if all(ord(ch) < 256 for ch in s):
            chars = s.encode("latin-1")
            self.pair(SC_STRING, len(chars) | 0x80000000)
        else:
            chars = s.encode("utf-16-le", errors="surrogatepass")
            self.pair(SC_STRING, len(chars) // 2)
        self.buf += chars
        self.buf += b"\0" * (-len(chars) % 8)

    def key(self, k):
        if _is_index(k):
            self.pair(SC_INT32, int(k))
        else:
            self.string(k)

    def value(self, v):
        if v is None:
            self.pair(SC_NULL, 0)
        elif v is True or v is False:
            self.pair(SC_BOOLEAN, int(v))
        elif isinstance(v, int) and -(2**31) <= v < 2**31:
            self.pair(SC_INT32, v)
        elif isinstance(v, (int, float)):
            f = float(v)
            if f.is_integer() and -(2**31) <= f < 2**31 and not (
                f == 0 and math.copysign(1, f) < 0
            ):
                self.pair(SC_INT32, int(f))
            elif math.isnan(f):
                self.buf += struct.pack("<Q", 0x7FF8000000000000)
            else:
                self.buf += struct.pack("<d", f)
        elif isinstance(v, str):
            self.string(v)
        elif isinstance(v, list):
            self.pair(SC_ARRAY, len(v))
            for i, item in enumerate(v):
                self.pair(SC_INT32, i)
                self.value(item)
            self.pair(SC_END_OF_KEYS, 0)
        elif isinstance(v, dict):
            self.pair(SC_OBJECT, 0)
            # Like SpiderMonkey's property order: indices ascending, then names.
            keys = sorted((k for k in v if _is_index(k)), key=int)
            keys += [k for k in v if not _is_index(k)]
            for k in keys:
                self.key(k)
                self.value(v[k])
            self.pair(SC_END_OF_KEYS, 0)
        else:
            raise TypeError(f"cannot encode {type(v).__name__} for storage.local")


def sc_encode(value):
    w = Writer()
    w.pair(SC_HEADER, SC_SCOPE)
    w.value(value)
    return bytes(w.buf)


class Unsupported(Exception):
    pass


class Reader:
    def __init__(self, buf):
        self.buf = buf
        self.pos = 0
        self.objs = []

    def pair(self):
        data, tag = struct.unpack_from("<II", self.buf, self.pos)
        self.pos += 8
        return tag, data

    def peek_tag(self):
        return struct.unpack_from("<I", self.buf, self.pos + 4)[0]

    def chars(self, data):
        n = data & 0x7FFFFFFF
        if data & 0x80000000:
            s = bytes(self.buf[self.pos : self.pos + n]).decode("latin-1")
            size = n
        else:
            size = n * 2
            s = bytes(self.buf[self.pos : self.pos + size]).decode(
                "utf-16-le", errors="surrogatepass"
            )
        self.pos += size + (-size % 8)
        return s

    def double(self):
        f = struct.unpack_from("<d", self.buf, self.pos)[0]
        self.pos += 8
        return f

    def string(self):
        tag, data = self.pair()
        if tag != SC_STRING:
            raise Unsupported(f"expected string, got tag {tag:#x}")
        return self.chars(data)

    def value(self):
        tag = self.peek_tag()
        if tag < SC_FLOAT_MAX:
            f = self.double()
            return int(f) if f.is_integer() and abs(f) < 2**53 else f
        tag, data = self.pair()
        if tag == SC_NULL:
            return None
        if tag == SC_UNDEFINED:
            return {"$undefined": True}
        if tag == SC_BOOLEAN:
            return bool(data)
        if tag == SC_INT32:
            return struct.unpack("<i", struct.pack("<I", data))[0]
        if tag == SC_STRING:
            return self.chars(data)
        if tag == SC_DATE:
            v = {"$date": self.double()}
            self.objs.append(v)
            return v
        if tag == SC_REGEXP:
            v = {"$regexp": None, "flags": data}
            self.objs.append(v)
            v["$regexp"] = self.string()
            return v
        if tag == SC_BOOLEAN_OBJECT:
            v = {"$boolean": bool(data)}
            self.objs.append(v)
            return v
        if tag == SC_STRING_OBJECT:
            v = {"$string": None}
            self.objs.append(v)
            v["$string"] = self.string()
            return v
        if tag == SC_NUMBER_OBJECT:
            v = {"$number": self.double()}
            self.objs.append(v)
            return v
        if tag == SC_BACK_REFERENCE:
            return {"$ref": data, "value": "(circular)"} if data >= len(self.objs) else self.objs[data]
        if tag == SC_ARRAY:
            arr = [None] * data
            self.objs.append(arr)
            while self.peek_tag() != SC_END_OF_KEYS:
                k = self.value()
                item = self.value()
                if isinstance(k, int) and 0 <= k < len(arr):
                    arr[k] = item
            self.pair()
            return arr
        if tag == SC_OBJECT:
            obj = {}
            self.objs.append(obj)
            while self.peek_tag() != SC_END_OF_KEYS:
                k = self.value()
                obj[str(k)] = self.value()
            self.pair()
            return obj
        if tag == SC_MAP:
            entries = []
            v = {"$map": entries}
            self.objs.append(v)
            while self.peek_tag() != SC_END_OF_KEYS:
                entries.append([self.value(), self.value()])
            self.pair()
            return v
        if tag == SC_SET:
            items = []
            v = {"$set": items}
            self.objs.append(v)
            while self.peek_tag() != SC_END_OF_KEYS:
                items.append(self.value())
            self.pair()
            return v
        raise Unsupported(f"structured clone tag {tag:#010x}")


def sc_decode(buf):
    r = Reader(buf)
    tag, _ = r.pair()
    if tag != SC_HEADER:
        r.pos = 0
    return r.value()


# --- keyboard shortcuts --------------------------------------------------------

# toolkit/modules/ShortcutUtils.sys.mjs validate(), for user-set shortcuts.
SHORTCUT_MODIFIERS = {"Alt": "alt", "Command": "accel", "Ctrl": "accel", "MacCtrl": "control", "Shift": "shift"}
SHORTCUT_MEDIA_KEYS = re.compile(r"^(MediaNextTrack|MediaPlayPause|MediaPrevTrack|MediaStop)$")
SHORTCUT_BASIC_KEYS = re.compile(
    r"^([A-Z0-9]|Comma|Period|Home|End|PageUp|PageDown|Space|Insert|Delete|Up|Down|Left|Right)$"
)
SHORTCUT_FUNCTION_KEYS = re.compile(r"^(F[1-9]|F1[0-9])$")


def shortcut_error(shortcut):
    """Why Firefox would reject a shortcut, or None if it is valid."""
    if SHORTCUT_MEDIA_KEYS.match(shortcut.strip()):
        return None
    parts = [p.strip() for p in shortcut.split("+")]
    key = parts.pop()
    mods = [SHORTCUT_MODIFIERS.get(m) for m in parts]
    if None in mods:
        return "unknown modifier (use Alt, Ctrl, Command, MacCtrl, Shift)"
    function_key = bool(SHORTCUT_FUNCTION_KEYS.match(key))
    if not mods and not function_key:
        return "needs a modifier"
    if mods == ["shift"] and not function_key:
        return "Shift alone needs a function key"
    if len(mods) == 2 and mods[0] == mods[1]:
        return "duplicate modifier"
    if len(mods) > 2:
        return "at most two modifiers"
    if not SHORTCUT_BASIC_KEYS.match(key) and not function_key:
        return "unsupported key (A-Z, 0-9, F1-F19, Comma, Period, Space, arrows, ...)"
    return None


# --- encode (build time) -------------------------------------------------------


def cmd_encode(args):
    import snappy

    with open(args.spec) as f:
        spec = json.load(f)
    bundle = {"version": BUNDLE_VERSION, "extensions": {}}
    for ext_id, ext in sorted(spec.get("extensions", {}).items()):
        out = {"uuid": ext.get("uuid")}
        local = ext.get("local", {})

        def encode_value(key, value):
            data = snappy.compress(sc_encode(value))
            if len(data) >= IDB_DATA_THRESHOLD:
                sys.exit(
                    f"{ext_id}: storage.local key {key!r} is {len(data)} bytes; "
                    "Firefox stores values this large outside the database, "
                    "which this tool does not support"
                )
            return base64.b64encode(data).decode()

        rows = {}
        for mode in ("force", "defaults"):
            rows[mode] = {
                key: {
                    "key": base64.b64encode(encode_key(key)).decode(),
                    "data": encode_value(key, value),
                    "json": value,
                }
                for key, value in sorted(local.get(mode, {}).items())
            }
        # Keys with an {id} placeholder, expanded at apply time for every id
        # captured from the extension's existing keys. Values are encoded now;
        # keys are encoded at apply time (stdlib only).
        templates = []
        for name, tpl in sorted(local.get("templates", {}).items()):
            try:
                if re.compile(tpl["idsFromKeys"]).groups != 1:
                    raise re.error("needs exactly one capture group")
            except re.error as e:
                sys.exit(f"{ext_id}: template {name!r}: idsFromKeys: {e}")
            t = {"name": name, "idsFromKeys": tpl["idsFromKeys"]}
            for mode in ("force", "defaults"):
                t[mode] = {}
                for key, value in sorted(tpl.get(mode, {}).items()):
                    if "{id}" not in key:
                        sys.exit(f"{ext_id}: template {name!r}: key {key!r} has no {{id}}")
                    t[mode][key] = {"data": encode_value(key, value), "json": value}
            templates.append(t)
        out["local"] = {
            **rows,
            "templates": templates,
            "resetUndeclared": bool(local.get("resetUndeclared")),
        }
        sync = ext.get("sync", {})
        out["sync"] = {
            "force": sync.get("force", {}),
            "defaults": sync.get("defaults", {}),
            "resetUndeclared": bool(sync.get("resetUndeclared")),
        }
        commands = ext.get("commands", {})
        for name, shortcut in commands.items():
            error = shortcut_error(shortcut) if shortcut is not None else None
            if error:
                sys.exit(f"{ext_id}: command {name!r}: shortcut {shortcut!r}: {error}")
        out["commands"] = commands
        bundle["extensions"][ext_id] = out
    with open(args.out, "w") as f:
        json.dump(bundle, f, indent=1, sort_keys=True)


# --- profile helpers -------------------------------------------------------------


def profile_lock_owner(profile):
    """PID of a live Firefox holding the profile, or None."""
    lock = os.path.join(profile, "lock")
    try:
        target = os.readlink(lock)
    except OSError:
        return None
    m = re.search(r"\+(\d+)$", target)
    if not m:
        return -1  # Unknown lock format: assume it is held.
    pid = int(m.group(1))
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError:
        pass
    return pid


PREF_LINE = re.compile(r'^user_pref\("((?:[^"\\]|\\.)*)",\s*(.*)\);\s*$')


class Prefs:
    """Minimal prefs.js editor that keeps every untouched line verbatim."""

    def __init__(self, profile):
        self.path = os.path.join(profile, "prefs.js")
        self.lines = []
        if os.path.exists(self.path):
            with open(self.path, encoding="utf-8") as f:
                self.lines = f.read().splitlines()
        self.dirty = False

    def _find(self, name):
        for i, line in enumerate(self.lines):
            m = PREF_LINE.match(line)
            if m and json.loads(f'"{m.group(1)}"') == name:
                return i, m.group(2)
        return None, None

    def get(self, name):
        _, raw = self._find(name)
        return None if raw is None else json.loads(raw)

    def set(self, name, value):
        line = f"user_pref({json.dumps(name)}, {json.dumps(value)});"
        i, _ = self._find(name)
        if i is None:
            self.lines.append(line)
        elif self.lines[i] != line:
            self.lines[i] = line
        else:
            return
        self.dirty = True

    def remove(self, name):
        i, _ = self._find(name)
        if i is not None:
            del self.lines[i]
            self.dirty = True

    def save(self):
        if self.dirty:
            write_atomic(self.path, "\n".join(self.lines) + "\n")


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".webext-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def idb_path(profile, ext_uuid):
    origin = f"moz-extension+++{ext_uuid}^userContextId={STORAGE_USER_CONTEXT}"
    return os.path.join(profile, "storage", "default", origin, "idb", IDB_FILE_BASE + ".sqlite")


def open_idb(path, readonly=False):
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True) if readonly else sqlite3.connect(path)
    # Firefox's triggers call this to track blob files; our rows never have any.
    db.create_function("update_refcount", 2, lambda old, new: None)
    return db


# --- apply -------------------------------------------------------------------


class Log:
    def __init__(self, quiet):
        self.quiet = quiet

    def __call__(self, msg):
        if not self.quiet:
            print(f"firefox-webext: {msg}")


def expand_templates(templates, existing, wanted):
    """Add template rows to `wanted` for every id found in the existing keys.

    An id is the capture group of `idsFromKeys` over the extension's current
    key names, so a template only reaches ids the extension has created (for
    example logged-in accounts); none yet means nothing to do until a later
    apply. Explicit rows win over template rows for the same key.
    """
    names = [decode_key(k) for k in existing]
    for t in templates:
        pattern = re.compile(t["idsFromKeys"])
        ids = sorted({m.group(1) for n in names for m in [pattern.search(n)] if m})
        for mode in ("defaults", "force"):
            for key_tpl, item in t[mode].items():
                for i in ids:
                    key = encode_key(key_tpl.replace("{id}", i))
                    if key not in wanted["force"] and key not in wanted["defaults"]:
                        wanted[mode][key] = base64.b64decode(item["data"])


def apply_local_idb(path, ext_id, local, log):
    db = open_idb(path)
    try:
        row = db.execute("SELECT id FROM object_store WHERE name = ?", (IDB_OBJECT_STORE,)).fetchone()
        if row is None:
            return False
        store = row[0]
        existing = {
            bytes(k): bytes(d)
            for k, d in db.execute("SELECT key, data FROM object_data WHERE object_store_id = ?", (store,))
        }
        changed = 0
        declared = set()
        wanted = {
            mode: {
                base64.b64decode(item["key"]): base64.b64decode(item["data"])
                for item in local[mode].values()
            }
            for mode in ("defaults", "force")
        }
        expand_templates(local.get("templates", []), existing, wanted)
        for mode in ("defaults", "force"):
            for key, data in wanted[mode].items():
                declared.add(key)
                if key in existing and (mode == "defaults" or existing[key] == data):
                    continue
                db.execute(
                    "INSERT OR REPLACE INTO object_data (object_store_id, key, data) VALUES (?, ?, ?)",
                    (store, key, data),
                )
                existing[key] = data
                changed += 1
        if local["resetUndeclared"]:
            for key in set(existing) - declared:
                db.execute("DELETE FROM object_data WHERE object_store_id = ? AND key = ?", (store, key))
                changed += 1
        db.commit()
        if changed:
            log(f"{ext_id}: storage.local updated {changed} key(s) in IndexedDB")
        return True
    finally:
        db.close()


def apply_local_json(profile, prefs, ext_id, local, log):
    path = os.path.join(profile, "browser-extension-data", ext_id, "storage.js")
    current = {}
    if os.path.exists(path) and not local["resetUndeclared"]:
        try:
            with open(path, encoding="utf-8") as f:
                current = json.load(f)
        except ValueError:
            current = {}
    new = dict(current)
    for key, item in local["defaults"].items():
        new.setdefault(key, item["json"])
    for key, item in local["force"].items():
        new[key] = item["json"]
    if new != current or not os.path.exists(path):
        write_atomic(path, json.dumps(new))
        log(f"{ext_id}: storage.local staged in storage.js (imported on first start)")
    # Firefox only imports storage.js while this pref is unset.
    prefs.remove(MIGRATED_PREF + ext_id)


def apply_sync(profile, ext_id, sync, log):
    if not (sync["force"] or sync["defaults"] or sync["resetUndeclared"]):
        return
    path = os.path.join(profile, "storage-sync-v2.sqlite")
    fresh = not os.path.exists(path)
    db = sqlite3.connect(path)
    try:
        if fresh:
            db.executescript(SYNC_SCHEMA)
        row = db.execute("SELECT data FROM storage_sync_data WHERE ext_id = ?", (ext_id,)).fetchone()
        current = json.loads(row[0]) if row and row[0] else {}
        new = {} if sync["resetUndeclared"] else dict(current)
        for key, value in sync["defaults"].items():
            new.setdefault(key, current.get(key, value))
        new.update(sync["force"])
        if new == current and row is not None:
            return
        db.execute(
            """INSERT INTO storage_sync_data (ext_id, data, sync_change_counter) VALUES (?, ?, 1)
               ON CONFLICT(ext_id) DO UPDATE SET data = excluded.data,
                 sync_change_counter = sync_change_counter + 1""",
            (ext_id, json.dumps(new, separators=(",", ":"))),
        )
        db.commit()
        log(f"{ext_id}: storage.sync updated")
    finally:
        db.close()


# --- rebuilt extensions --------------------------------------------------------
#
# Firefox re-reads a profile extension's metadata only when the XPI's mtime or
# path changes. Nix store files all have mtime 1 and home-manager's link
# <profile>/extensions/<id>.xpi keeps its path, so a rebuilt extension would
# run its new code under the old add-on database entry (old version, no
# upgrade, stale permissions). We remember which store file each link
# resolved to, and when that changes, zero the recorded mtimes in
# addonStartup.json.lz4 and extensions.json, so Firefox sees a modified add-on.

XPI_STATE_FILE = "firefox-webext-xpis.json"
MOZLZ4_MAGIC = b"mozLz40\0"


def lz4_block_decompress(src, size):
    out = bytearray()
    i = 0
    while i < len(src):
        token = src[i]
        i += 1
        n = token >> 4
        if n == 15:
            while True:
                b = src[i]
                i += 1
                n += b
                if b != 255:
                    break
        out += src[i : i + n]
        i += n
        if i >= len(src):
            break
        offset = src[i] | (src[i + 1] << 8)
        i += 2
        m = token & 15
        if m == 15:
            while True:
                b = src[i]
                i += 1
                m += b
                if b != 255:
                    break
        m += 4
        start = len(out) - offset
        for k in range(m):  # may overlap its own output
            out.append(out[start + k])
    if len(out) != size:
        raise ValueError("lz4: size mismatch")
    return bytes(out)


def lz4_block_literals(data):
    """A valid LZ4 block holding `data` as one literal run (no compression)."""
    n = len(data)
    out = bytearray([min(n, 15) << 4])
    if n >= 15:
        rest = n - 15
        while rest >= 255:
            out.append(255)
            rest -= 255
        out.append(rest)
    return bytes(out) + data


def read_mozlz4(path):
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:8] != MOZLZ4_MAGIC:
        raise ValueError("not a mozlz4 file")
    size = struct.unpack_from("<I", raw, 8)[0]
    return lz4_block_decompress(raw[12:], size)


def write_mozlz4(path, data):
    tmp = path + ".webext-tmp"
    with open(tmp, "wb") as f:
        f.write(MOZLZ4_MAGIC + struct.pack("<I", len(data)) + lz4_block_literals(data))
    os.replace(tmp, path)


def store_xpis(profile):
    """{addon id: store file} for profile extensions linked into the Nix store."""
    found = {}
    ext_dir = os.path.join(profile, "extensions")
    if not os.path.isdir(ext_dir):
        return found
    for name in os.listdir(ext_dir):
        path = os.path.join(ext_dir, name)
        if name.endswith(".xpi") and os.path.islink(path):
            target = os.path.realpath(path)
            if target.startswith("/nix/store/"):
                found[name[: -len(".xpi")]] = target
    return found


def refresh_rebuilt_xpis(profile, log):
    state_path = os.path.join(profile, XPI_STATE_FILE)
    current = store_xpis(profile)
    try:
        with open(state_path) as f:
            previous = json.load(f)
    except (OSError, ValueError):
        # First run: we can't know what the database saw, so refresh them all once.
        previous = {}
    changed = {i for i, p in current.items() if previous.get(i) != p}
    if changed:
        startup = os.path.join(profile, "addonStartup.json.lz4")
        db_path = os.path.join(profile, "extensions.json")
        touched = set()
        if os.path.exists(startup):
            try:
                states = json.loads(read_mozlz4(startup))
                for loc in states.values():
                    for ext_id, addon in loc.get("addons", {}).items():
                        if ext_id in changed and addon.get("lastModifiedTime") != 0:
                            addon["lastModifiedTime"] = 0
                            touched.add(ext_id)
                if touched:
                    write_mozlz4(startup, json.dumps(states, separators=(",", ":")).encode())
            except (ValueError, KeyError, IndexError, struct.error):
                # Unreadable cache: Firefox rebuilds it from a full scan.
                os.unlink(startup)
                touched = set(changed)
        if touched and os.path.exists(db_path):
            with open(db_path, encoding="utf-8") as f:
                db = json.load(f)
            for addon in db.get("addons", []):
                if addon.get("id") in touched and addon.get("location") == "app-profile":
                    addon["updateDate"] = 0
            write_atomic(db_path, json.dumps(db, separators=(",", ":")))
        for ext_id in sorted(touched):
            if ext_id in previous:
                log(f"{ext_id}: rebuilt, Firefox will reload it")
    if current != previous:
        write_atomic(state_path, json.dumps(current, indent=1, sort_keys=True))


SETTINGS_STORE_VERSION = 3


def apply_commands(profile, ext_id, commands, log):
    """Set shortcuts the way about:addons "Manage Extension Shortcuts" does.

    extension-settings.json (ExtensionSettingsStore) keeps, per command name, a
    precedence list of per-extension overrides; Firefox merges an extension's
    entry over its manifest's suggested_key at startup. An empty shortcut
    means "no shortcut".
    """
    if not commands:
        return
    path = os.path.join(profile, "extension-settings.json")
    try:
        with open(path, encoding="utf-8") as f:
            store = json.load(f)
    except (OSError, ValueError):
        store = {"version": SETTINGS_STORE_VERSION}
    before = json.dumps(store, sort_keys=True)
    install_date = 0
    try:
        with open(os.path.join(profile, "extensions.json"), encoding="utf-8") as f:
            for addon in json.load(f).get("addons", []):
                if addon.get("id") == ext_id:
                    install_date = addon.get("installDate") or 0
    except (OSError, ValueError):
        pass
    section = store.setdefault("commands", {})
    for name, shortcut in commands.items():
        entry = section.setdefault(name, {"precedenceList": []})
        plist = entry.setdefault("precedenceList", [])
        item = next((i for i in plist if i.get("id") == ext_id), None)
        if item is None:
            item = {"id": ext_id, "installDate": install_date, "value": {}, "enabled": True}
            plist.append(item)
        value = dict(item.get("value") or {})
        value["shortcut"] = "" if shortcut is None else re.sub(r"\s+", "", shortcut)
        item["value"] = value
        item["enabled"] = True
        plist.sort(key=lambda i: -(i.get("installDate") or 0))
    if json.dumps(store, sort_keys=True) != before:
        write_atomic(path, json.dumps(store))
        log(f"{ext_id}: keyboard shortcuts updated")


def apply_profile(profile, bundles, log):
    profile = os.path.abspath(profile)
    pid = profile_lock_owner(profile)
    if pid is not None:
        print(
            f"firefox-webext: warning: {profile} is in use by Firefox (pid {pid}); "
            "extension state will be applied the next time Firefox starts",
            file=sys.stderr,
        )
        return False
    os.makedirs(profile, exist_ok=True)
    refresh_rebuilt_xpis(profile, log)
    prefs = Prefs(profile)
    uuids_raw = prefs.get(UUIDS_PREF)
    uuids = json.loads(uuids_raw) if uuids_raw else {}
    uuids_before = dict(uuids)
    for bundle in bundles:
        if bundle.get("version") != BUNDLE_VERSION:
            sys.exit(f"firefox-webext: unsupported bundle version {bundle.get('version')}")
        for ext_id, ext in bundle["extensions"].items():
            if ext.get("uuid") and uuids.get(ext_id) != ext["uuid"]:
                if ext_id in uuids:
                    log(
                        f"{ext_id}: re-pinning UUID {uuids[ext_id]} -> {ext['uuid']}; "
                        "storage.local kept under the old UUID is no longer used"
                    )
                uuids[ext_id] = ext["uuid"]
            local = ext["local"]
            if local["force"] or local["defaults"] or local["resetUndeclared"]:
                if ext_id not in uuids:
                    # Pre-assign the UUID so the IndexedDB origin is known from now on.
                    uuids[ext_id] = str(uuidlib.uuid4())
                path = idb_path(profile, uuids[ext_id])
                if not (os.path.exists(path) and apply_local_idb(path, ext_id, local, log)):
                    apply_local_json(profile, prefs, ext_id, local, log)
            apply_sync(profile, ext_id, ext["sync"], log)
            apply_commands(profile, ext_id, ext.get("commands", {}), log)
    if uuids != uuids_before:
        prefs.set(UUIDS_PREF, json.dumps(uuids, separators=(",", ":")))
    prefs.save()
    return True


def cmd_apply(args):
    log = Log(args.quiet)
    jobs = []
    if args.manifest:
        with open(args.manifest) as f:
            for entry in json.load(f):
                jobs.append((os.path.expanduser(entry["profile"]), entry["bundles"]))
    if args.profile:
        jobs.append((args.profile, args.bundle))
    ok = True
    for profile, paths in jobs:
        bundles = []
        for p in paths:
            with open(p) as f:
                bundles.append(json.load(f))
        ok = apply_profile(profile, bundles, log) and ok
    if args.strict and not ok:
        sys.exit(2)


# --- dump ----------------------------------------------------------------------


def dump_idb(path):
    import snappy

    out = {}
    db = open_idb(path, readonly=True)
    try:
        row = db.execute("SELECT id FROM object_store WHERE name = ?", (IDB_OBJECT_STORE,)).fetchone()
        if row is None:
            return out
        for key, data, file_ids in db.execute(
            "SELECT key, data, file_ids FROM object_data WHERE object_store_id = ?", (row[0],)
        ):
            k = decode_key(bytes(key))
            if file_ids:
                out[k] = {"$external": file_ids}
                continue
            try:
                out[k] = sc_decode(snappy.decompress(bytes(data)))
            except Exception as e:  # keep dumping the other keys
                out[k] = {"$error": str(e)}
    finally:
        db.close()
    return out


def cmd_dump(args):
    profile = os.path.abspath(args.profile)
    prefs = Prefs(profile)
    uuids = json.loads(prefs.get(UUIDS_PREF) or "{}")
    result = {}

    def want(ext_id):
        return not args.id or ext_id in args.id

    if args.area in ("local", "all"):
        for ext_id, ext_uuid in uuids.items():
            if not want(ext_id):
                continue
            path = idb_path(profile, ext_uuid)
            if os.path.exists(path):
                data = dump_idb(path)
                if data:
                    result.setdefault(ext_id, {})["local"] = data
            js = os.path.join(profile, "browser-extension-data", ext_id, "storage.js")
            if os.path.exists(js):
                with open(js) as f:
                    result.setdefault(ext_id, {})["storageJs"] = json.load(f)
    if args.area in ("sync", "all"):
        path = os.path.join(profile, "storage-sync-v2.sqlite")
        if os.path.exists(path):
            db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            for ext_id, data in db.execute("SELECT ext_id, data FROM storage_sync_data"):
                if data and want(ext_id):
                    result.setdefault(ext_id, {})["sync"] = json.loads(data)
            db.close()
    if not args.no_meta:
        for ext_id in result:
            result[ext_id]["uuid"] = uuids.get(ext_id)
    json.dump(result, sys.stdout, indent=2, sort_keys=True, ensure_ascii=False)
    print()


def main():
    p = argparse.ArgumentParser(prog="firefox-webext", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("encode", help="build a state bundle from a spec (build time)")
    e.add_argument("spec")
    e.add_argument("out")
    e.set_defaults(func=cmd_encode)

    a = sub.add_parser("apply", help="merge state bundles into closed profiles")
    a.add_argument("--manifest", help='JSON list of {"profile": dir, "bundles": [file]}')
    a.add_argument("--profile")
    a.add_argument("--bundle", action="append", default=[])
    a.add_argument("--quiet", action="store_true")
    a.add_argument("--strict", action="store_true", help="exit 2 if a profile was skipped")
    a.set_defaults(func=cmd_apply)

    d = sub.add_parser("dump", help="decode a profile's extension storage to JSON")
    d.add_argument("--profile", required=True)
    d.add_argument("--id", action="append", help="only this extension id (repeatable)")
    d.add_argument("--area", choices=["local", "sync", "all"], default="all")
    d.add_argument("--no-meta", action="store_true", help="omit uuid fields")
    d.set_defaults(func=cmd_dump)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
