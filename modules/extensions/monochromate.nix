# Monochromate (grayscale filter). All settings live in one storage object,
# `Monofilter`, with a schema version under `Monofilter$`.
{
  config,
  lib,
  addonLib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.addons.monochromate;
  addonId = "{cdf4f419-70fa-491b-abcb-14bc1ad3d36f}";
  time = types.strMatching "([01][0-9]|2[0-3]):[0-5][0-9]";
  sites =
    description:
    mkOption {
      type = types.listOf types.str;
      default = [ ];
      inherit description;
    };
in
{
  options.addons.monochromate =
    addonLib.mkCommonOptions {
      displayName = "Monochromate";
      packageAttr = "monochromate";
    }
    // {
      enabled = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the grayscale filter is on.";
      };

      intensity = mkOption {
        type = types.ints.between 0 100;
        default = 100;
        description = "Filter strength, in percent.";
      };

      mode = mkOption {
        type = types.enum [
          "blacklist"
          "whitelist"
        ];
        default = "blacklist";
        description = "Gray every site except `excludedSites` (blacklist), or only `includedSites` (whitelist).";
      };

      excludedSites = sites "Hostnames never grayed, in blacklist mode.";
      excludedUrlPatterns = sites "URL patterns never grayed, in blacklist mode.";
      includedSites = sites "Hostnames grayed, in whitelist mode.";
      includedUrlPatterns = sites "URL patterns grayed, in whitelist mode.";

      schedule = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Only gray between `start` and `end`.";
        };
        start = mkOption {
          type = time;
          default = "17:00";
          description = "When the schedule starts graying.";
        };
        end = mkOption {
          type = time;
          default = "09:00";
          description = "When the schedule stops.";
        };
      };

      keepMediaInColor = mkOption {
        type = types.bool;
        default = false;
        description = "Leave images and video in colour.";
      };
    };

  config = lib.mkIf cfg.enable {
    webext.extensions.${addonId} = {
      inherit (cfg) package privateBrowsing defaultArea;
      commands = cfg.shortcuts;
      storage.local.force = {
        Monofilter = {
          inherit (cfg) enabled intensity mode;
          blacklist = cfg.excludedSites;
          urlPatternBlacklist = cfg.excludedUrlPatterns;
          whitelist = cfg.includedSites;
          urlPatternWhitelist = cfg.includedUrlPatterns;
          schedule = cfg.schedule.enable;
          scheduleStart = cfg.schedule.start;
          scheduleEnd = cfg.schedule.end;
          mediaExceptionEnabled = cfg.keepMediaInColor;
          temporaryDisable = false;
          temporaryDisableUntil = null;
        };
        "Monofilter$" = {
          v = 4;
        };
      }
      // cfg.extraSettings;
      state = "declarative";
    };
  };
}
