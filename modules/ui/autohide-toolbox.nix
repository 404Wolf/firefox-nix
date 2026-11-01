# Hide the toolbox (URL bar, toolbars) until it's needed: it slides in over
# the page on Ctrl+L / Alt+D / F6 or while one of its menus is open. See
# ./autohide-toolbox.css.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.chrome.autoHideToolbar;
in
{
  options.chrome.autoHideToolbar = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Hide the toolbox (nav bar, bookmarks bar, tab strip) until the URL bar
        is focused or one of its menus or panels is open. It shows over the
        page rather than pushing it down.
      '';
    };

    revealOnHover = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Also show it while the pointer is at the top edge of the window. This
        leaves an invisible 2px strip there that takes clicks meant for the page.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    settings."toolkit.legacyUserProfileCustomizations.stylesheets" = true;

    userChrome = lib.mkMerge [
      (builtins.readFile ./autohide-toolbox.css)
      (lib.mkIf cfg.revealOnHover ''
        /* Reveal on hover: leave the toolbox's bottom 2px on screen as the
         * hover target, and keep it shown while the pointer is over it. */
        :root:not([customizing], [inFullscreen]) #navigator-toolbox {
          transform: translateY(calc(-100% + 2px));

          &:hover {
            transform: none;
            opacity: 1;
          }
        }
      '')
    ];
  };
}
