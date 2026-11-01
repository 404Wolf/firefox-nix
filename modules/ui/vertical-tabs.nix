# Vertical tabs, from Firefox itself or from Tree Style Tab. Switching
# provider is one line; this sets the sidebar prefs, the TST addon and the
# CSS that go with each.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.verticalTabs;
  util = import ../util.nix { inherit lib; };
  tstId = "treestyletab@piro.sakura.ne.jp";
  tstSidebar = "${util.widgetId tstId}-sidebar-action";
  native = cfg.provider == "native";

  nativeVisibility = [
    "always-show"
    "expand-on-hover"
    "hide-sidebar"
  ];
  horizontalVisibility = [
    "hide-launcher"
    "hide-on-close"
  ];
  visibility =
    if cfg.visibility != null then
      cfg.visibility
    else if native then
      "always-show"
    else
      "hide-launcher";
in
{
  options.verticalTabs = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Show tabs in a vertical list beside the page.";
    };

    provider = mkOption {
      type = types.enum [
        "native"
        "treestyletab"
      ];
      default = "native";
      description = ''
        Who draws the tab list: Firefox's own vertical tabs (`native`), or Tree
        Style Tab in the sidebar (`treestyletab`, which also enables
        `addons.tree-style-tab`).
      '';
    };

    position = mkOption {
      type = types.enum [
        "left"
        "right"
      ];
      default = "left";
      description = "Which side of the window the tabs (the sidebar) go on.";
    };

    visibility = mkOption {
      type = types.nullOr (types.enum (nativeVisibility ++ horizontalVisibility));
      default = null;
      description = ''
        Firefox's sidebar mode (`sidebar.visibility`). With native tabs:
        `always-show`, `expand-on-hover` (collapsed to icons until hovered) or
        `hide-sidebar`. With Tree Style Tab Firefox is in horizontal-tabs mode,
        where it is `hide-launcher` (no icon strip, only the open panel) or
        `hide-on-close`. Null picks `always-show` or `hide-launcher`.
      '';
    };

    sidebarTools = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      example = [
        "history"
        "bookmarks"
      ];
      description = ''
        The sidebar's tool icons (`sidebar.main.tools`): built-in tools
        (aichat, syncedtabs, history, bookmarks, passwords) or extension ids
        that have a sidebar. Null leaves Firefox's default.
      '';
    };

    hideTabStrip = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Hide the horizontal tab strip when Tree Style Tab provides the tabs.
        (Native vertical tabs always hide it.)
      '';
    };

    hideSidebarHeader = mkOption {
      type = types.bool;
      default = true;
      description = "Hide the sidebar's title bar above Tree Style Tab.";
    };

    openOnStartup = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open Tree Style Tab's sidebar in a fresh session. Windows opened later
        copy the sidebar of the window they came from, and a restored session
        keeps its own.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = lib.elem visibility (if native then nativeVisibility else horizontalVisibility);
            message = "verticalTabs.visibility = \"${visibility}\" is not a ${
              if native then "native vertical tabs" else "horizontal-tabs (Tree Style Tab)"
            } mode; use one of ${
              lib.concatStringsSep ", " (if native then nativeVisibility else horizontalVisibility)
            }.";
          }
        ];

        settings = {
          "sidebar.revamp" = true;
          "sidebar.verticalTabs" = native;
          "sidebar.position_start" = cfg.position == "left";
          "sidebar.visibility" = visibility;
          "sidebar.expandOnHover" = visibility == "expand-on-hover";
        }
        // lib.optionalAttrs (cfg.sidebarTools != null) {
          "sidebar.main.tools" = lib.concatStringsSep "," (
            if native then lib.remove tstId cfg.sidebarTools else cfg.sidebarTools
          );
        };
      }

      (lib.mkIf (!native) {
        addons.tree-style-tab.enable = lib.mkDefault true;

        settings = {
          "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
        }
        // lib.optionalAttrs cfg.openOnStartup {
          # Fallback sidebar state for windows with nothing to restore or adopt.
          "sidebar.backupState" = builtins.toJSON {
            command = tstSidebar;
            panelOpen = true;
            launcherVisible = false;
            launcherExpanded = false;
            launcherWidth = 0;
            bookmarksExpandedFolders = [ ];
          };
        };

        userChrome = lib.mkMerge [
          (lib.mkIf cfg.hideTabStrip (builtins.readFile ./hide-tab-strip.css))
          (lib.mkIf cfg.hideSidebarHeader ''
            /* Hide the sidebar title bar above Tree Style Tab. */
            #sidebar-box[sidebarcommand="${tstSidebar}"] #sidebar-header {
              display: none !important;
            }
          '')
        ];
      })
    ]
  );
}
