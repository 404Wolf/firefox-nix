# Bitwarden. Only settings are configurable here; accounts, vaults, keys and
# tokens are runtime state and never touched (state = "overlay").
#
# Bitwarden stores each setting as `global_<state>_<key>`, or for
# per-account settings `user_<account id>_<state>_<key>`, with the value as a
# JSON string under `{ "__json__": true, "value": ... }`. Names and defaults
# follow its KeyDefinition/UserKeyDefinition declarations. `allAccounts` reaches
# every account through a webext storage template (ids taken from the
# `user_<id>_` keys at apply time), so account ids stay out of the config.
{
  config,
  lib,
  addonLib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.addons.bitwarden;
  addonId = "{446900e4-71c2-419f-a6a7-df9c091e268b}";
  url = types.nullOr types.str;
  # Bitwarden account (user) ids.
  uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";

  bwJson = value: {
    __json__ = true;
    value = builtins.toJSON value;
  };

  bool =
    default: description:
    mkOption {
      type = types.bool;
      inherit default description;
    };

  regions = {
    US = null;
    EU = {
      api = "https://api.bitwarden.eu";
      identity = "https://identity.bitwarden.eu";
      webVault = "https://vault.bitwarden.eu";
      icons = "https://icons.bitwarden.eu";
      notifications = "https://notifications.bitwarden.eu";
      events = "https://events.bitwarden.eu";
    };
  };

  environment =
    if cfg.selfHosted != null then
      lib.filterAttrs (_: v: v != null) cfg.selfHosted
    else
      regions.${cfg.region};

  inlineMenu = {
    off = 0;
    onFieldFocus = 1;
    onButtonClick = 2;
  };

  uriMatch = {
    domain = 0;
    host = 1;
    startsWith = 2;
    exact = 3;
    regularExpression = 4;
    never = 5;
  };

  global = {
    theming_selection = cfg.theme;
    autofillSettingsLocal_inlineMenuVisibility = inlineMenu.${cfg.inlineMenu};
    autofillSettings_enableContextMenu = cfg.contextMenu;
    domainSettings_showFavicons = cfg.showFavicons;
    domainSettings_neverDomains = lib.genAttrs cfg.neverSaveDomains (_: null);
    userNotificationSettings_enableAddedLoginPrompt = cfg.askToAddLogins;
    userNotificationSettings_enableChangedPasswordPrompt = cfg.askToUpdatePasswords;
  };

  perAccount = a: {
    vaultTimeoutSettings_vaultTimeout = a.vaultTimeout;
    vaultTimeoutSettings_vaultTimeoutAction = a.vaultTimeoutAction;
    autofillSettings_autofillOnPageLoad = a.autofillOnPageLoad;
    autofillSettings_autoCopyTotp = a.autoCopyTotp;
    autofillSettings_showInlineMenuCards = a.showCardsInInlineMenu;
    autofillSettings_showInlineMenuIdentities = a.showIdentitiesInInlineMenu;
    autofillSettingsLocal_clearClipboardDelay = a.clearClipboard;
    badgeSettings_enableBadgeCounter = a.badgeCounter;
    domainSettings_defaultUriMatchStrategy = uriMatch.${a.defaultUriMatch};
  };

  accountType = types.submodule {
    options = {
      vaultTimeout = mkOption {
        type = types.either types.ints.unsigned (
          types.enum [
            "never"
            "onRestart"
            "onLocked"
            "onSleep"
            "onIdle"
          ]
        );
        default = "onRestart";
        description = "When the vault times out: minutes, or an event.";
      };
      vaultTimeoutAction = mkOption {
        type = types.enum [
          "lock"
          "logOut"
        ];
        default = "lock";
        description = "What happens when it times out.";
      };
      autofillOnPageLoad = bool false "Fill a matching login as soon as a page loads.";
      autoCopyTotp = bool true "Copy the TOTP code after filling a login.";
      showCardsInInlineMenu = bool true "Offer cards in the inline menu.";
      showIdentitiesInInlineMenu = bool true "Offer identities in the inline menu.";
      clearClipboard = mkOption {
        type = types.enum [
          "never"
          "tenSeconds"
          "twentySeconds"
          "thirtySeconds"
          "oneMinute"
          "twoMinutes"
          "fiveMinutes"
        ];
        default = "fiveMinutes";
        description = "Clear copied values from the clipboard after this long.";
      };
      badgeCounter = bool true "Show the number of matching logins on the toolbar icon.";
      defaultUriMatch = mkOption {
        type = types.enum (lib.attrNames uriMatch);
        default = "domain";
        description = "How login URIs match pages by default.";
      };
    };
  };
in
{
  options.addons.bitwarden =
    addonLib.mkCommonOptions {
      displayName = "Bitwarden";
      packageAttr = "bitwarden";
    }
    // {
      region = mkOption {
        type = types.enum (lib.attrNames regions);
        default = "US";
        description = "Which Bitwarden cloud to use (ignored when `selfHosted` is set).";
      };

      selfHosted = mkOption {
        type = types.nullOr (
          types.submodule {
            options =
              lib.genAttrs
                [
                  "base"
                  "webVault"
                  "api"
                  "identity"
                  "icons"
                  "notifications"
                  "events"
                ]
                (
                  n:
                  mkOption {
                    type = url;
                    default = null;
                    description = "The server's ${n} URL${
                      lib.optionalString (n == "base") "; the others default to paths under it"
                    }.";
                  }
                );
          }
        );
        default = null;
        example = {
          base = "https://vault.example.com";
        };
        description = "A self-hosted server instead of Bitwarden's cloud, applied through managed storage.";
      };

      theme = mkOption {
        type = types.enum [
          "system"
          "light"
          "dark"
        ];
        default = "system";
        description = "The popup's theme.";
      };

      inlineMenu = mkOption {
        type = types.enum (lib.attrNames inlineMenu);
        default = "off";
        description = "When the autofill menu appears inside login fields.";
      };

      contextMenu = bool true "Add Bitwarden to the page context menu.";
      showFavicons = bool true "Show website icons in the vault.";
      askToAddLogins = bool true "Offer to save new logins.";
      askToUpdatePasswords = bool true "Offer to update a login when its password changes.";

      neverSaveDomains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "accounts.google.com" ];
        description = "Domains where Bitwarden never offers to save a login.";
      };

      allAccounts = mkOption {
        type = types.nullOr accountType;
        default = null;
        example = {
          vaultTimeout = 15;
          clearClipboard = "thirtySeconds";
        };
        description = ''
          Per-account settings for every account logged in to Bitwarden.
          Bitwarden keeps these per account; the accounts are found in its
          storage each time the profile is written, so no account id goes in
          your config. An account you log in to gets them from the next start.
          `null` leaves them alone.
        '';
      };

      accounts = mkOption {
        type = types.attrsOf accountType;
        default = { };
        example = lib.literalExpression ''{ "<account user id>".vaultTimeout = 15; }'';
        description = ''
          Per-account settings for specific accounts, by Bitwarden account (user)
          id: the uuid in the `user_<id>_...` keys of its storage. These win over
          `allAccounts` for that account. Prefer `allAccounts` if your config is
          public.
        '';
      };
    };

  config = lib.mkIf cfg.enable {
    webext.extensions.${addonId} = {
      inherit (cfg) package privateBrowsing defaultArea;
      commands = cfg.shortcuts;
      storage.managed = lib.optionalAttrs (environment != null) { inherit environment; };
      storage.local.force =
        lib.mapAttrs' (k: v: lib.nameValuePair "global_${k}" (bwJson v)) global
        // lib.concatMapAttrs (
          id: a: lib.mapAttrs' (k: v: lib.nameValuePair "user_${id}_${k}" (bwJson v)) (perAccount a)
        ) cfg.accounts
        // cfg.extraSettings;
      storage.local.templates = lib.optionalAttrs (cfg.allAccounts != null) {
        accounts = {
          idsFromKeys = "^user_(${uuid})_";
          force = lib.mapAttrs' (k: v: lib.nameValuePair "user_{id}_${k}" (bwJson v)) (
            perAccount cfg.allAccounts
          );
        };
      };
      state = "overlay";
    };
  };
}
