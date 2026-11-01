# Tree Style Tab. Settings go through TST's managed storage, which it treats
# as administrator-locked: they apply on every start and are greyed out in
# its options page. Its own state (tree caches, sidebar widths, sync device
# ids) stays in storage.local.
{
  config,
  lib,
  addonLib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.addons.tree-style-tab;
  addonId = "treestyletab@piro.sakura.ne.jp";
in
{
  options.addons.tree-style-tab =
    addonLib.mkCommonOptions {
      displayName = "Tree Style Tab";
      packageAttr = "tree-style-tab";
    }
    // {
      settings = mkOption {
        type = types.attrsOf addonLib.json;
        default = { };
        example = {
          autoCollapseExpandSubtreeOnSelect = false;
          style = "proton";
        };
        description = ''
          TST settings by their internal name (the keys of `configs` in TST's
          common/common.js, also shown in its options page with "expert
          options" on). Anything not set keeps TST's default.
        '';
      };
    };

  config = lib.mkIf cfg.enable {
    webext.extensions.${addonId} = {
      inherit (cfg) package privateBrowsing defaultArea;
      commands = cfg.shortcuts;
      storage.managed = cfg.settings;
      storage.local.force = cfg.extraSettings;
      state = "overlay";
    };
  };
}
