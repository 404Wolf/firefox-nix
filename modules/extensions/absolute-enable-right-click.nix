# Absolute Enable Right Click & Copy. It keeps nothing in extension storage,
# so there is nothing to configure beyond installing it.
{
  config,
  lib,
  addonLib,
  ...
}:
let
  cfg = config.addons.absolute-enable-right-click;
  addonId = "{9350bc42-47fb-4598-ae0f-825e3dd9ceba}";
in
{
  options.addons.absolute-enable-right-click = addonLib.mkCommonOptions {
    displayName = "Absolute Enable Right Click & Copy";
    packageAttr = "absolute-enable-right-click";
  };

  config = lib.mkIf cfg.enable {
    webext.extensions.${addonId} = {
      inherit (cfg) package privateBrowsing defaultArea;
      commands = cfg.shortcuts;
      storage.local.force = cfg.extraSettings;
      state = "declarative";
    };
  };
}
