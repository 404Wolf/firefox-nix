# Pure helpers shared by the addon and UI modules.
{ lib }:
{
  # Firefox's widget id for an extension (makeWidgetId in ExtensionCommon):
  # the id lowercased, with anything outside [a-z0-9_-] replaced by "_".
  # Toolbar buttons are "<id>-browser-action", sidebars "<id>-sidebar-action".
  widgetId =
    addonId:
    lib.concatMapStrings (c: if builtins.match "[a-z0-9_-]" c != null then c else "_") (
      lib.stringToCharacters (lib.toLower addonId)
    );

  # A DOM key code (what KeyboardEvent.keyCode reports) for a key name, for
  # extensions that store bindings as key codes.
  keyCode =
    key:
    let
      named = {
        "[" = 219;
        "]" = 221;
        ";" = 186;
        "=" = 187;
        "," = 188;
        "-" = 189;
        "." = 190;
        "/" = 191;
        "`" = 192;
        "\\" = 220;
        "'" = 222;
        Space = 32;
        Enter = 13;
        Escape = 27;
        Left = 37;
        Up = 38;
        Right = 39;
        Down = 40;
      };
    in
    if builtins.isInt key then
      key
    else if named ? ${key} then
      named.${key}
    else if builtins.match "[a-zA-Z0-9]" key != null then
      lib.strings.charToInt (lib.toUpper key)
    else if builtins.match "F([1-9]|1[0-2])" key != null then
      111 + lib.toInt (lib.removePrefix "F" key)
    else
      throw "Unknown key name `${key}`; use a key code (integer) instead.";
}
