# Extensions with nothing worth typing: they either store nothing, or keep
# their settings in a form that can't be written without clobbering runtime
# data. Each still gets enable/package/privateBrowsing/defaultArea and the
# raw `extraSettings` escape hatch.
{
  config,
  lib,
  addonLib,
  ...
}:
let
  addons = {
    onepassword = {
      displayName = "1Password";
      addonId = "{d634138d-c276-4fc8-924b-40a0ea21d284}";
      packageAttr = "onepassword-password-manager";
      # Its settings are one JSON string (`config`) that also holds account
      # and vault ids; the rest of its storage is account state.
      state = "overlay";
    };
    bypass-paywalls-clean = {
      displayName = "Bypass Paywalls Clean";
      addonId = "magnolia@12.34";
      packageAttr = "bypass-paywalls-clean";
      # Its two options live inside `sites`, the map of enabled sites that it
      # rebuilds from its own site list, next to update-check state.
      state = "overlay";
    };
    browser-zoom = {
      displayName = "Browser Zoom";
      addonId = "{daef88de-f4dd-4359-997c-b0c1eee0e5bb}";
      packageAttr = "browser-zoom";
      state = "declarative";
    };
    vt-companion = {
      displayName = "Val Town companion";
      addonId = "std@val.town";
      packageAttr = "vt-companion";
      state = "declarative";
    };
    solid-devtools = {
      displayName = "Solid Devtools";
      addonId = "{abfd162e-9948-403a-a75c-6e61184e1d47}";
      packageAttr = "solid-devtools";
      state = "declarative";
    };
    vicinae = {
      displayName = "Vicinae";
      addonId = "firefox@vicinae.com";
      packageAttr = "vicinae";
      state = "declarative";
    };
  };
in
{
  options.addons = lib.mapAttrs (
    _: a:
    addonLib.mkCommonOptions {
      inherit (a) displayName packageAttr;
    }
  ) addons;

  config.webext.extensions = lib.mkMerge (
    lib.mapAttrsToList (
      name: a:
      let
        cfg = config.addons.${name};
      in
      lib.mkIf cfg.enable {
        ${a.addonId} = {
          inherit (cfg) package privateBrowsing defaultArea;
          commands = cfg.shortcuts;
          inherit (a) state;
          storage.local.force = cfg.extraSettings;
        };
      }
    ) addons
  );
}
