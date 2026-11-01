# firefox-webext: encode, apply and dump WebExtension storage for Firefox profiles.
{
  lib,
  python3,
  runCommand,
}:
let
  python = python3.withPackages (p: [ p.python-snappy ]);
in
runCommand "firefox-webext"
  {
    passthru = { inherit python; };
    meta = {
      description = "Declarative WebExtension storage (storage.local / storage.sync) for Firefox profiles";
      mainProgram = "firefox-webext";
      platforms = lib.platforms.all;
    };
  }
  ''
    install -Dm644 ${./firefox_webext.py} $out/lib/firefox_webext.py
    mkdir -p $out/bin
    cat > $out/bin/firefox-webext <<EOF
    #!${python}/bin/python3
    import sys
    sys.path.insert(0, "$out/lib")
    from firefox_webext import main
    main()
    EOF
    chmod +x $out/bin/firefox-webext

    # Codec self-test at build time.
    PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=$out/lib ${python}/bin/python3 ${./tests/codec.py}
  ''
