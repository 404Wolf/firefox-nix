# uBlock Origin, configured through its admin (managed storage) settings.
# uBO applies `toOverwrite` on every launch, so these win over anything
# changed in its dashboard. Its filter-list caches stay in storage.local
# untouched. See https://github.com/gorhill/uBlock/wiki/Deploying-uBlock-Origin
{
  config,
  lib,
  addonLib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.addons.ublock-origin;
  addonId = "uBlock0@raymondhill.net";
  str = v: if builtins.isBool v then lib.boolToString v else toString v;
in
{
  options.addons.ublock-origin =
    addonLib.mkCommonOptions {
      displayName = "uBlock Origin";
      packageAttr = "ublock-origin";
    }
    // {
      filterLists = mkOption {
        type = types.listOf types.str;
        default = [
          "user-filters"
          "ublock-filters"
          "ublock-badware"
          "ublock-privacy"
          "ublock-quick-fixes"
          "ublock-unbreak"
          "easylist"
          "easyprivacy"
          "urlhaus-1"
          "plowe-0"
        ];
        description = ''
          Enabled filter lists: tokens from uBO's assets.json (as shown in the
          dashboard's URLs), or URLs of external lists.
        '';
      };

      userFilters = mkOption {
        type = types.lines;
        default = "";
        example = ''
          ! hide the cookie banner
          example.com##.cookie-banner
        '';
        description = "Your own filters (the \"My filters\" pane), one per line.";
      };

      trustedSites = mkOption {
        type = types.listOf types.str;
        default = [
          "chrome-extension-scheme"
          "moz-extension-scheme"
        ];
        description = ''
          Trusted-site directives (the "Trusted sites" pane): uBO is disabled on
          these. Hostnames, URL patterns, or uBO's special scheme tokens.
        '';
      };

      userSettings = mkOption {
        type = types.attrsOf (
          types.oneOf [
            types.bool
            types.int
            types.str
          ]
        );
        default = { };
        example = {
          advancedUserEnabled = true;
          cloudStorageEnabled = false;
        };
        description = "Settings-pane values, by uBO's internal name.";
      };

      advancedSettings = mkOption {
        type = types.attrsOf (
          types.oneOf [
            types.bool
            types.int
            types.str
          ]
        );
        default = { };
        example = {
          autoUpdatePeriod = 4;
        };
        description = "Advanced settings (about:advanced-settings in uBO), by name.";
      };
    };

  config = lib.mkIf cfg.enable {
    webext.extensions.${addonId} = {
      inherit (cfg) package privateBrowsing defaultArea;
      commands = cfg.shortcuts;
      storage.managed = {
        toOverwrite = {
          inherit (cfg) filterLists;
          filters = lib.filter (l: l != "") (lib.splitString "\n" cfg.userFilters);
          trustedSiteDirectives = cfg.trustedSites;
        };
      }
      // lib.optionalAttrs (cfg.userSettings != { }) {
        userSettings = lib.mapAttrsToList (n: v: [
          n
          (str v)
        ]) cfg.userSettings;
      }
      // lib.optionalAttrs (cfg.advancedSettings != { }) {
        advancedSettings = lib.mapAttrsToList (n: v: [
          n
          (str v)
        ]) cfg.advancedSettings;
      };
      storage.local.force = cfg.extraSettings;
      # Filter-list caches and the compiled engine live in storage.local.
      state = "overlay";
    };
  };
}
