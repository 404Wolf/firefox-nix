# Firefox Multi-Account Containers. The containers themselves are the
# profile's `containers` option; this adds the extension and its
# "always open this site in" assignments.
{
  config,
  lib,
  addonLib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.addons.multi-account-containers;
  addonId = "@testpilot-containers";

  # A stable id per container, in the UUID format the extension uses to
  # match containers across synced machines.
  stableUUID =
    name:
    let
      h = builtins.hashString "sha256" "multi-account-containers:${name}";
      s = start: len: builtins.substring start len h;
    in
    "${s 0 8}-${s 8 4}-4${s 13 3}-a${s 17 3}-${s 20 12}";

  containerUUID = name: cfg.containerUUIDs.${name} or (stableUUID name);
in
{
  options.addons.multi-account-containers =
    addonLib.mkCommonOptions {
      displayName = "Multi-Account Containers";
      packageAttr = "multi-account-containers";
    }
    // {
      siteAssignments = mkOption {
        type = types.attrsOf (
          types.coercedTo types.str (container: { inherit container; }) (
            types.submodule {
              options = {
                container = mkOption {
                  type = types.str;
                  description = "Name of the container (a key of the profile's `containers`).";
                };
                neverAsk = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Reopen in the container without asking first.";
                };
              };
            }
          )
        );
        default = { };
        example = {
          "login.example.edu" = {
            container = "School";
            neverAsk = true;
          };
          "news.example.com" = "Personal";
        };
        description = "Sites that always open in a container, by hostname.";
      };

      containerUUIDs = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          The extension's own id for each container, by container name. It
          generates a random one per container on first run; set these to the
          existing ids to keep assignments attached to them. Containers not
          listed get an id derived from their name.
        '';
      };

      sync = mkOption {
        type = types.bool;
        default = false;
        description = "Sync containers and assignments through Firefox Sync.";
      };

      skipOnboarding = mkOption {
        type = types.bool;
        default = true;
        description = "Mark the extension's onboarding panels as already seen.";
      };
    };

  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (site: a: {
      assertion = config.containers ? ${a.container};
      message = "addons.multi-account-containers.siteAssignments.\"${site}\": no container named `${a.container}` in this profile's `containers`.";
    }) cfg.siteAssignments;

    webext.extensions.${addonId} = {
      inherit (cfg) package privateBrowsing defaultArea;
      commands = cfg.shortcuts;
      storage.local.force =
        lib.mapAttrs' (
          site: a:
          lib.nameValuePair "siteContainerMap@@_${site}" {
            userContextId = toString config.containers.${a.container}.id;
            inherit (a) neverAsk;
            identityMacAddonUUID = containerUUID a.container;
          }
        ) cfg.siteAssignments
        // {
          syncEnabled = cfg.sync;
        }
        // lib.optionalAttrs cfg.skipOnboarding {
          # The last onboarding stage in 8.x.
          "onboarding-stage" = 8;
        }
        // cfg.extraSettings;
      # Hidden-tab state and container ids are runtime state.
      state = "overlay";
    };
  };
}
