# Shared pieces for the addon modules.
{ lib, pkgs }:
let
  inherit (lib) mkOption types;
in
import ../util.nix { inherit lib; }
// rec {
  json = (pkgs.formats.json { }).type;

  # The package from rycee's firefox-addons set (the flake overlay as
  # `pkgs.firefox-addons`, or NUR), so `enable = true` works without a pin.
  upstreamPackage =
    attr:
    pkgs.firefox-addons.${attr} or pkgs.nur.repos.rycee.firefox-addons.${attr}
      or (throw "No firefox-addons package `${attr}` in pkgs; set the addon's `package` option.");

  # Options every addon module has.
  mkCommonOptions =
    {
      displayName,
      packageAttr,
    }:
    {
      enable = lib.mkEnableOption displayName;

      package = mkOption {
        type = types.package;
        default = upstreamPackage packageAttr;
        defaultText = lib.literalExpression "pkgs.firefox-addons.${packageAttr}";
        description = "The ${displayName} extension package.";
      };

      privateBrowsing = mkOption {
        type = types.bool;
        default = false;
        description = "Whether ${displayName} also runs in private windows.";
      };

      defaultArea = mkOption {
        type = types.nullOr (
          types.enum [
            "navbar"
            "menupanel"
          ]
        );
        default = null;
        description = ''
          Where ${displayName}'s toolbar button goes when installed: the nav bar,
          or the extensions menu. Null leaves it to the extension. (A declared
          `toolbar` layout overrides this.)
        '';
      };

      shortcuts = mkOption {
        type = types.attrsOf (types.nullOr types.str);
        default = { };
        example = {
          _execute_browser_action = "Alt+Shift+U";
        };
        description = ''
          Keyboard shortcuts for ${displayName}'s commands, by command name (as
          listed in about:addons → Manage Extension Shortcuts, or the `commands`
          of its manifest). `null` removes a shortcut. Unlisted commands keep
          their defaults.
        '';
      };

      extraSettings = mkOption {
        type = types.attrsOf json;
        default = { };
        description = ''
          Raw storage keys for ${displayName}, written on top of the ones the
          typed options produce. An escape hatch for settings without an option.
        '';
      };
    };
}
