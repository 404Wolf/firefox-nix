# End-to-end check of addons.tridactyl + tridactyl-blank: evaluate the
# home-manager module, then launch its Firefox headless in the sandbox (once
# light, once dark, each on a fresh profile) and drive it over Marionette.
{
  pkgs,
  homeManagerConfiguration,
  module,
}:
let
  # The webext module bakes absolute profile paths into the launcher, so the
  # test home has to be where the sandbox builds: Nix's default build dir.
  home = "/build/home";
  profilePath = ".mozilla/firefox/test";

  hmConfig =
    (homeManagerConfiguration {
      inherit pkgs;
      modules = [
        module
        {
          home.username = "test";
          home.homeDirectory = home;
          home.stateVersion = "25.05";
          programs.firefox = {
            enable = true;
            package = pkgs.firefox-devedition;
            configPath = ".mozilla/firefox";
            immutable.enable = true;
            profiles.test = {
              id = 0;
              isDefault = true;
              path = "test";
              settings = {
                "extensions.autoDisableScopes" = 0;
                "browser.shell.checkDefaultBrowser" = false;
                "datareporting.policy.dataSubmissionEnabled" = false;
              };
              addons.tridactyl = {
                enable = true;
                settings = {
                  hintchars = "qwer";
                  smoothscroll = true;
                };
                binds.normal = {
                  "Q" = "js document.title = 'bound by nix'";
                  "<c-f>" = null;
                };
                searchurls.nixtest = "https://example.invalid/?q=";
              };
            };
          };
        }
      ];
    }).config;

  ff = hmConfig.programs.firefox;
  tri = ff.profiles.test.addons.tridactyl;
  file = name: hmConfig.home.file.${name}.source;
in
pkgs.runCommand "tridactyl-blank-e2e"
  {
    nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.pillow ])) ];
    LAUNCHER = "${ff.immutable.finalPackage}/bin/firefox-devedition";
    PROFILE = "${home}/${profilePath}";
    PROFILES_INI = file ".mozilla/firefox/profiles.ini";
    USER_JS = file "${profilePath}/user.js";
    EXTENSIONS = file "${profilePath}/extensions";
    UUID = tri.uuid;
    USERCONFIG = builtins.toJSON tri.userconfig;
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  }
  ''
    if [ "$NIX_BUILD_TOP" != /build ]; then
      echo "this check expects the sandbox build directory /build (got $NIX_BUILD_TOP)" >&2
      exit 1
    fi
    export HOME=${home}
    mkdir -p "$out"
    cd "$NIX_BUILD_TOP"
    set -o pipefail
    python3 ${./harness.py} 2>&1 | tee "$out/log"
  ''
