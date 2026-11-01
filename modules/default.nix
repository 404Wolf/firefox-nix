# firefox-webext: declarative WebExtension state and an immutable Firefox,
# as a home-manager module extending `programs.firefox`.
#
# Extension state (`programs.firefox.profiles.<name>.webext.extensions.<id>`)
#
#   storage.local    Firefox keeps it in IndexedDB, as snappy-compressed
#                    SpiderMonkey structured clones. A build-time derivation
#                    encodes your values into exactly those bytes (the "state
#                    bundle"), so nothing but byte copies happens on your machine.
#   storage.sync     JSON rows in storage-sync-v2.sqlite.
#   storage.managed  Enterprise policy (`3rdparty.Extensions.<id>`).
#
#   Every key is either `force` (rewritten on every apply: Nix wins) or
#   `defaults` (written once, then the extension owns it). `resetUndeclared`
#   deletes every key you didn't declare. `state = "declarative"` turns that on
#   for config-only extensions. `state = "overlay"` leaves runtime state such as
#   logins in place, layered under your keys.
#
#   storage.local.templates set keys that contain an id the extension makes at
#   runtime (accounts, say): `user_{id}_setting`, applied to every id captured
#   from the existing key names when the profile is written. The ids never have
#   to appear in your config.
#
#   Also: `commands` (keyboard shortcuts, in extension-settings.json), `uuid`
#   (stable moz-extension:// URLs), `privateBrowsing` and `defaultArea` (by
#   policy), `package` (installed into the profile).
#
# How it lands
#
#   build time   spec -> firefox-webext encode -> bundle (store path)
#   activation   firefox-webext apply: merge bundles into each closed profile
#   launch       the same apply runs from the Firefox wrapper before exec, so a
#                switch made while Firefox was open lands at its next start
#
#   apply never writes a profile whose lock is held by a live Firefox. An
#   extension that has never run has no IndexedDB yet; its values are staged in
#   browser-extension-data/<id>/storage.js, which Firefox imports on first
#   start (this needs extensions.webextensions.keepStorageOnUninstall, set by
#   default whenever `webext.extensions` is used).
#
#   apply also notices rebuilt extensions. Store files all have mtime 1 and the
#   link in <profile>/extensions keeps its path, so Firefox would keep the old
#   add-on database entry (old version, no upgrade). When a link's store target
#   changes, apply zeroes the recorded mtimes so Firefox reloads it.
#
# Immutability (`programs.firefox.immutable`)
#
#   lockPrefs         every `profiles.<name>.settings` pref is locked with
#                     autoconfig lockPref(): about:preferences and about:config
#                     can't change it. (The `Preferences` policy can only lock
#                     an allowlist of pref branches, so it isn't used.)
#   blockAboutConfig  policy BlockAboutConfig.
#   lockExtensions    (per profile) policy ExtensionSettings: "*" is blocked,
#                     declared extensions are allowed. Extensions installed by
#                     hand are uninstalled.
#
#   Autoconfig and policies apply to the whole installation, not one profile.
#   Locked prefs are therefore merged across profiles (a pref with different
#   values in two profiles is an error), and lockExtensions allows the union of
#   every profile's extensions.
#
#   Not provided: resetting undeclared prefs in prefs.js on every launch.
#   Firefox keeps runtime state there (UI migration version, add-on database
#   schema, Sync client identity, push IDs, GMP plugin versions, update and
#   first-run markers). Resetting it re-runs browser migrations on every start,
#   re-registers the Sync client, and re-downloads DRM plugins, and an allowlist
#   breaks again with each Firefox release. Declare and lock the prefs you
#   care about instead.
#
# The Firefox on PATH is `programs.firefox.immutable.finalPackage`: home-manager's
# `finalPackage` with the locked prefs and the pre-launch apply added.
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
    types
    mapAttrs
    mapAttrsToList
    filterAttrs
    attrValues
    concatMap
    concatStrings
    optionalAttrs
    ;

  cfg = config.programs.firefox;
  jsonValue = (pkgs.formats.json { }).type;
  firefoxWebext = pkgs.callPackage ../pkgs/firefox-webext { };

  profileDir = profile: "${config.home.homeDirectory}/${cfg.profilesPath}/${profile.path}";

  storageAreaOptions = area: {
    force = mkOption {
      type = types.attrsOf jsonValue;
      default = { };
      description = "storage.${area} keys rewritten on every apply: Nix always wins.";
    };
    defaults = mkOption {
      type = types.attrsOf jsonValue;
      default = { };
      description = "storage.${area} keys written only when absent, so changes made in the extension stick.";
    };
  };

  extensionModule =
    profileCfg:
    { name, config, ... }:
    {
      options = {
        package = mkOption {
          type = types.nullOr types.package;
          default = null;
          description = "Extension package to install into the profile (added to `extensions.packages`).";
        };
        uuid = mkOption {
          type = types.nullOr (
            types.strMatching "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
          );
          default = null;
          example = "5f0c6f63-5c4b-4f63-9a4e-2b1d3c4e5f60";
          description = ''
            Pin the extension's moz-extension:// UUID, so its pages have a stable
            URL (for example to use one as the home page). `null` keeps the UUID
            Firefox assigned. Changing it orphans storage.local kept under the old UUID.
          '';
        };
        privateBrowsing = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = "Allow (or forbid) the extension in private windows. Enforced by policy.";
        };
        defaultArea = mkOption {
          type = types.nullOr (
            types.enum [
              "navbar"
              "menupanel"
            ]
          );
          default = null;
          description = "Where the toolbar button goes on first install. Enforced by policy.";
        };
        commands = mkOption {
          type = types.attrsOf (types.nullOr types.str);
          default = { };
          example = {
            _execute_browser_action = "Alt+Shift+B";
            some_command = null;
          };
          description = ''
            Keyboard shortcuts for the extension's commands (the names in its
            manifest's `commands`), like about:addons → Manage Extension Shortcuts.
            `null` removes the shortcut. Rewritten on every apply; commands you
            don't list keep their default or whatever was set in the browser.
            Validated at build time with Firefox's rules: one or two of Alt, Ctrl,
            Command, MacCtrl, Shift plus A-Z, 0-9, F1-F19, Comma, Period, Space,
            Home, End, PageUp, PageDown, Insert, Delete or an arrow.
          '';
        };
        state = mkOption {
          type = types.enum [
            "overlay"
            "declarative"
          ];
          default = profileCfg.webext.defaultState;
          defaultText = lib.literalExpression "webext.defaultState";
          description = ''
            `declarative`: keys you didn't declare are deleted on every apply, so the
            extension's storage is exactly what Nix says. Use for config-only extensions.

            `overlay`: Nix keys are layered over runtime state, which survives. Use for
            extensions holding logins or other state you create in the browser
            (password managers, container assignments).
          '';
        };
        storage = {
          local = storageAreaOptions "local" // {
            templates = mkOption {
              type = types.attrsOf (
                types.submodule {
                  options = {
                    idsFromKeys = mkOption {
                      type = types.str;
                      example = "^user_([0-9a-f-]{36})_";
                      description = ''
                        A regular expression (Python syntax) with one capture group,
                        matched against the extension's existing storage.local key
                        names when the profile is written. Every distinct capture is
                        an id the template is applied to.
                      '';
                    };
                    force = mkOption {
                      type = types.attrsOf jsonValue;
                      default = { };
                      example = {
                        "user_{id}_vaultTimeoutSettings_vaultTimeout" = "onRestart";
                      };
                      description = "Keys containing `{id}`, rewritten for every id on every apply.";
                    };
                    defaults = mkOption {
                      type = types.attrsOf jsonValue;
                      default = { };
                      description = "Keys containing `{id}`, written for an id only when absent.";
                    };
                  };
                }
              );
              default = { };
              description = ''
                Settings for things the extension creates at runtime and keys by an
                id you don't want in your config, such as accounts. The ids are found
                in the live storage each time the profile is written, so a template
                reaches an account from the next start after you log in to it.
                Keys declared in `force`/`defaults` win over template keys.
              '';
            };
          };
          sync = storageAreaOptions "sync";
          managed = mkOption {
            type = types.attrsOf jsonValue;
            default = { };
            description = "storage.managed values, delivered by enterprise policy (read-only for the extension).";
          };
          resetUndeclared = {
            local = mkOption {
              type = types.bool;
              default = config.state == "declarative";
              defaultText = lib.literalExpression ''state == "declarative"'';
              description = "Delete storage.local keys that aren't declared.";
            };
            sync = mkOption {
              type = types.bool;
              default = config.state == "declarative";
              defaultText = lib.literalExpression ''state == "declarative"'';
              description = "Delete storage.sync keys that aren't declared.";
            };
          };
        };
      };
    };

  profileModule =
    { config, name, ... }:
    let
      webext = config.webext;
      spec = {
        extensions = mapAttrs (_: ext: {
          inherit (ext) uuid commands;
          local = {
            inherit (ext.storage.local) force defaults templates;
            resetUndeclared = ext.storage.resetUndeclared.local;
          };
          sync = {
            inherit (ext.storage.sync) force defaults;
            resetUndeclared = ext.storage.resetUndeclared.sync;
          };
        }) webext.extensions;
      };
    in
    {
      options.webext = {
        lockExtensions = mkOption {
          type = types.bool;
          default = cfg.immutable.enable;
          defaultText = lib.literalExpression "programs.firefox.immutable.enable";
          description = ''
            Block every extension that isn't declared, here or in `extensions.packages`.
            Extensions can't be added, removed or disabled by hand. Enforced by
            policy, which applies to the whole installation.
          '';
        };
        defaultState = mkOption {
          type = types.enum [
            "overlay"
            "declarative"
          ];
          default = "overlay";
          description = "Default `state` for this profile's extensions.";
        };
        extensions = mkOption {
          type = types.attrsOf (types.submodule (extensionModule config));
          default = { };
          description = "Per-extension state, keyed by add-on ID.";
        };
        bundle = mkOption {
          type = types.package;
          readOnly = true;
          internal = true;
          description = "Encoded state bundle for this profile.";
        };
      };

      config = {
        # Firefox marks a freshly installed extension as already migrated to
        # IndexedDB, which skips the storage.js import that seeds
        # never-started extensions, unless storage survives uninstall. Keeping
        # storage and UUIDs across uninstall also suits Nix: dropping an
        # extension from the config and adding it back loses nothing.
        settings = mkIf (webext.extensions != { }) {
          "extensions.webextensions.keepStorageOnUninstall" = lib.mkDefault true;
          "extensions.webextensions.keepUuidOnUninstall" = lib.mkDefault true;
        };
        extensions.packages = concatMap (ext: lib.optional (ext.package != null) ext.package) (
          attrValues webext.extensions
        );
        webext.bundle =
          pkgs.runCommand "firefox-webext-bundle-${name}"
            {
              spec = builtins.toJSON spec;
              passAsFile = [ "spec" ];
            }
            ''
              ${firefoxWebext}/bin/firefox-webext encode "$specPath" $out
            '';
      };
    };

  profiles = attrValues cfg.profiles;
  # Profiles the applier visits: ones with extension state, and ones with Nix
  # extensions at all, so rebuilt XPIs are noticed (see firefox_webext.py).
  webextProfiles = builtins.filter (
    p: p.webext.extensions != { } || p.extensions.packages != [ ]
  ) profiles;

  manifest = pkgs.writeText "firefox-webext-manifest.json" (
    builtins.toJSON (
      map (p: {
        profile = profileDir p;
        bundles = [ "${p.webext.bundle}" ];
      }) webextProfiles
    )
  );

  # Same value encoding as home-manager's user.js.
  prefValue =
    v: builtins.toJSON (if lib.isBool v || lib.isInt v || lib.isString v then v else builtins.toJSON v);

  lockedPrefs =
    optionalAttrs cfg.immutable.lockPrefs (lib.foldl' (acc: p: acc // p.settings) { } profiles)
    // cfg.immutable.extraLockedPrefs;

  conflictingPrefs = lib.filter (
    pref:
    lib.length (
      lib.unique (map (p: p.settings.${pref}) (builtins.filter (p: p.settings ? ${pref}) profiles))
    ) > 1
  ) (lib.unique (concatMap (p: builtins.attrNames p.settings) profiles));

  lockedPrefsCfg = concatStrings (
    mapAttrsToList (n: v: "lockPref(${builtins.toJSON n}, ${prefValue v});\n") lockedPrefs
  );

  allowedIds = lib.unique (
    concatMap (
      p:
      builtins.attrNames p.webext.extensions
      ++ concatMap (pkg: lib.optional (pkg ? addonId) pkg.addonId) p.extensions.packages
    ) profiles
  );

  extensionPolicy = filterAttrs (_: v: v != { }) (
    lib.foldl' lib.recursiveUpdate { } (
      concatMap (
        p:
        mapAttrsToList (id: ext: {
          ${id} =
            optionalAttrs (ext.privateBrowsing != null) { private_browsing = ext.privateBrowsing; }
            // optionalAttrs (ext.defaultArea != null) { default_area = ext.defaultArea; };
        }) p.webext.extensions
      ) profiles
    )
  );

  lockExtensions = lib.any (p: p.webext.lockExtensions) profiles;

  managed = lib.foldl' (a: b: a // b) { } (
    concatMap (
      p:
      mapAttrsToList (
        id: ext: optionalAttrs (ext.storage.managed != { }) { ${id} = ext.storage.managed; }
      ) p.webext.extensions
    ) profiles
  );

  applyCmd = "${firefoxWebext}/bin/firefox-webext apply --manifest ${manifest}";

  needsLauncher = cfg.finalPackage != null && (lockedPrefs != { } || webextProfiles != [ ]);

  launcher = (
    (cfg.finalPackage.override (old: {
      extraPrefs = (old.extraPrefs or "") + lockedPrefsCfg;
    })).overrideAttrs
      (old: {
        makeWrapperArgs =
          (old.makeWrapperArgs or [ ])
          ++ lib.optionals (webextProfiles != [ ] && cfg.webext.applyOnLaunch) [
            "--run"
            "${applyCmd} --quiet || true"
          ];
      })
  );
