# firefox-nix

A home-manager module that makes Firefox fully declarative, including the part
Nix usually can't reach: **the settings stored inside your extensions**.

- **Extension state**: declare `storage.local`, `storage.sync` and managed
  storage for any WebExtension. The values are encoded at build time, in the
  Nix sandbox, into the exact bytes Firefox itself writes (IndexedDB rows of
  snappy-compressed structured clones), then copied into the profile.
- **Typed extension modules**: readable options for uBlock Origin, Dark Reader,
  Tridactyl, Tree Style Tab, Bitwarden and more, written in each extension's
  own storage format.
- **Immutable Firefox**: lock every declared pref (about:preferences and
  about:config can't change it), block about:config, and refuse extensions
  installed by hand.
- **Chrome**: vertical tabs (native or Tree Style Tab), a toolbar that stays
  hidden until <kbd>Ctrl</kbd>+<kbd>L</kbd>, a declared toolbar layout, and a
  `declutter` switch for Firefox's promos and AI extras.
- **Tridactyl with a blank new tab**: a repack whose new-tab page looks
  exactly like Firefox's own blank page, while Tridactyl's keys keep working on
  it, including in the very first window.

Every part has an end-to-end check that runs headless Firefox inside the Nix
sandbox.

## Quickstart

```nix
# flake.nix
{
  inputs.firefox-nix.url = "github:404Wolf/firefox-nix";
  # ...
  outputs = { home-manager, firefox-nix, ... }: {
    homeConfigurations.me = home-manager.lib.homeManagerConfiguration {
      # ...
      modules = [ firefox-nix.homeModules.default ./home.nix ];
    };
  };
}
```

```nix
# home.nix
{ pkgs, ... }:
{
  programs.firefox = {
    enable = true;
    package = pkgs.firefox-devedition; # unsigned repacks need signatures off; see Caveats
    immutable.enable = true;           # lock prefs, block about:config, lock extensions
    declutter.enable = true;

    profiles.default = {
      settings."browser.startup.page" = 3;

      addons = {
        ublock-origin = {
          enable = true;
          filterLists = [ "user-filters" "ublock-filters" "easylist" ];
          userFilters = ''
            example.com##.cookie-banner
          '';
        };

        darkreader = {
          enable = true;
          theme = { brightness = 110; contrast = 120; };
          disabledFor = [ "localhost" ];
        };

        tridactyl = {
          enable = true;
          settings.hintchars = "asdfghjkl";
          binds.normal."<C-f>" = null;          # unbind a default
          binds.normal.J = "tabprev";
          searchurls.nix = "https://search.nixos.org/packages?query=%s";
        };

        bitwarden = {
          enable = true;
          allAccounts.vaultTimeout = 15;         # applied to every logged-in account
        };
      };

      verticalTabs = { enable = true; provider = "native"; };
      chrome.autoHideToolbar.enable = true;

      # Any extension, typed module or not:
      webext.extensions."some-addon@example.org" = {
        package = pkgs.some-addon;
        state = "declarative";                   # drop every key not declared below
        storage.local.force = { theme = "dark"; };
        storage.sync.defaults = { firstRun = false; };
        commands._execute_browser_action = "Alt+Shift+S";
      };
    };
  };
}
```

## How it works

### Layers

```
build time   your options ─► firefox-webext encode ─► state bundle (store path)
activation   firefox-webext apply: merge each bundle into its profile
launch       the same apply runs from the Firefox wrapper before exec
```

The encode step is pure: it runs in the sandbox and produces the IndexedDB
rows, the `storage.sync` JSON, and a `storage.js` fallback. Applying is only a
byte copy, done by a stdlib-only Python script. Apply never writes a profile
whose lock is held by a running Firefox. If you switch while Firefox is open,
the change lands the next time Firefox starts, through its wrapper.

### Per-key semantics

| | |
|---|---|
| `force` | Rewritten on every apply. Nix wins. |
| `defaults` | Written only if the key is absent. Seed once, then the extension owns it. |
| `templates` | Keys containing an id the extension creates at runtime, e.g. `user_{id}_vaultTimeout`. Ids are captured from existing key names at apply time, so they never appear in your config. |
| `state = "overlay"` | Undeclared keys (logins, caches) survive under your declared ones. The default. |
| `state = "declarative"` | Undeclared keys are deleted on every apply. For config-only extensions. |

Also per extension: `package`, `uuid` (a stable `moz-extension://` URL),
`privateBrowsing` and `defaultArea` (set by policy), and `commands` (keyboard
shortcuts, written where about:addons' "Manage Extension Shortcuts" puts them).

### Where each area goes

- **`storage.local`** lives in IndexedDB at
  `storage/default/moz-extension+++<uuid>^userContextId=4294967295/idb/*.sqlite`.
  Each value is a SpiderMonkey structured clone compressed with snappy, and
  each key uses Firefox's IndexedDB key encoding. The encoder reproduces
  Firefox's own rows byte for byte, which a codec test checks. Rows are upserted
  directly, with a no-op stand-in for Gecko's `update_refcount()` trigger
  function.
- **An extension that has never run** has no database yet. Its values are
  staged in `browser-extension-data/<id>/storage.js`, which Firefox imports into
  IndexedDB on first start.
- **`storage.sync`** is JSON rows in `storage-sync-v2.sqlite`.
- **Managed storage** comes from enterprise policy,
  `3rdparty.Extensions.<id>`.

Apply also notices rebuilt extensions. Store files all have mtime 1 and the
link in `<profile>/extensions` keeps its path, so Firefox would keep its stale
add-on database entry. When a link's target changes, apply resets the recorded
mtime so Firefox reloads the add-on.

### Immutability

`programs.firefox.immutable`:

- **`lockPrefs`** locks every `profiles.<name>.settings` pref with autoconfig
  `lockPref()`. The `Preferences` policy can only lock an allowlist of pref
  branches, so it isn't used. Use `extraLockedPrefs` for prefs outside a
  profile.
- **`blockAboutConfig`** sets policy `BlockAboutConfig`.
- **`lockExtensions`** (per profile, on by default with `immutable.enable`)
  sets policy `ExtensionSettings` so `"*"` is blocked and only declared
  extensions may run. Extensions installed by hand are uninstalled.

Autoconfig and policies apply to the whole installation. Locked prefs are
merged across profiles, and a pref with conflicting values in two profiles is
an evaluation error.

Resetting undeclared prefs in `prefs.js` on every launch is deliberately not
offered. Firefox keeps runtime state there, such as migration versions, Sync
identity, push IDs, plugin versions and first-run markers. Wiping it re-runs
migrations on every start and breaks Sync. Declare and lock the prefs you care
about instead.

## Typed extension modules

`programs.firefox.profiles.<name>.addons.<addon>`. Each takes `enable`,
`package`, `privateBrowsing`, `defaultArea` and `shortcuts`, plus its own
options. Defaults are the extension's own defaults. `package` defaults to the
matching attribute of rycee's firefox-addons (`pkgs.firefox-addons` or NUR)
when one is available.

| Addon | Highlights |
|---|---|
| `ublock-origin` | filter lists, user filters, trusted sites, user/advanced settings (via uBlock's managed `toOverwrite`) |
| `darkreader` | every setting and theme field, site lists, per-site themes, automation |
| `tridactyl` | settings, per-mode binds (`null` unbinds), autocmds, search URLs, aliases, blank new tab |
| `tree-style-tab` | managed settings, shortcuts |
| `videospeed` | key bindings, speeds, site blacklist |
| `multi-account-containers` | site → container assignments, sync |
| `bitwarden` | global settings, never-save domains, per-account settings for every account (`allAccounts`) |
| `clearurls`, `i-dont-care-about-cookies`, `monochromate`, `react-devtools`, `user-agent-switcher`, `absolute-enable-right-click` | their settings |
| `onepassword`, `bypass-paywalls-clean`, `browser-zoom`, `vt-companion`, `solid-devtools`, `vicinae` | package only |

Anything else can use `webext.extensions.<id>` directly.

## Tridactyl with a blank new tab

Firefox doesn't run extension content scripts on `about:newtab` or
`about:home`. That's why Tridactyl replaces the new-tab page: its keys only
work on pages it owns. `pkgs.tridactyl-blank` repacks the AMO release so that:

- the page is empty and matches Firefox's own background pixel for pixel, in
  light and dark;
- `browser.startup.homepage` points at it, so the first window gets it too,
  with an empty URL bar;
- new tabs focus the page rather than the URL bar (`newTabFocus = "urlbar"`
  restores Firefox's behaviour);
- the first-install tutorial tab is gone.

`pkgs.patchXpi` (also `lib.patchXpi`) is the generic repacker it's built on.

## Chrome

- **`verticalTabs`**: `provider = "native" | "treestyletab"`, `position`,
  `visibility`, `sidebarTools`. It hides the horizontal tab strip.
- **`chrome.autoHideToolbar`**: the navigation toolbox collapses to nothing and
  slides in over the page while the URL bar has focus
  (<kbd>Ctrl</kbd>+<kbd>L</kbd>, <kbd>Alt</kbd>+<kbd>D</kbd>, <kbd>F6</kbd>) or
  any of its panels is open.
- **`toolbar`**: a declared nav-bar and bookmarks-bar layout.
- **`programs.firefox.declutter`**: New Tab weather, stories and sponsored
  items, Firefox Suggest, the AI chatbot and link previews, recommendations,
  promos and onboarding, all off. Translations stay available.

## Caveats

- **Firefox must be closed to apply.** Otherwise the change lands at the next
  launch through the wrapper.
- **Firefox Sync** can pull older `storage.sync` data down from the server.
  Prefer `storage.local`, or turn off the extension's own sync.
- **Unsigned repacks** (`tridactyl-blank`, your own forks) need
  `xpinstall.signatures.required = false`, which only Developer Edition,
  Nightly, ESR and unbranded builds honour. The Tridactyl module sets it.
- **Value size:** a single value of 1 MB or more after compression fails at
  build time. Firefox would store it outside the database.
- `lockExtensions` uninstalls anything you didn't declare, so declare
  everything you use before turning it on.

## Testing

```sh
nix flake check          # codec, formatting, and on x86_64-linux:
nix build .#checks.x86_64-linux.e2e              # storage/locking end to end
nix build .#checks.x86_64-linux.tridactyl-blank  # blank new tab end to end
```

The end-to-end checks evaluate the module through home-manager, then drive
headless Firefox Developer Edition over Marionette inside the sandbox. They
cover:

- fresh, overlay and declarative launches;
- every value type, unicode keys, templates and shortcuts;
- rebuilt extensions;
- locked prefs, a blocked about:config and a hand-installed extension that
  never runs;
- for Tridactyl, the first window, <kbd>Ctrl</kbd>+<kbd>T</kbd> focus, binds
  and background colours.

## License

MIT
