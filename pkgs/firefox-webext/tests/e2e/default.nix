# End-to-end check: evaluate the home-manager module with a test extension,
# then drive headless Firefox through three launches (fresh profile, overlay,
# declarative) and assert what the extension actually sees.
{
  pkgs,
  homeManagerConfiguration,
  module,
}:
let
  inherit (pkgs) lib;
  spec = lib.importJSON ./spec.json;
  # The module bakes absolute profile paths into the launcher, so the test
  # home has to be where the sandbox builds: Nix's default build dir.
  home = "/build/home";
  profilePath = ".mozilla/firefox/test";

  mkXpi =
    id: version:
    let
      manifest = pkgs.writeText "manifest.json" (
        builtins.toJSON {
          manifest_version = 2;
          name = id;
          inherit version;
          browser_specific_settings.gecko.id = id;
          background.scripts = [ "background.js" ];
          commands = lib.mapAttrs (_: key: {
            suggested_key.default = key;
            description = "test command";
          }) spec.manifestCommands;
          permissions = [
            "storage"
            "http://127.0.0.1/*"
          ];
        }
      );
    in
    pkgs.runCommand "xpi-${id}-${version}"
      {
        nativeBuildInputs = [ pkgs.zip ];
        passthru.addonId = id;
      }
      ''
        mkdir src
        cp ${manifest} src/manifest.json
        cp ${./test-extension/background.js} src/background.js
        dst="$out/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
        mkdir -p "$dst"
        (cd src && zip -qr "$dst/${id}.xpi" .)
      '';

  testExtension = mkXpi spec.testId "1.0";
  # Same path in the profile, new store path: a rebuilt extension.
  testExtensionV2 = mkXpi spec.testId "2.0";
  intruder = mkXpi spec.intruderId "1.0";
  xpi = pkg: id: "${pkg}/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/${id}.xpi";

  mkHome =
    state:
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
                ${spec.lockedPref} = spec.lockedValue;
                "xpinstall.signatures.required" = false;
                "extensions.autoDisableScopes" = 0;
                "browser.shell.checkDefaultBrowser" = false;
                "browser.aboutwelcome.enabled" = false;
                "datareporting.policy.dataSubmissionEnabled" = false;
                "browser.startup.homepage_override.mstone" = "ignore";
              };
              webext.extensions.${spec.testId} = {
                package = testExtension;
                inherit (spec) uuid;
                inherit state;
                privateBrowsing = true;
                inherit (spec) commands;
                storage = {
                  local.force = spec.localForce;
                  local.defaults = spec.localDefaults;
                  local.templates = spec.localTemplates;
                  sync.force = spec.syncForce;
                  sync.defaults = spec.syncDefaults;
                  managed = spec.managed;
                };
              };
            };
          };
        }
      ];
    }).config;

  overlay = mkHome "overlay";
  declarative = mkHome "declarative";
  file = name: overlay.home.file.${name}.source;
  launcher = cfg: "${cfg.programs.firefox.immutable.finalPackage}/bin/firefox-devedition";
in
pkgs.runCommand "firefox-webext-e2e"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    SPEC = ./spec.json;
    PROFILE = "${home}/${profilePath}";
    LAUNCHER_OVERLAY = launcher overlay;
    LAUNCHER_DECLARATIVE = launcher declarative;
    # home-manager's Firefox without the pre-launch apply: shows the bug.
    FIREFOX_PLAIN = "${declarative.programs.firefox.finalPackage}/bin/firefox-devedition";
    XPI_V2 = xpi testExtensionV2 spec.testId;
    FIREFOX_WEBEXT = "${overlay.programs.firefox.webext.package}/bin/firefox-webext";
    MANIFEST = overlay.programs.firefox.webext.manifest;
    MANIFEST_DECLARATIVE = declarative.programs.firefox.webext.manifest;
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  }
  ''
    if [ "$NIX_BUILD_TOP" != /build ]; then
      echo "this check expects the sandbox build directory /build (got $NIX_BUILD_TOP)" >&2
      exit 1
    fi
    export HOME=${home}
    mkdir -p "$PROFILE/extensions"
    cp ${file ".mozilla/firefox/profiles.ini"} "$HOME/.mozilla/firefox/profiles.ini"
    cp ${file "${profilePath}/user.js"} "$PROFILE/user.js"
    cp -rL ${file "${profilePath}/extensions"}/. "$PROFILE/extensions/"
    # Like home-manager: the XPI is a symlink into the store (mtime 1).
    ln -sf ${xpi testExtension spec.testId} "$PROFILE/extensions/${spec.testId}.xpi"
    # Installed behind Nix's back: lockExtensions must keep it from running.
    cp ${intruder}/share/mozilla/extensions/*/${spec.intruderId}.xpi "$PROFILE/extensions/"
    chmod -R u+w "$HOME"
    cd "$NIX_BUILD_TOP"
    set -o pipefail
    python3 ${./harness.py} 2>&1 | tee $out
  ''
