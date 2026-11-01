# The toolbar layout (browser.uiCustomization.state), declared by area.
#
# Items are Firefox widget ids ("back-button", "urlbar-container",
# "downloads-button", "customizableui-special-spring1"...; see
# CustomizableUI.sys.mjs), or "addon:<extension id>" for an extension's
# toolbar button. Extensions not placed anywhere go in the extensions menu
# (the puzzle-piece button).
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.toolbar;
  util = import ../util.nix { inherit lib; };
  nativeTabs = config.verticalTabs.enable && config.verticalTabs.provider == "native";

  resolve =
    item:
    if lib.hasPrefix "addon:" item then
      "${util.widgetId (lib.removePrefix "addon:" item)}-browser-action"
    else
      item;

  area =
    description: default:
    mkOption {
      type = types.listOf types.str;
      inherit default description;
    };

  placements = lib.mapAttrs (_: map resolve) {
    "nav-bar" = cfg.navBar;
    "TabsToolbar" = cfg.tabStrip;
    "vertical-tabs" = cfg.verticalTabs;
    "PersonalToolbar" = cfg.bookmarksBar;
    "toolbar-menubar" = cfg.menuBar;
    "widget-overflow-fixed-list" = cfg.overflowMenu;
    "unified-extensions-area" = cfg.extensionsMenu;
  };

  allItems = lib.concatLists (lib.attrValues placements);
in
{
  options.toolbar = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Declare the toolbar layout. Customize mode can't change it while this is on.";
    };

    navBar = area "The main toolbar, with the URL bar." [
      "back-button"
      "forward-button"
      "stop-reload-button"
      "customizableui-special-spring1"
      "vertical-spacer"
      "urlbar-container"
      "customizableui-special-spring2"
      "downloads-button"
      "fxa-toolbar-menu-button"
      "unified-extensions-button"
    ];

    tabStrip = mkOption {
      type = types.listOf types.str;
      default = [
        "firefox-view-button"
      ]
      ++ lib.optional (!nativeTabs) "tabbrowser-tabs"
      ++ [
        "new-tab-button"
        "alltabs-button"
      ];
      defaultText = lib.literalMD "Firefox's default, without the tabs when native vertical tabs are on";
      description = "The horizontal tab strip.";
    };

    verticalTabs = mkOption {
      type = types.listOf types.str;
      default = lib.optional nativeTabs "tabbrowser-tabs";
      defaultText = lib.literalMD ''`[ "tabbrowser-tabs" ]` with native vertical tabs, else empty'';
      description = "The vertical tab list (native vertical tabs).";
    };

    bookmarksBar = area "The bookmarks toolbar." [
      "personal-bookmarks"
    ];

    menuBar = area "The menu bar." [ "menubar-items" ];

    overflowMenu = area "The overflow (») menu." [ ];

    extensionsMenu = area "The extensions (puzzle piece) menu." [ ];

    version = mkOption {
      type = types.ints.positive;
      default = 28;
      description = ''
        CustomizableUI's layout version (kVersion in CustomizableUI.sys.mjs);
        Firefox migrates layouts with an older version. 28 for Firefox 159.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.length allItems == lib.length (lib.unique allItems);
        message = "toolbar: an item is placed in more than one area.";
      }
    ];

    settings."browser.uiCustomization.state" = builtins.toJSON {
      inherit placements;
      # Every declared extension counts as seen, so Firefox doesn't add its
      # button to the nav bar on its own; unplaced ones stay in the
      # extensions menu.
      seen = lib.unique (
        lib.filter (lib.hasSuffix "-browser-action") allItems
        ++ map (id: "${util.widgetId id}-browser-action") (lib.attrNames config.webext.extensions)
      );
      dirtyAreaCache = lib.attrNames placements;
      currentVersion = cfg.version;
      newElementCount = 0;
    };
  };
}
