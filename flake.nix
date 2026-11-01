{
  description = "Declarative Firefox for home-manager: extension state written into the profile, typed extension settings, locked prefs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Only the checks use it, to evaluate the module through home-manager.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAll = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      homeModules.default = ./modules;
      homeManagerModules.default = self.homeModules.default;

      overlays.default = final: _prev: {
        firefox-webext = final.callPackage ./pkgs/firefox-webext { };
        patchXpi = final.callPackage ./pkgs/patch-xpi.nix { };
        tridactyl-blank = final.callPackage ./pkgs/tridactyl-blank { };
      };

      lib.patchXpi = pkgs: pkgs.callPackage ./pkgs/patch-xpi.nix { };

      packages = forAll (pkgs: rec {
        firefox-webext = pkgs.callPackage ./pkgs/firefox-webext { };
        tridactyl-blank = pkgs.callPackage ./pkgs/tridactyl-blank { };
        default = firefox-webext;
      });

      formatter = forAll (pkgs: pkgs.nixfmt-tree);

      checks = forAll (
        pkgs:
        {
          # The codec self-test runs while the package builds.
          codec = self.packages.${pkgs.stdenv.hostPlatform.system}.firefox-webext;
          formatting = pkgs.runCommand "firefox-nix-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            cd ${self}
            find . -name '*.nix' -print0 | xargs -0 nixfmt --check
            touch $out
          '';
        }
        # Headless Firefox in the sandbox.
        // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          e2e = pkgs.callPackage ./pkgs/firefox-webext/tests/e2e {
            inherit (home-manager.lib) homeManagerConfiguration;
            module = self.homeModules.default;
          };
          tridactyl-blank = pkgs.callPackage ./pkgs/tridactyl-blank/tests {
            inherit (home-manager.lib) homeManagerConfiguration;
            module = self.homeModules.default;
          };
        }
      );
    };
}
