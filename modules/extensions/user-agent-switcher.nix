# User-Agent Switcher (ntninja). The list of user agents (`available`) and
# the one currently picked (`current`) stay runtime state; the behaviour
# settings are typed. Defaults are the extension's own.
{
  config,
  lib,
  addonLib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.addons.user-agent-switcher;
  addonId = "user-agent-switcher@ninetailed.ninja";
in
{
  options.addons.user-agent-switcher =
    addonLib.mkCommonOptions {
      displayName = "User-Agent Switcher";
      packageAttr = "user-agent-string-switcher";
    }
    // {
      random = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Switch to a random user agent periodically.";
        };
        categories = mkOption {
          type = types.listOf types.str;
          default = [ "Desktop" ];
          description = "Categories of the list to pick random user agents from.";
        };
        interval = {
          mode = mkOption {
            type = types.enum [
              "startup"
              "timed"
            ];
            default = "startup";
            description = "Pick a new one at every browser start (`startup`), or every `value` `unit`s (`timed`).";
          };
          value = mkOption {
            type = types.ints.positive;
            default = 1;
            description = "Interval length.";
          };
          unit = mkOption {
            type = types.enum [
              "m"
              "h"
              "d"
            ];
            default = "h";
            description = "Interval unit: minutes, hours or days.";
          };
        };
        jitter = mkOption {
          type = types.ints.between 0 100;
          default = 20;
          description = "Random variation of the interval, in percent.";
        };
      };

      showBadgeText = mkOption {
        type = types.bool;
        default = true;
        description = "Show the active user agent's short name on the toolbar icon.";
      };

      editMode = mkOption {
        type = types.enum [
          "table"
          "text"
        ];
        default = "table";
        description = "How the list is edited in the options page.";
      };
    };

  config = lib.mkIf cfg.enable {
    webext.extensions.${addonId} = {
      inherit (cfg) package privateBrowsing defaultArea;
      commands = cfg.shortcuts;
      storage.local.force = {
        "random-enabled" = cfg.random.enable;
        "random-categories" = cfg.random.categories;
        "random-interval" = { inherit (cfg.random.interval) mode value unit; };
        "random-jitter" = cfg.random.jitter;
        "show-badge-text" = cfg.showBadgeText;
        "edit-mode" = cfg.editMode;
      }
      // cfg.extraSettings;
      state = "overlay";
    };
  };
}
