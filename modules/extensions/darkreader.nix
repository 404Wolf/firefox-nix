# Dark Reader. Option names and defaults follow DEFAULT_SETTINGS and
# DEFAULT_THEME in Dark Reader 4.9.x (src/defaults.ts).
#
# Dark Reader reads its settings from storage.local when `syncSettings` is
# off and from storage.sync when it is on, so everything is written to the
# area it will actually read, and the other area is cleared.
{
  config,
  lib,
  addonLib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.addons.darkreader;
  addonId = "addon@darkreader.org";

  color = types.strMatching "#[0-9a-fA-F]{3,8}";
  percent = types.ints.between 0 200;

  themeOptions = {
    mode = mkOption {
      type = types.enum [
        "dark"
        "light"
      ];
      default = "dark";
      description = "Whether pages are made dark, or light.";
    };
    brightness = mkOption {
      type = percent;
      default = 100;
      description = "Brightness, in percent.";
    };
    contrast = mkOption {
      type = percent;
      default = 100;
      description = "Contrast, in percent.";
    };
    grayscale = mkOption {
      type = types.ints.between 0 100;
      default = 0;
      description = "Grayscale, in percent.";
    };
    sepia = mkOption {
      type = types.ints.between 0 100;
      default = 0;
      description = "Sepia, in percent.";
    };
    useFont = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to replace page fonts with `fontFamily`.";
    };
    fontFamily = mkOption {
      type = types.str;
      default = "Open Sans";
      description = "Font used when `useFont` is on.";
    };
    textStroke = mkOption {
      type = types.number;
      default = 0;
      description = "Text stroke width in pixels (0 to 1).";
    };
    engine = mkOption {
      type = types.enum [
        "dynamicTheme"
        "cssFilter"
        "svgFilter"
        "staticTheme"
      ];
      default = "dynamicTheme";
      description = ''
        How pages are themed: `dynamicTheme` rewrites colours (best quality),
        `cssFilter`/`svgFilter` invert the page with a filter (fast, works on
        anything), `staticTheme` applies a generated stylesheet.
      '';
    };
    stylesheet = mkOption {
      type = types.lines;
      default = "";
      description = "Extra CSS for the static theme engine.";
    };
    darkSchemeBackgroundColor = mkOption {
      type = color;
      default = "#181a1b";
      description = "Background colour in dark mode.";
    };
    darkSchemeTextColor = mkOption {
      type = color;
      default = "#e8e6e3";
      description = "Text colour in dark mode.";
    };
    lightSchemeBackgroundColor = mkOption {
      type = color;
      default = "#dcdad7";
      description = "Background colour in light mode.";
    };
    lightSchemeTextColor = mkOption {
      type = color;
      default = "#181a1b";
      description = "Text colour in light mode.";
    };
    scrollbarColor = mkOption {
      type = types.str;
      default = "";
      description = ''Scrollbar colour: a colour, "auto", or "" to leave scrollbars alone.'';
    };
    selectionColor = mkOption {
      type = types.str;
      default = "auto";
      description = ''Selection colour: a colour, "auto", or "" to leave it alone.'';
    };
    styleSystemControls = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to restyle native form controls (buttons, inputs).";
    };
    lightColorScheme = mkOption {
      type = types.str;
      default = "Default";
      description = "Named colour scheme for light mode.";
    };
    darkColorScheme = mkOption {
      type = types.str;
      default = "Default";
      description = "Named colour scheme for dark mode.";
    };
    immediateModify = mkOption {
      type = types.bool;
      default = false;
      description = "Modify page styles synchronously (faster first paint, can break pages).";
    };
  };

  themeType = types.submodule { options = themeOptions; };

  toTheme = t: (removeAttrs t [ "mode" ]) // { mode = if t.mode == "dark" then 1 else 0; };

  # The upstream theme defaults, which per-site overrides are relative to.
  defaultTheme = lib.mapAttrs (_: o: o.default) themeOptions;

  # Dark Reader's built-in per-site themes: Office and Google Docs editors
  # only work with a filter.
  builtInSiteThemes =
    map
      (url: {
        url = [ url ];
        theme = {
          engine = "cssFilter";
        };
        builtIn = true;
      })
      ([
        "*.officeapps.live.com"
        "*.sharepoint.com"
        "docs.google.com"
        "onedrive.live.com"
      ]);

  settings = {
    schemeVersion = 2;
    inherit (cfg)
      enabled
      fetchNews
      presets
      enabledByDefault
      enabledFor
      disabledFor
      changeBrowserTheme
      syncSettings
      syncSitesFixes
      previewNewDesign
      previewNewestDesign
      enableForPDF
      enableForProtectedPages
      enableContextMenus
      detectDarkTheme
      ;
    theme = toTheme cfg.theme;
    customThemes = map (t: {
      inherit (t) url builtIn;
      theme = toTheme (defaultTheme // t.theme);
    }) cfg.customThemes;
    automation = {
      inherit (cfg.automation) enabled behavior;
      mode = if cfg.automation.mode == null then "" else cfg.automation.mode;
    };
    time = { inherit (cfg.time) activation deactivation; };
    location = { inherit (cfg.location) latitude longitude; };
  }
  // cfg.extraSettings;
in
{
  options.addons.darkreader =
    addonLib.mkCommonOptions {
      displayName = "Dark Reader";
      packageAttr = "darkreader";
    }
    // {
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "The main on/off switch (the toggle at the top of the popup).";
      };

      theme = mkOption {
        type = themeType;
        default = { };
        description = "The theme applied to every site without a per-site theme.";
      };

      enabledByDefault = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether Dark Reader themes every site except `disabledFor` (true), or
          only the sites in `enabledFor` (false).
        '';
      };

      enabledFor = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "docs.rs" ];
        description = ''
          Sites to theme. When `enabledByDefault` is on, these are themed even
          if they already look dark (`detectDarkTheme`).
        '';
      };

      disabledFor = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "github.com"
          "localhost:3000"
        ];
        description = "Sites never themed (hostnames, optionally with a port, or wildcard patterns).";
      };

      customThemes = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              url = mkOption {
                type = types.listOf types.str;
                description = "Sites this theme applies to.";
              };
              theme = mkOption {
                type = types.attrsOf addonLib.json;
                default = { };
                example = {
                  engine = "cssFilter";
                  brightness = 90;
                };
                description = ''
                  Theme values for these sites, on top of Dark Reader's default
                  theme (not `theme` above), as in Dark Reader's own per-site themes.
                '';
              };
              builtIn = mkOption {
                type = types.bool;
                default = false;
                description = "Marks one of Dark Reader's shipped per-site themes.";
              };
            };
          }
        );
        default = builtInSiteThemes;
        defaultText = lib.literalMD "Dark Reader's built-in filter themes for Office Online, SharePoint, OneDrive and Google Docs";
        description = "Per-site themes.";
      };

      presets = mkOption {
        type = types.listOf addonLib.json;
        default = [ ];
        description = "Saved theme presets, in Dark Reader's own format.";
      };

      automation = {
        enabled = mkOption {
          type = types.bool;
          default = false;
          description = "Whether Dark Reader turns itself on and off automatically.";
        };
        mode = mkOption {
          type = types.nullOr (
            types.enum [
              "time"
              "system"
              "location"
            ]
          );
          default = null;
          description = "What drives automation: a time window, the system colour scheme, or sunset/sunrise.";
        };
        behavior = mkOption {
          type = types.enum [
            "OnOff"
            "Scheme"
          ];
          default = "OnOff";
          description = "Whether automation switches Dark Reader on/off, or switches the theme between dark and light.";
        };
      };

      time = {
        activation = mkOption {
          type = types.strMatching "([01]?[0-9]|2[0-3]):[0-5][0-9]";
          default = "18:00";
          description = "Start of the time window for `automation.mode = \"time\"`.";
        };
        deactivation = mkOption {
          type = types.strMatching "([01]?[0-9]|2[0-3]):[0-5][0-9]";
          default = "9:00";
          description = "End of the time window.";
        };
      };

      location = {
        latitude = mkOption {
          type = types.nullOr types.number;
          default = null;
          description = "Latitude for `automation.mode = \"location\"`.";
        };
        longitude = mkOption {
          type = types.nullOr types.number;
          default = null;
          description = "Longitude for `automation.mode = \"location\"`.";
        };
      };

      detectDarkTheme = mkOption {
        type = types.bool;
        default = true;
        description = "Skip sites that already have a dark theme.";
      };

      enableForPDF = mkOption {
        type = types.bool;
        default = true;
        description = "Theme PDFs opened in the browser.";
      };

      enableForProtectedPages = mkOption {
        type = types.bool;
        default = false;
        description = "Theme pages where extensions are normally restricted.";
      };

      enableContextMenus = mkOption {
        type = types.bool;
        default = false;
        description = "Add Dark Reader entries to the page context menu.";
      };

      changeBrowserTheme = mkOption {
        type = types.bool;
        default = false;
        description = "Also recolour the browser UI to match.";
      };

      fetchNews = mkOption {
        type = types.bool;
        default = true;
        description = "Fetch Dark Reader's news and show a badge for unread items.";
      };

      syncSettings = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Keep settings in storage.sync (synced by Firefox Sync) rather than
          storage.local. Turn off so a synced copy from another machine can't
          override the configured one.
        '';
      };

      syncSitesFixes = mkOption {
        type = types.bool;
        default = false;
        description = "Download updated site fixes from Dark Reader's servers.";
      };

      previewNewDesign = mkOption {
        type = types.bool;
        default = false;
        description = "Use the redesigned popup.";
      };

      previewNewestDesign = mkOption {
        type = types.bool;
        default = false;
        description = "Use the newest popup design preview.";
      };
    };

  config = lib.mkIf cfg.enable {
    webext.extensions.${addonId} = {
      inherit (cfg) package privateBrowsing defaultArea;
      commands = cfg.shortcuts;
      # storage.local always gets the settings: Dark Reader looks at its
      # `syncSettings` there first, and falls back to it if sync is unavailable.
      storage.local.force = settings;
      storage.sync.force = lib.optionalAttrs cfg.syncSettings settings;
      # Everything Dark Reader keeps is configuration; the rest (news seen,
      # install date) is recreated as needed.
      state = "declarative";
    };
  };
}
