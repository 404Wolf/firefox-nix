# Tridactyl, configured from Nix: `programs.firefox.profiles.<name>.addons.tridactyl`.
#
#   addons.tridactyl = {
#     enable = true;
#     settings = { smoothscroll = true; hintchars = "asdfghjkl"; };
#     binds.normal = { "<C-d>" = "scrollpage 0.5"; "<C-f>" = null; };
#     autocmds.DocStart."mail.google.com" = "mode ignore";
#     searchurls.nix = "https://search.nixos.org/packages?query=";
#   };
#
# Compiles to Tridactyl's own config object (`userconfig` in storage.local,
# where 1.25 keeps it; storage.sync is only touched by :push/:pull) and hands
# it to `webext.extensions."tridactyl.vim@cmcaine.co.uk"`, which writes it
# into the profile. The config is rewritten on every apply, so a runtime `:set`
# or `:bind` lasts until the next launch. Command history and other runtime
# keys survive (state "overlay").
#
# Settings are merged over Tridactyl's defaults the same way `:set` merges
# them: you only declare what you change, and `null` deletes a default (for
# example a bind or a search engine).
#
# By default the package is tridactyl-blank: the new tab page is empty and
# Firefox-styled, and with `homepage` the first window and new windows open on
# it too, so Firefox's own home page never shows and binds work from the first
# keypress. That build is unsigned, so this also sets
# xpinstall.signatures.required = false (honoured by Developer Edition,
# Nightly and ESR only).
#
# ~/.config/tridactyl/tridactylrc isn't written: it needs the native messenger
# and is re-sourced only on `:source`/startup, while this config is in place
# before Tridactyl starts.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    mkMerge
    mkDefault
    types
    mapAttrs
    mapAttrs'
    mapAttrsToList
    filterAttrs
    optionalAttrs
    ;

  hm = config;
  addonId = "tridactyl.vim@cmcaine.co.uk";
  jsonValue = (pkgs.formats.json { }).type;
  defaultPackage = pkgs.callPackage ../../pkgs/tridactyl-blank { };

  # Nix mode names -> Tridactyl config keys (src/lib/binding.ts).
  modeMaps = {
    normal = "nmaps";
    ignore = "ignoremaps";
    insert = "imaps";
    input = "inputmaps";
    ex = "exmaps";
    hint = "hintmaps";
    visual = "vmaps";
    browser = "browsermaps";
  };

  # Tridactyl's default browser-mode binds (config.ts, Linux).
  defaultBrowserBinds = {
    "<C-,>" = "escapehatch";
    "<C-6>" = "tab #";
  };

  # Bracket keys the way `:bind` stores them (keyseq.ts canonicaliseMapstr):
  # modifiers upper-case in A, C, M, S order, vim aliases expanded.
  keyAliases = {
    cr = "Enter";
    return = "Enter";
    enter = "Enter";
    esc = "Escape";
    space = "Space";
    bar = "|";
    del = "Delete";
    bs = "Backspace";
    lt = "<";
  };
  canonKey =
    mapstr:
    lib.concatStrings (
      map (
        part:
        if builtins.isList part then
          let
            prefix = builtins.elemAt part 0;
            mods = if prefix == null then "" else lib.toUpper (lib.replaceStrings [ "-" ] [ "" ] prefix);
            key = builtins.elemAt part 2;
            key' = keyAliases.${lib.toLower key} or key;
            mods' = lib.concatStrings (
              builtins.filter (m: lib.hasInfix m mods) [
                "A"
                "C"
                "M"
                "S"
              ]
            );
          in
          if mods' == "" then "<${key'}>" else "<${mods'}-${key'}>"
        else
          part
      ) (builtins.split "<(([ACMSacms]+-)*)([^<>]+)>" mapstr)
    );

  # A single-key mapstr in WebExtension commands syntax (keyseq.ts
  # minimalKeyToMozMap). MacCtrl is the real Ctrl key on every platform.
  commandKeys = {
    "," = "Comma";
    "." = "Period";
    Space = "Space";
    ArrowUp = "Up";
    ArrowDown = "Down";
    ArrowLeft = "Left";
    ArrowRight = "Right";
  };
  mozShortcut =
    mapstr:
    let
      m = builtins.match "<([ACMS]+)-(.+)>" mapstr;
      mods = if m == null then "" else builtins.elemAt m 0;
      key = if m == null then lib.removePrefix "<" (lib.removeSuffix ">" mapstr) else builtins.elemAt m 1;
      modNames = lib.concatMap (x: lib.optional (lib.hasInfix x.l mods) x.n) [
        {
          l = "A";
          n = "Alt";
        }
        {
          l = "C";
          n = "MacCtrl";
        }
        {
          l = "S";
          n = "Shift";
        }
        {
          l = "M";
          n = "Command";
        }
      ];
    in
    lib.concatStringsSep "+" (modNames ++ [ (commandKeys.${key} or (lib.toUpper key)) ]);

  # A stable UUID per profile, so the home page URL is known at build time
  # without every user of this module sharing one guessable UUID.
  derivedUuid =
    profilePath:
    let
      h = builtins.hashString "sha256" "${hm.home.homeDirectory}/${profilePath}/${addonId}";
      s = start: len: builtins.substring start len h;
    in
    "${s 0 8}-${s 8 4}-4${s 13 3}-a${s 17 3}-${s 20 12}";

  tridactylOptions =
    profile:
    { config, ... }:
    {
      options = {
        enable = mkEnableOption "Tridactyl, configured from Nix";

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          defaultText = lib.literalExpression "tridactyl-blank";
          description = ''
            The Tridactyl build to install. The default is tridactyl-blank (empty,
            Firefox-styled new tab page). For the signed upstream build use
            `pkgs.callPackage <this flake>/packages/tridactyl-blank { }).stock`, and
            set `homepage = false`.
          '';
        };

        uuid = mkOption {
          type = types.str;
          default = derivedUuid profile.path;
          defaultText = lib.literalExpression "derived from the home directory and profile path";
          description = ''
            moz-extension:// UUID for Tridactyl. Pinned so `homepage` can point at
            its new tab page. Web pages can probe it through Tridactyl's
            web-accessible resources, so the default is per-user rather than one
            shared constant.
          '';
        };

        homepage = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Open the first window and every new window on Tridactyl's new tab page,
            so Firefox's own home page never shows. Also turns off the first-run
            and what's-new pages.
          '';
        };

        newTabFocus = mkOption {
          type = types.enum [
            "page"
            "urlbar"
          ];
          default = "page";
          description = ''
            Where the keyboard goes on a new tab. `page`: straight to Tridactyl,
            so `o`, `t`, `:` work at once (tridactyl-blank only; the address bar
            stays empty either way). `urlbar`: Firefox's default, typing searches;
            Esc moves to the page.
          '';
        };

        privateBrowsing = mkOption {
          type = types.bool;
          default = true;
          description = "Run Tridactyl in private windows.";
        };

        settings = mkOption {
          type = types.attrsOf jsonValue;
          default = { };
          example = {
            smoothscroll = true;
            hintchars = "asdfghjkl";
            theme = "dark";
            scrollduration = 150;
          };
          description = ''
            Tridactyl settings (`:help set`). Top-level booleans become Tridactyl's
            "true"/"false" strings, so `smoothscroll = true` works; nested values
            are passed as is. `null` resets a setting to its default.
          '';
        };

        binds = mkOption {
          type = types.attrsOf (types.attrsOf (types.nullOr types.str));
          default = { };
          example = {
            normal = {
              "<C-d>" = "scrollpage 0.5";
              "<C-f>" = null;
            };
            ex."<C-j>" = "ex.next_completion";
            browser."<A-t>" = "tabopen";
          };
          description = ''
            Binds per mode: normal, insert, input, ignore, ex, hint, visual, browser
            (or any other `<mode>`, stored as `<mode>maps`). `null` unbinds a
            default. Keys use `:bind` syntax; modifier case and order and aliases
            like `<cr>` are normalised.

            Browser-mode binds work even where Tridactyl can't run (about: pages).
            They need Firefox shortcuts, which are baked into the package, so they
            require a package that takes `browserShortcuts` (tridactyl-blank does).
          '';
        };

        autocmds = mkOption {
          type = types.attrsOf (types.attrsOf (types.nullOr types.str));
          default = { };
          example = {
            DocStart."mail.google.com" = "mode ignore";
            TabEnter.".*" = "unfocus";
          };
          description = "Autocommands per event (`:help autocmd`), URL regex -> excmd.";
        };

        searchurls = mkOption {
          type = types.attrsOf (types.nullOr types.str);
          default = { };
          example = {
            nix = "https://search.nixos.org/packages?query=";
            bing = null;
          };
          description = "Search engines for `:open <keyword> <query>`. `null` removes a default.";
        };

        exaliases = mkOption {
          type = types.attrsOf (types.nullOr types.str);
          default = { };
          example.q = "tabclose";
          description = "Ex command aliases (`:help command`).";
        };

        autocontain = mkOption {
          type = types.attrsOf types.str;
          default = { };
          example."github\\.com" = "Work";
          description = "URL regex -> container name (`:help autocontain`).";
        };

        extraConfig = mkOption {
          type = types.attrsOf jsonValue;
          default = { };
          example.subconfigs."www.reddit.com".nmaps.j = "scrollline 5";
          description = "Raw Tridactyl config, merged last (for subconfigs, jsurls and the like).";
        };

        userconfig = mkOption {
          type = types.attrsOf jsonValue;
          readOnly = true;
          description = "The config object handed to Tridactyl.";
        };

        finalPackage = mkOption {
          type = types.package;
          readOnly = true;
          description = "`package` with the browser-mode shortcuts baked in.";
        };
      };

      config =
        let
          setting = v: if lib.isBool v then lib.boolToString v else v;
          maps = mapAttrs' (mode: binds: {
            name = modeMaps.${mode} or "${mode}maps";
            value = lib.mapAttrs' (k: v: {
              name = canonKey k;
              value = v;
            }) binds;
          }) config.binds;
          browserBinds = filterAttrs (_: v: v != null) (defaultBrowserBinds // (maps.browsermaps or { }));
          nonEmpty = name: v: optionalAttrs (v != { }) { ${name} = v; };
        in
        {
          userconfig = lib.recursiveUpdate (
            mapAttrs (_: setting) config.settings
            // maps
            // nonEmpty "autocmds" config.autocmds
            // nonEmpty "searchurls" config.searchurls
            // nonEmpty "exaliases" config.exaliases
            // nonEmpty "autocontain" config.autocontain
            // {
              # Without it Tridactyl runs its config migrations, one of which
              # replaces the whole config with storage.sync's.
              configversion = "2.0";
              # Read by tridactyl-blank's new tab page.
              newtabfocus = config.newTabFocus;
            }
          ) config.extraConfig;

          finalPackage =
            if config.binds ? browser && config.package.takesBrowserShortcuts or false then
              config.package.override {
                browserShortcuts = map mozShortcut (lib.attrNames browserBinds);
              }
            else
              config.package;
        };
    };

  profileModule =
    { config, ... }:
    let
      t = config.addons.tridactyl;
      newTabUrl = "moz-extension://${t.uuid}/static/newtab.html";
    in
    {
      options.addons.tridactyl = mkOption {
        type = types.submodule (tridactylOptions config);
        default = { };
        description = "Tridactyl, configured from Nix.";
      };

      config = mkIf t.enable {
        webext.extensions.${addonId} = {
          package = t.finalPackage;
          inherit (t) uuid privateBrowsing;
          state = mkDefault "overlay";
          storage.local.force.userconfig = t.userconfig;
        };

        settings = mkMerge [
          (mkIf (t.finalPackage.unsigned or false) {
            "xpinstall.signatures.required" = false;
          })
          (mkIf t.homepage {
            # The query string keeps Firefox from treating the page as the new
            # tab URL (which would focus the address bar); the address bar still
            # shows empty, since Firefox ignores the query for that.
            "browser.startup.homepage" = if t.newTabFocus == "page" then "${newTabUrl}?focus" else newTabUrl;
            "browser.startup.homepage_override.privateAllowed" = t.privateBrowsing;
            "browser.startup.page" = mkDefault 1;
            "browser.startup.homepage_override.mstone" = mkDefault "ignore";
            "startup.homepage_welcome_url" = mkDefault "";
            "startup.homepage_welcome_url.additional" = mkDefault "";
            "browser.aboutwelcome.enabled" = mkDefault false;
          })
        ];
      };
    };

  enabled = filterAttrs (_: p: p.addons.tridactyl.enable) config.programs.firefox.profiles;
in
{
  options.programs.firefox.profiles = mkOption {
    type = types.attrsOf (types.submodule profileModule);
  };

  config = mkIf (enabled != { }) {
    assertions = mapAttrsToList (name: p: {
      assertion = (p.addons.tridactyl.settings.newtab or "") == "";
      message = ''
        programs.firefox.profiles.${name}.addons.tridactyl.settings.newtab makes Tridactyl
        leave its new tab page for that URL, where binds may not work. Leave it unset.'';
    }) enabled;

    warnings =
      let
        pkg = config.programs.firefox.package;
        name = if pkg == null then "" else lib.getName pkg;
        honoursUnsigned = lib.any (s: lib.hasInfix s name) [
          "devedition"
          "nightly"
          "esr"
          "unbranded"
        ];
      in
      lib.optional
        (
          !honoursUnsigned
          && lib.any (p: p.addons.tridactyl.finalPackage.unsigned or false) (lib.attrValues enabled)
        )
        ''
          addons.tridactyl uses an unsigned build (tridactyl-blank), but ${name} looks like
          release Firefox, which ignores xpinstall.signatures.required and won't load it.
          Use firefox-devedition, firefox-esr or a nightly, or the signed `.stock` package.'';
  };
}