in
{
  imports = [
    # Typed modules for individual extensions, built on `webext`.
    ./extensions
    # Vertical tabs, auto-hiding toolbox, toolbar layout, declutter.
    ./ui
  ];

  options.programs.firefox = {
    profiles = mkOption {
      type = types.attrsOf (types.submodule profileModule);
    };

    webext = {
      applyOnLaunch = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Apply extension state every time Firefox starts, not only on
          home-manager activation. Changes made while Firefox was open then land
          at its next start.
        '';
      };
      package = mkOption {
        type = types.package;
        default = firefoxWebext;
        readOnly = true;
        description = "The firefox-webext tool (encode / apply / dump).";
      };
      manifest = mkOption {
        type = types.package;
        default = manifest;
        readOnly = true;
        internal = true;
        description = "Profiles and state bundles that `firefox-webext apply --manifest` merges.";
      };
    };

    immutable = {
      enable = mkEnableOption ''
        a Nix-only Firefox: declared prefs are locked, about:config is blocked
        and only declared extensions can run'';
      lockPrefs = mkOption {
        type = types.bool;
        default = cfg.immutable.enable;
        defaultText = lib.literalExpression "programs.firefox.immutable.enable";
        description = ''
          Lock every pref declared in `profiles.<name>.settings` with autoconfig
          `lockPref`, so neither about:preferences nor about:config can change it.
          Autoconfig applies to the whole installation, so all profiles share one
          set of locked prefs.
        '';
      };
      extraLockedPrefs = mkOption {
        type = types.attrsOf jsonValue;
        default = { };
        description = "Prefs to lock for every profile, in addition to the profiles' settings.";
      };
      blockAboutConfig = mkOption {
        type = types.bool;
        default = cfg.immutable.enable;
        defaultText = lib.literalExpression "programs.firefox.immutable.enable";
        description = "Block about:config (policy `BlockAboutConfig`).";
      };
      finalPackage = mkOption {
        type = types.nullOr types.package;
        readOnly = true;
        default = if needsLauncher then launcher else cfg.finalPackage;
        defaultText = lib.literalExpression "programs.firefox.finalPackage with locked prefs and the pre-launch applier";
        description = "The Firefox package actually put on PATH. Reference this rather than `finalPackage`.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.immutable.lockPrefs || conflictingPrefs == [ ];
          message = ''
            programs.firefox.immutable.lockPrefs locks prefs for the whole installation,
            but these prefs have different values in different profiles:
            ${lib.concatStringsSep ", " conflictingPrefs}'';
        }
      ]
      ++ map (p: {
        assertion = p.webext.extensions == { } || p.extensions.settings == { };
        message = ''
          programs.firefox.profiles.${p.name}: `extensions.settings` turns off Firefox's
          IndexedDB storage backend, which `webext` writes to. Move those settings to
          `webext.extensions.<id>.storage.local`.'';
      }) profiles;
    }

    {
      programs.firefox.policies = {
        ExtensionSettings = mkIf (lockExtensions || extensionPolicy != { }) (mkMerge [
          (mkIf lockExtensions (
            {
              "*" = {
                installation_mode = "blocked";
                blocked_install_message = "Extensions are managed by Nix (home-manager).";
              };
            }
            // lib.genAttrs allowedIds (_: {
              installation_mode = "allowed";
            })
          ))
          extensionPolicy
        ]);
        BlockAboutConfig = mkIf cfg.immutable.blockAboutConfig true;
        "3rdparty" = mkIf (managed != { }) { Extensions = managed; };
      };
    }

    (mkIf needsLauncher {
      home.packages = [ (lib.hiPrio launcher) ];
    })

    (mkIf (webextProfiles != [ ]) {
      home.packages = [
        firefoxWebext
        (pkgs.writeShellScriptBin "firefox-webext-apply" ''exec ${applyCmd} "$@"'')
      ];
      home.activation.firefoxWebext = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        run ${applyCmd}
      '';
    })
  ]);
}
