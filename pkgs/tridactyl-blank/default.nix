# Tridactyl with its splash/changelog new tab page swapped for an empty page
# that looks like Firefox's own new tab. The page still loads content.js, so
# every Tridactyl bind works on it. (Firefox never runs extension content
# scripts on about:newtab or about:blank, which is why Tridactyl has to own the
# page at all.)
#
# Also: no tutorial tab on first install, and, with `browserShortcuts`, the
# Firefox-level shortcuts for `:bind --mode=browser` binds baked into the
# manifest instead of registered at runtime.
#
# The result is unsigned: it needs xpinstall.signatures.required = false
# (Developer Edition, Nightly or ESR). `passthru.stock` is the signed AMO
# build, laid out the same way.
{
  lib,
  fetchurl,
  runCommand,
  callPackage,
  patchXpi ? callPackage ../patch-xpi.nix { },
  xpi ? fetchurl {
    url = "https://addons.mozilla.org/firefox/downloads/file/5014416/tridactyl_vim-1.25.1.xpi";
    hash = "sha256-ciwsbfwD2A5I+utMMRPTMCA5QEg+P8/GwdQQ4cxYVj4=";
  },
  version ? "1.25.1",
  # Firefox's empty new tab background, light and dark. Matches about:home in
  # Firefox 159 (checked by test.nix).
  lightBackground ? "#f7f6fb",
  darkBackground ? "#131215",
  # Shortcuts in WebExtension commands syntax ("MacCtrl+Comma", "Alt+6") for
  # Tridactyl's command_1..command_20 slots, which back browser-mode binds.
  # null keeps the manifest's defaults.
  browserShortcuts ? null,
}:

let
  addonId = "tridactyl.vim@cmcaine.co.uk";
  firefoxAppId = "{ec8030f7-c20a-464f-9b0e-13a3a9e97384}";

  shortcutsJson = builtins.toFile "tridactyl-browser-shortcuts.json" (
    builtins.toJSON browserShortcuts
  );

  stock = runCommand "tridactyl-${version}" { passthru = { inherit addonId; }; } ''
    install -Dm644 ${xpi} "$out/share/mozilla/extensions/${firefoxAppId}/${addonId}.xpi"
  '';
in
assert lib.assertMsg (
  browserShortcuts == null || builtins.length browserShortcuts <= 20
) "tridactyl-blank: Tridactyl has 20 browser-mode command slots";

patchXpi {
  inherit version addonId;
  src = xpi;
  pname = "tridactyl-blank";

  # theme: read the active theme's new tab colours.
  manifest.permissions = [ "theme" ];

  postPatch = ''
    install -m644 ${./newtab.html} static/newtab.html
    install -m644 ${./blank.js} static/blank.js
    substitute ${./blank.css} static/css/blank.css \
      --subst-var-by LIGHT_BG ${lib.escapeShellArg lightBackground} \
      --subst-var-by DARK_BG ${lib.escapeShellArg darkBackground}

    # content.js retitles the page when it shows its tips; keep "New Tab".
    substituteInPlace content.js \
      --replace-fail '"Tridactyl Top Tips & New Tab Page"' '"New Tab"'

    # No tutorial tab on first install: a fresh profile opens to the blank page.
    substituteInPlace background.js \
      --replace-fail 'if (details.reason === "install")' 'if (false)'

    # The changelog/update-nag script only drove the old page.
    rm -f newtab.js newtab.js.map
  ''
  + lib.optionalString (browserShortcuts != null) ''
    jq --slurpfile keys ${shortcutsJson} '
      .commands |= with_entries(
        (.key | ltrimstr("command_") | tonumber - 1) as $i
        | .value |= (del(.suggested_key)
            + (if $i < ($keys[0] | length)
               then { suggested_key: { default: $keys[0][$i] } } else {} end)))
    ' manifest.json > manifest.json.new
    mv manifest.json.new manifest.json
  '';

  passthru = {
    inherit stock;
    takesBrowserShortcuts = true;
  };

  meta = {
    description = "Tridactyl with a blank, Firefox-styled new tab page";
    homepage = "https://tridactyl.xyz";
    license = lib.licenses.asl20;
  };
}
