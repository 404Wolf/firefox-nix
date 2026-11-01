# Video Speed Controller (codebicycle/videospeed 0.6.x). Settings live in
# storage.sync under the names its options page writes.
{
  config,
  lib,
  addonLib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.addons.videospeed;
  addonId = "{7be2ba16-0f1e-4d93-9ebc-5164397477a9}";

  bindingType = types.submodule {
    options = {
      key = mkOption {
        type = types.either types.str types.int;
        description = ''A key name ("V", "[", "F5", "Left") or a DOM key code.'';
      };
      value = mkOption {
        type = types.number;
        default = 0;
        description = "The action's amount: a speed step, seconds to skip, or the preferred speed.";
      };
      overrideSite = mkOption {
        type = types.bool;
        default = false;
        description = "Stop the page from also handling this key.";
      };
    };
  };

  actions = [
    "display"
    "slower"
    "faster"
    "rewind"
    "advance"
    "reset"
    "fast"
    "muted"
    "pause"
    "mark"
    "jump"
  ];

  # The bindings its options page always shows, and can rebind but not remove.
  predefined = [
    "display"
    "slower"
    "faster"
    "rewind"
    "advance"
    "reset"
    "fast"
  ];

  # In the extension's own order (predefined first), as its options page lists them.
  bindings = map (
    action:
    let
      b = cfg.keyBindings.${action};
    in
    {
      inherit action;
      inherit (b) value;
      key = addonLib.keyCode b.key;
      force = lib.boolToString b.overrideSite;
      predefined = lib.elem action predefined;
    }
  ) (lib.filter (a: cfg.keyBindings ? ${a}) actions);
in
{
  options.addons.videospeed =
    addonLib.mkCommonOptions {
      displayName = "Video Speed Controller";
      packageAttr = "videospeed";
    }
    // {
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Whether the controller is active.";
      };

      rememberSpeed = mkOption {
        type = types.bool;
        default = false;
        description = "Apply the last used speed to every video.";
      };

      forceLastSavedSpeed = mkOption {
        type = types.bool;
        default = false;
        description = "Fight sites that reset the playback speed.";
      };

      audio = mkOption {
        type = types.bool;
        default = false;
        description = "Also control audio elements.";
      };

      startHidden = mkOption {
        type = types.bool;
        default = false;
        description = "Hide the on-video controller until its display key is pressed.";
      };

      controllerOpacity = mkOption {
        type = types.str;
        default = "0.3";
        description = "Opacity of the on-video controller, 0 to 1.";
      };

      blacklist = mkOption {
        type = types.listOf types.str;
        default = [
          "www.instagram.com"
          "twitter.com"
          "vine.co"
          "imgur.com"
          "teams.microsoft.com"
        ];
        description = "Sites the controller never runs on (hostnames or /regex/ patterns).";
      };

      keyBindings = mkOption {
        type = types.attrsOf bindingType;
        default = {
          display.key = "V";
          slower = {
            key = "S";
            value = 0.1;
          };
          faster = {
            key = "D";
            value = 0.1;
          };
          rewind = {
            key = "Z";
            value = 10;
          };
          advance = {
            key = "X";
            value = 10;
          };
          reset = {
            key = "R";
            value = 1;
          };
          fast = {
            key = "G";
            value = 1.8;
          };
        };
        description = ''
          Key bindings by action (${lib.concatStringsSep ", " actions}). Setting
          this replaces the default set, so list every binding you want.
        '';
      };
    };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (a: lib.elem a actions) (lib.attrNames cfg.keyBindings);
        message = "addons.videospeed.keyBindings: actions must be among ${lib.concatStringsSep ", " actions}.";
      }
    ];

    webext.extensions.${addonId} = {
      inherit (cfg) package privateBrowsing defaultArea;
      commands = cfg.shortcuts;
      storage.sync.force = {
        # The settings schema version; older versions migrate on load.
        version = "0.5.3";
        inherit (cfg)
          enabled
          rememberSpeed
          forceLastSavedSpeed
          startHidden
          controllerOpacity
          ;
        audioBoolean = cfg.audio;
        keyBindings = bindings;
        displayKeyCode = addonLib.keyCode (cfg.keyBindings.display or { key = "V"; }).key;
        blacklist = lib.concatMapStrings (s: s + "\n") cfg.blacklist;
      }
      // cfg.extraSettings;
      # Only configuration lives here, plus the last speed used.
      state = "declarative";
    };
  };
}
