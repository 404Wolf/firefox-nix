# I don't care about cookies. Its only setting is the list of sites it
# leaves alone.
{
  config,
  lib,
  addonLib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.addons.i-dont-care-about-cookies;
  addonId = "jid1-KKzOGWgsW3Ao4Q@jetpack";
in
{
  options.addons.i-dont-care-about-cookies =
    addonLib.mkCommonOptions {
      displayName = "I don't care about cookies";
      packageAttr = "i-dont-care-about-cookies";
    }
    // {
      allowedSites = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "meet.google.com" ];
        description = ''
          Hostnames where cookie banners are left alone (the popup's "Report a
          problem / disable on this site" list), for sites the blocking breaks.
        '';
      };
    };

  config = lib.mkIf cfg.enable {
    webext.extensions.${addonId} = {
      inherit (cfg) package privateBrowsing defaultArea;
      commands = cfg.shortcuts;
      storage.local.force = {
        whitelisted_domains = lib.genAttrs cfg.allowedSites (_: true);
      }
      // cfg.extraSettings;
      state = "declarative";
    };
  };
}
