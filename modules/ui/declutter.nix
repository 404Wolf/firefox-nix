# Turn off Firefox's promotional and "smart" extras: New Tab widgets and
# stories, sponsored suggestions, AI features, recommendations, promos and
# nags. Useful features (translations, Picture-in-Picture, Reader View,
# containers) are left alone.
#
# Enterprise policies do it where one exists (they also hide the matching
# settings); prefs cover the rest. Every pref name was checked against
# Firefox 159's omni.ja.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.programs.firefox.declutter;

  newTabPrefs = lib.mapAttrs' (n: lib.nameValuePair "browser.newtabpage.activity-stream.${n}") {
    # Weather
    "showWeather" = false;
    "system.showWeather" = false;
    "widgets.weather.enabled" = false;
    "widgets.system.weather.enabled" = false;
    "widgets.weatherForecast.enabled" = false;
    "widgets.system.weatherForecast.enabled" = false;
    # Widgets (lists, timer, clocks, stocks, crossword...)
    "widgets.enabled" = false;
    "widgets.system.enabled" = false;
    # Stories, sponsored stories and shortcuts
    "feeds.section.topstories" = false;
    "feeds.system.topstories" = false;
    "discoverystream.enabled" = false;
    "showSponsored" = false;
    "system.showSponsored" = false;
    "showSponsoredTopSites" = false;
    "showSponsoredCheckboxes" = false;
    "unifiedAds.spocs.enabled" = false;
    "unifiedAds.tiles.enabled" = false;
    # Shortcuts and recent activity
    "feeds.topsites" = false;
    "feeds.system.topsites" = false;
    "feeds.section.highlights" = false;
    # Wallpapers
    "newtabWallpapers.enabled" = false;
    # Feature recommendations ("CFR") and promo messages
    "asrouter.userprefs.cfr.addons" = false;
    "asrouter.userprefs.cfr.features" = false;
    "showWebNotifications" = false;
    "system.showWebNotifications" = false;
    # Usage pings
    "telemetry" = false;
    "feeds.telemetry" = false;
  };

  prefs = newTabPrefs // {
    # AI: chatbot sidebar, link previews, smart tab groups, smart window,
    # PDF alt text. (Also blocked by the AIControls policy; the prefs keep
    # the entry points out of menus.)
    "browser.ml.chat.enabled" = false;
    "browser.ml.chat.menu" = false;
    "browser.ml.chat.page" = false;
    "browser.ml.chat.page.menuBadge" = false;
    "browser.ml.chat.page.footerBadge" = false;
    "browser.ml.chat.shortcuts" = false;
    "browser.ml.chat.sidebar" = false;
    "browser.ml.linkPreview.enabled" = false;
    "browser.tabs.groups.smart.enabled" = false;
    "browser.tabs.groups.smart.userEnabled" = false;
    "browser.smartwindow.enabled" = false;
    "extensions.ml.enabled" = false;
    "pdfjs.enableAltText" = false;

    # Address bar: Firefox Suggest, sponsored and "trending" suggestions,
    # weather/Yelp/MDN cards.
    "browser.urlbar.quicksuggest.enabled" = false;
    "browser.urlbar.suggest.quicksuggest.sponsored" = false;
    "browser.urlbar.suggest.quicksuggest.nonsponsored" = false;
    "browser.urlbar.suggest.trending" = false;
    "browser.urlbar.trending.featureGate" = false;
    "browser.urlbar.suggest.weather" = false;
    "browser.urlbar.weather.featureGate" = false;
    "browser.urlbar.suggest.yelp" = false;
    "browser.urlbar.suggest.mdn" = false;
    "browser.urlbar.suggest.amp" = false;
    "browser.urlbar.suggest.wikipedia" = false;
    "browser.urlbar.suggest.addons" = false;
    "browser.urlbar.sponsoredTopSites" = false;

    # Recommendations, promos, onboarding, nags
    "extensions.htmlaboutaddons.recommendations.enabled" = false;
    "extensions.getAddons.showPane" = false;
    "browser.discovery.enabled" = false;
    "browser.preferences.moreFromMozilla" = false;
    "browser.aboutwelcome.enabled" = false;
    "browser.uitour.enabled" = false;
    "browser.vpn_promo.enabled" = false;
    "browser.ipProtection.enabled" = false;
    "browser.promo.pin.enabled" = false;
    "browser.shell.checkDefaultBrowser" = false;
    "browser.backup.scheduled.enabled" = false;
    "identity.fxaccounts.toolbar.pxiToolbarEnabled" = false;
    "browser.tabs.firefox-view" = false;
  };
in
{
  options.programs.firefox.declutter = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Turn off Firefox's promotional and AI extras: New Tab weather, widgets,
        stories and sponsored shortcuts; Firefox Suggest and sponsored
        suggestions; the AI chatbot, link previews, smart tab groups and smart
        window; extension and feature recommendations; VPN, pinning and
        default-browser promos; onboarding and What's New pages; Firefox View.
      '';
    };

    keepTranslations = mkOption {
      type = types.bool;
      default = true;
      description = "Keep on-device page translation available (it falls under Firefox's AI controls).";
    };
  };

  # The prefs go to every profile, as defaults a profile can override.
  options.programs.firefox.profiles = mkOption {
    type = types.attrsOf (
      types.submodule {
        config.settings = lib.mkIf cfg.enable (lib.mapAttrs (_: lib.mkDefault) prefs);
      }
    );
  };

  config = lib.mkIf cfg.enable {
    programs.firefox.policies = {
      AIControls = {
        Default = {
          Value = "blocked";
          Locked = true;
        };
      }
      // lib.optionalAttrs cfg.keepTranslations {
        Translations = {
          Value = "available";
          Locked = true;
        };
      };
      FirefoxHome = {
        Search = true;
        Weather = false;
        TopSites = false;
        SponsoredTopSites = false;
        Highlights = false;
        Stories = false;
        SponsoredStories = false;
        Widgets.Enabled = false;
        Locked = true;
      };
      FirefoxSuggest = {
        WebSuggestions = false;
        SponsoredSuggestions = false;
        ImproveSuggest = false;
        OnlineEnabled = false;
        Locked = true;
      };
      UserMessaging = {
        WhatsNew = false;
        ExtensionRecommendations = false;
        FeatureRecommendations = false;
        UrlbarInterventions = false;
        SkipOnboarding = true;
        MoreFromMozilla = false;
        FirefoxLabs = false;
        Locked = true;
      };
    };
  };
}
