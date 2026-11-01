# Browser-chrome options for each profile: vertical tabs, an auto-hiding
# toolbox and a declarative toolbar layout. Declutter is browser-wide and
# lives in ./declutter.nix.
{ lib, ... }:
{
  imports = [ ./declutter.nix ];

  options.programs.firefox.profiles = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        imports = [
          ./vertical-tabs.nix
          ./autohide-toolbox.nix
          ./toolbar.nix
        ];
      }
    );
  };
}
