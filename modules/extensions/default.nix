# Typed per-extension options: programs.firefox.profiles.<name>.addons.<addon>.
#
# Each addon module turns a handful of readable options into the extension's
# own storage layout and hands it to the generic layer at
# programs.firefox.profiles.<name>.webext.extensions.<addonId>, which installs
# the package and writes the storage. Defaults are the extension's own
# defaults, so enabling an addon without setting anything leaves it as it
# ships. Extensions without a module here can use webext.extensions directly.
{ lib, pkgs, ... }:
let
  addonLib = import ./lib.nix { inherit lib pkgs; };
in
{
  # Tridactyl's module is a whole home-manager module (it reads options
  # outside the profile), so it's imported here, not into the submodule.
  imports = [ ./tridactyl.nix ];

  options.programs.firefox.profiles = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        imports = [
          ./ublock-origin.nix
          ./darkreader.nix
          ./tree-style-tab.nix
          ./videospeed.nix
          ./multi-account-containers.nix
          ./bitwarden.nix
          ./clearurls.nix
          ./i-dont-care-about-cookies.nix
          ./monochromate.nix
          ./absolute-enable-right-click.nix
          ./react-devtools.nix
          ./user-agent-switcher.nix
          ./simple.nix
        ];
        config._module.args = { inherit addonLib; };
      }
    );
  };
}
