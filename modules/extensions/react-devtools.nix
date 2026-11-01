# React Developer Tools. The Components panel's settings live in
# storage.local; defaults are React DevTools' own.
{
  config,
  lib,
  addonLib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.addons.react-devtools;
  addonId = "@react-devtools";
  bool =
    default: description:
    mkOption {
      type = types.bool;
      inherit default description;
    };
in
{
  options.addons.react-devtools =
    addonLib.mkCommonOptions {
      displayName = "React Developer Tools";
      packageAttr = "react-devtools";
    }
    // {
      appendComponentStack = bool true "Append the component stack to console warnings and errors.";
      breakOnConsoleErrors = bool false "Pause the debugger on console errors.";
      hideConsoleLogsInStrictMode = bool false "Hide the second log of Strict Mode's double render.";
      showInlineWarningsAndErrors = bool true "Show warning and error counts in the component tree.";
    };

  config = lib.mkIf cfg.enable {
    webext.extensions.${addonId} = {
      inherit (cfg) package privateBrowsing defaultArea;
      commands = cfg.shortcuts;
      storage.local.force = {
        inherit (cfg)
          appendComponentStack
          breakOnConsoleErrors
          hideConsoleLogsInStrictMode
          showInlineWarningsAndErrors
          ;
      }
      // cfg.extraSettings;
      state = "declarative";
    };
  };
}
