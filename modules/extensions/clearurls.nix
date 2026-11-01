# ClearURLs. Its rule set, hash and counters are runtime state downloaded
# from `ruleUrl`; only the settings are written here. Defaults follow
# ClearURLs' storage.js.
{
  config,
  lib,
  addonLib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.addons.clearurls;
  addonId = "{74145f27-f039-47ce-a470-a662b129930a}";
  bool =
    default: description:
    mkOption {
      type = types.bool;
      inherit default description;
    };
in
{
  options.addons.clearurls =
    addonLib.mkCommonOptions {
      displayName = "ClearURLs";
      packageAttr = "clearurls";
    }
    // {
      enabled = bool true "The main on/off switch.";
      badge = bool true "Show the number of cleaned URLs on the toolbar icon.";
      badgeColor = mkOption {
        type = types.str;
        default = "#ffa500";
        description = "Badge colour.";
      };
      contextMenu = bool true "Add \"Copy clean link\" to the link context menu.";
      blockTrackingDomains = bool true "Block requests to known tracking domains outright, not just clean their parameters.";
      eTagFiltering = bool false "Strip ETag headers (stops ETag tracking, costs cache hits).";
      historyListener = bool true "Also clean URLs that pages change with the History API.";
      skipLocalhost = bool true "Leave localhost and private network addresses alone.";
      logging = bool false "Keep a log of cleaned URLs.";
      logLimit = mkOption {
        type = types.ints.unsigned;
        default = 100;
        description = "Maximum log entries.";
      };
      pingBlocking = bool true "Block hyperlink auditing pings.";
      pingRequestTypes = mkOption {
        type = types.listOf types.str;
        default = [
          "ping"
          "beacon"
        ];
        description = "Request types treated as pings.";
      };
      referralMarketing = bool false "Allow referral-marketing parameters (e.g. Amazon affiliate tags).";
      statistics = bool true "Count cleaned URLs.";
      ruleUrl = mkOption {
        type = types.str;
        default = "https://rules2.clearurls.xyz/data.minify.json";
        description = "Where the rule set is downloaded from.";
      };
      hashUrl = mkOption {
        type = types.str;
        default = "https://rules2.clearurls.xyz/rules.minify.hash";
        description = "Where the rule set's hash is downloaded from.";
      };
      requestTypes = mkOption {
        type = types.listOf types.str;
        default = [
          "font"
          "image"
          "imageset"
          "main_frame"
          "media"
          "object"
          "object_subrequest"
          "other"
          "script"
          "stylesheet"
          "sub_frame"
          "websocket"
          "xml_dtd"
          "xmlhttprequest"
          "xslt"
        ];
        description = "Request types ClearURLs inspects.";
      };
    };

  config = lib.mkIf cfg.enable {
    webext.extensions.${addonId} = {
      inherit (cfg) package privateBrowsing defaultArea;
      commands = cfg.shortcuts;
      storage.local.force = {
        globalStatus = cfg.enabled;
        badgedStatus = cfg.badge;
        badged_color = cfg.badgeColor;
        contextMenuEnabled = cfg.contextMenu;
        domainBlocking = cfg.blockTrackingDomains;
        inherit (cfg)
          eTagFiltering
          logLimit
          pingBlocking
          pingRequestTypes
          referralMarketing
          ;
        ruleURL = cfg.ruleUrl;
        hashURL = cfg.hashUrl;
        historyListenerEnabled = cfg.historyListener;
        localHostsSkipping = cfg.skipLocalhost;
        loggingStatus = cfg.logging;
        statisticsStatus = cfg.statistics;
        types = lib.concatStringsSep "," cfg.requestTypes;
      }
      // cfg.extraSettings;
      # The downloaded rules, their hash, the log and counters stay.
      state = "overlay";
    };
  };
}
