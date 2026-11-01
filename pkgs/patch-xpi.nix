# Repack a Firefox extension: unzip it, apply edits, and zip it back up as an
# unsigned XPI laid out like the rycee/NUR addons (so it drops into
# programs.firefox.profiles.<name>.extensions.packages unchanged).
#
# The upstream signature (META-INF) is removed, since any edit invalidates it.
# Firefox only loads unsigned extensions when xpinstall.signatures.required is
# false, which Developer Edition, Nightly and ESR honour (release ignores it).
#
#   patchXpi {
#     src = pkgs.firefox-addons.tridactyl;   # an addon package, or a .xpi file
#     pname = "tridactyl-blank";
#     manifest = { permissions = [ "theme" ]; };  # merged into manifest.json
#     postPatch = ''cp ${./newtab.html} static/newtab.html'';
#   }
{
  lib,
  stdenvNoCC,
  unzip,
  zip,
  jq,
}:

{
  src,
  pname ? src.pname or (lib.getName src),
  version ? src.version or (lib.getVersion src),
  addonId ? src.addonId or src.passthru.addonId,
  # Attrs merged into manifest.json. Lists are appended to, objects merged
  # recursively, everything else replaced.
  manifest ? { },
  postPatch ? "",
  nativeBuildInputs ? [ ],
  meta ? src.meta or { },
  passthru ? { },
}:

let
  firefoxAppId = "{ec8030f7-c20a-464f-9b0e-13a3a9e97384}";
  manifestPatch = builtins.toFile "${pname}-manifest-patch.json" (builtins.toJSON manifest);
in
stdenvNoCC.mkDerivation {
  inherit pname version;
  inherit src;
  nativeBuildInputs = [
    unzip
    zip
    jq
  ]
  ++ nativeBuildInputs;

  unpackPhase = ''
    runHook preUnpack
    if [ -d "$src" ]; then
      xpi=$(find "$src/share/mozilla/extensions" -name '*.xpi' | head -n1)
    else
      xpi=$src
    fi
    [ -n "$xpi" ] || { echo "patchXpi: no .xpi found in $src" >&2; exit 1; }
    mkdir xpi
    # Mozilla's zips trip unzip's central-directory check (exit 1 or 2); a
    # missing manifest afterwards is the real failure signal.
    unzip -q "$xpi" -d xpi || [ $? -le 2 ]
    [ -f xpi/manifest.json ] || { echo "patchXpi: $xpi has no manifest.json" >&2; exit 1; }
    cd xpi
    runHook postUnpack
  '';

  patchPhase = ''
    runHook prePatch
    rm -rf META-INF
    jq --slurpfile patch ${manifestPatch} '
      def merge($a; $b):
        if ($a|type) == "object" and ($b|type) == "object" then
          reduce ($b|keys_unsorted[]) as $k ($a; .[$k] = merge($a[$k]; $b[$k]))
        elif ($a|type) == "array" and ($b|type) == "array" then
          $a + [$b[] | select(. as $x | $a | index([$x]) | not)]
        elif $b == null then $a
        else $b end;
      merge(.; $patch[0])
    ' manifest.json > manifest.json.new
    mv manifest.json.new manifest.json
    runHook postPatch
  '';

  inherit postPatch;

  # Deterministic archive: sorted entries, fixed timestamps, no extra fields.
  installPhase = ''
    runHook preInstall
    dst="$out/share/mozilla/extensions/${firefoxAppId}"
    mkdir -p "$dst"
    find . -exec touch -h -d @1 {} +
    find . -type f -printf '%P\n' | LC_ALL=C sort | zip -q -X -D -9 "$dst/${addonId}.xpi" -@
    runHook postInstall
  '';

  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;
  preferLocalBuild = true;

  passthru = {
    inherit addonId;
    unsigned = true;
  }
  // passthru;

  meta = meta // {
    platforms = lib.platforms.all;
  };
}
