"""Codec tests: key encoding and structured clone round trips.

Set WEBEXT_SAMPLE_IDB to a copy of a real storage.local IndexedDB file to also
check that re-encoding Firefox's own rows reproduces them byte for byte.
"""

import os
import sqlite3
import sys

import snappy

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import firefox_webext as fw  # noqa: E402

for s in ["", "disabledFor", "héllo", "日本語", "😀x", "a" * 200, "㿿䂾\u007f\u0080"]:
    assert fw.decode_key(fw.encode_key(s)) == s, s

value = {
    "1": [1, 2.5, -3, None, True, {}, [], 2**40, -(2**31)],
    "k": "😀 unicode ü",
    "nested": {"a": {"b": [False, "x" * 9]}},
    "float": 0.1,
}
decoded = fw.sc_decode(fw.sc_encode(value))
assert decoded == value, decoded

# Known encoding from a real Firefox row (Dark Reader "displayedNews").
assert fw.sc_encode(["google-docs-bugs"]).hex() == (
    "03000000" "0000f1ff" "01000000" "0700ffff" "00000000" "0300ffff"
    "10000080" "0400ffff" "676f6f676c652d646f63732d62756773" "00000000" "1300ffff"
)

# LZ4 block (mozlz4): a match that overlaps its own output, long literal runs.
assert fw.lz4_block_decompress(bytes([0x35]) + b"abc" + bytes([3, 0]) + bytes([0x10]) + b"!", 13) == b"abcabcabcabc!"
for n in (0, 1, 14, 15, 16, 269, 270, 271, 5000):
    data = bytes(range(256)) * (n // 256 + 1)
    data = data[:n]
    assert fw.lz4_block_decompress(fw.lz4_block_literals(data), n) == data, n

# Shortcut validation follows ShortcutUtils.validate().
for ok in ["Alt+Shift+H", "Ctrl+Shift+A", "MacCtrl+Comma", "F5", "Shift+F13", "MediaPlayPause", "Alt + Up"]:
    assert fw.shortcut_error(ok) is None, ok
for bad in ["Shift+F", "H", "Hyper+H", "Ctrl+Command+A", "Alt+Shift+Ctrl+H", "Alt+>", "Alt+h"]:
    assert fw.shortcut_error(bad), bad

# Templates: ids from existing key names; explicit rows win.
existing = {fw.encode_key(k): b"" for k in ["user_a1_x", "user_b2_y", "global_z", "user_a1_z"]}
wanted = {"force": {fw.encode_key("user_a1_s"): b"explicit"}, "defaults": {}}
tpl = {"name": "t", "idsFromKeys": r"^user_([a-z0-9]+)_", "force": {"user_{id}_s": {"data": "VA=="}}, "defaults": {}}
fw.expand_templates([tpl], existing, wanted)
assert wanted["force"] == {fw.encode_key("user_a1_s"): b"explicit", fw.encode_key("user_b2_s"): b"T"}, wanted
wanted = {"force": {}, "defaults": {}}
fw.expand_templates([tpl], {fw.encode_key("global_z"): b""}, wanted)
assert wanted == {"force": {}, "defaults": {}}, "no ids, no rows"

sample = os.environ.get("WEBEXT_SAMPLE_IDB")
if sample:
    db = sqlite3.connect(f"file:{sample}?mode=ro", uri=True)
    rows = 0
    for k, d in db.execute("SELECT key, data FROM object_data"):
        k, raw = bytes(k), snappy.decompress(bytes(d))
        key = fw.decode_key(k)
        assert fw.encode_key(key) == k, key
        assert fw.sc_encode(fw.sc_decode(raw)) == raw, key
        rows += 1
    print(f"sample: {rows} rows re-encode byte for byte")
print("codec ok")
